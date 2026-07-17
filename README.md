# deploy-argocd

Repositório GitOps para gerenciar **Argo CD** e os **workloads** do cluster via pull request.

## Estrutura

- `bootstrap/`: instala/atualiza o Argo CD e cria o “root app”
- `apps/`: só CRDs do Argo (`AppProject`, `Application`, `ApplicationSet`)
- `envs/`: manifests por ambiente (Kustomize/Helm) referenciados por `apps/`
- `lib/`: peças reutilizáveis (patches/labels)

## Fluxo (GitOps)

1. Aplicar uma vez o Argo CD: `bootstrap/argocd/`
2. Aplicar uma vez o root app: `bootstrap/root-app/application.yaml`
3. A partir daí, o Argo CD reconcilia `apps/` e tudo que eles apontarem em `envs/`

## Quickstart (onboarding completo)

```bash
kubectl apply -k bootstrap/argocd
kubectl apply -f bootstrap/root-app/application.yaml
```

Após o ArgoCD sincronizar, siga o **Vault** abaixo para inicializar o backend de secrets.
A partir daí o cluster é GitOps puro — qualquer novo ExternalSecret vai para
o Vault via `platform-security` e é materializado pelo ESO automaticamente.

## HashiCorp Vault

O cluster usa HashiCorp Vault self-hosted (namespace `vault`, gerenciado por
`platform-security`) como backend de secrets. O ESO autentica via Kubernetes auth
— sem token fixo após o bootstrap inicial.

### Bootstrap (uma vez por cluster)

1. **Inicializar o Vault** (após o pod `security-vault-0` subir):

   ```bash
   kubectl exec -n vault security-vault-0 -- vault operator init \
     -key-shares=1 -key-threshold=1 -format=json > ~/vault-init.json
   ```

   Guarda `~/vault-init.json` em lugar seguro (contém unseal key e root token).

2. **Desselar o Vault:**

   ```bash
   UNSEAL_KEY=$(cat ~/vault-init.json | python3 -c \
     "import sys,json; print(json.load(sys.stdin)['unseal_keys_b64'][0])")
   kubectl exec -n vault security-vault-0 -- vault operator unseal $UNSEAL_KEY
   ```

3. **Criar o token de bootstrap** (escopo limitado, expira em 2h):

   ```bash
   ROOT_TOKEN=$(cat ~/vault-init.json | python3 -c \
     "import sys,json; print(json.load(sys.stdin)['root_token'])")

   BOOTSTRAP_TOKEN=$(kubectl exec -n vault security-vault-0 -- \
     vault token create -policy=root -ttl=2h -field=token \
     -address=http://127.0.0.1:8200 <<< "" 2>/dev/null || \
     kubectl exec -n vault security-vault-0 -- env VAULT_TOKEN=$ROOT_TOKEN \
     vault token create -policy=root -ttl=2h -field=token)

   kubectl create secret generic vault-bootstrap-token \
     -n vault --from-literal=token=$BOOTSTRAP_TOKEN
   ```

4. **Aguardar o Job `vault-bootstrap`** (gerenciado pelo ArgoCD) completar:

   ```bash
   kubectl wait job/vault-bootstrap -n vault --for=condition=complete --timeout=120s
   ```

   O Job configura Kubernetes auth, policies (eso-read, crossplane-write) e
   roles, depois revoga o token de bootstrap automaticamente.

   > O bloco de secrets de aplicação (`vault kv put` de postgresql, keycloak,
   > grafana, dtrack, backstage, kargo) é idempotente por path — se o token de
   > bootstrap expirar/for revogado e o Job precisar reexecutar (recriando-o
   > manualmente), ele **não** re-gera senhas de paths que já existem. Fazer
   > isso sem essa guarda rotaciona a senha no Vault sem rotacionar no serviço
   > com estado real (ex.: Postgres), quebrando autenticação até alguém
   > alinhar o valor manualmente nos dois lados.

Validar:

```bash
kubectl get job vault-bootstrap -n vault   # COMPLETIONS: 1/1
```

### Segredos pós-bootstrap

O Job `vault-bootstrap` (`platform-security/vault/configmap-bootstrap.yaml`) gera sozinho as senhas
internas (`genpass`) de grafana, postgresql, keycloak e kargo, e cria os paths `cluster/argocd` e
`cluster/dtrack#admin_password` como placeholder pros sync Jobs abaixo preencherem.

**Automatizados** — cada um roda como um Job (mesmo padrão do `vault-bootstrap`: login no Vault via
Kubernetes auth, `vault kv patch`), disparado pelo próprio ArgoCD depois que a peça de origem existe.
Não precisam de intervenção manual, só de tempo pro cluster convergir:

| Vault path | Property | Job | De onde vem |
|---|---|---|---|
| `cluster/argocd` / `cluster/grafana` | `oidc_client_secret` | `platform-auth/base/job-oidc-secret-sync.yaml` | Client-secret gerado pelo próprio Keycloak ao criar os clients `argocd`/`grafana` (Admin REST API) |
| `cluster/backstage` | `argocd_auth_token` | `platform-gitops/cluster-config/argocd/job-backstage-account-token.yaml` | Token da conta local `backstage` (capability `apiKey`, RBAC só-leitura) criada no ArgoCD — não é mais a senha do `admin` |
| `cluster/dtrack` | `api_key` | `platform-security/dtrack/base/job-apikey-sync.yaml` | API key do time `Administrators` do Dependency-Track, após trocar a senha padrão `admin`/`admin` pela gerada em `cluster/dtrack#admin_password` |

Se algum desses Jobs já rodou (`Completed`) antes de a peça de origem existir e falhou, ele não
reexecuta sozinho — Jobs são imutáveis. Delete o Job (`kubectl delete job <nome> -n <ns>`) pra deixar
o ArgoCD recriá-lo no próximo sync.

**Ainda manuais** — vêm de uma identidade humana no GitHub, sem API viável pra criação desassistida:

| Vault path | Property | De onde vem | Comando |
|---|---|---|---|
| `cluster/backstage` | `github_token` | Personal Access Token do GitHub (scopes `repo`, `read:org`) pro catalog/scaffolder do Backstage | `vault kv patch secret/cluster/backstage github_token=<valor>` |
| `cluster/backstage` | `github_client_id` / `github_client_secret` | OAuth App do GitHub (Settings → Developer settings → OAuth Apps) pro login do Backstage | `vault kv patch secret/cluster/backstage github_client_id=<id> github_client_secret=<secret>` |

## Lint / validação CI

O repo é validado pelo workflow `lint-k8s.yml` do
[`org-ci-platform`](../org-ci-platform) — 3 scanners em paralelo, todos sobre
o **output do `kustomize build`** (não sobre YAMLs crus, porque patches
strategic-merge são fragmentos sem securityContext/resources que o merge
preenche depois).

| Scanner | O que valida |
|---|---|
| **kubeconform** | Schema das APIs k8s + CRDs (Argo CD, ESO, etc.) via datreeio catalog |
| **kube-linter** | Best-practices: resources, probes, securityContext, capabilities |
| **polaris** | Security/reliability/efficiency: TLS, hostPort, image policies, PriorityClass, single replica; gate em `danger` |

Caller em `.github/workflows/lint.yml` — zero inputs, plug-and-play.

### Patches em `bootstrap/argocd/` por causa do lint

O Argo CD upstream (`argo-cd v2.11.7/manifests/install.yaml`) é referenciado
via URL na `kustomization.yaml`. Patches strategic-merge ajustam ele pra
cluster homelab e pra passar nos scanners:

- **`argocd-cmd-params-cm-patch.yaml`** — config do Argo CD (URL, insecure-mode etc.).
- **`resources-patch.yaml`** — endereça findings do lint e ajusta upstream pra production-grade:
  1. `resources.requests/limits` (CPU + memória) em todos os 7 workloads.
  2. `imagePullPolicy: Always` em todos os containers (defesa contra tag mutation;
     próximo nível seria digest pinning via Renovate).
  3. `liveness-port` (kube-linter): declara `containerPort: 9001` no
     notifications-controller (upstream não declara mas a probe aponta pra ele).
  4. Pod-level `securityContext` (`runAsNonRoot` + `seccompProfile: RuntimeDefault`)
     nos 5 workloads que upstream não seta. Container-level já vem no upstream —
     patch reforça baseline a nível de Pod.

### Polaris — exemptions e config

**`polaris.yaml`** (raiz) desativa checks que não aplicam ao homelab single-node WSL ou são decisão de scope:

- `priorityClassNotSet`, `topologySpreadConstraint`, `missingPodDisruptionBudget`, `missingNetworkPolicy`, `deploymentMissingReplicas` — irrelevantes em 1 nó com replicas: 1.
- `automountServiceAccountToken` — componentes Argo CD precisam de API access.
- `metadataAndInstanceMismatched` — convenção `app.kubernetes.io/instance` que upstream não segue.

**`bootstrap/argocd/polaris-rbac-exempt-patch.yaml`** annota 4 RBAC resources com `polaris.fairwinds.com/<check>-exempt: "true"` pros dangers inerentes ao Argo CD:

| Resource | Check exempted | Por quê |
|---|---|---|
| `ClusterRoleBinding/argocd-application-controller` | `clusterrolebindingClusterAdmin`, `clusterrolebindingPodExecAttach` | aplicar manifests arbitrários é função core; sync hooks usam pods/exec |
| `ClusterRoleBinding/argocd-server` | `clusterrolebindingPodExecAttach` | UI features (logs, exec) |
| `ClusterRole/argocd-application-controller` | `clusterrolePodExecAttach` | mesma justificativa do binding |
| `ClusterRole/argocd-server` | `clusterrolePodExecAttach` | mesma justificativa do binding |

> Toda nova exemption (em `polaris.yaml` ou via annotation) **deve vir com
> justificativa explicando o porquê**. Sem isso, o arquivo vira lugar de
> varrer findings pra debaixo do tapete em vez de aceitar conscientemente.

## Plano: o que fazer em cada arquivo

### `bootstrap/argocd/kustomization.yaml`
- **TODO**: decidir a forma de instalar o Argo CD (manifests vs Helm)
- **TODO**: manter a versão pinada (chart version ou release)
- **TODO**: ajustar `ingress.yaml` se você expõe a UI

### `bootstrap/argocd/values.yaml`
- **TODO**: configurar Ingress/hostname/TLS (se aplicável)
- **TODO**: configurar RBAC (admin desativado, SSO, etc) se necessário
- **TODO**: configurar repos/creds (idealmente via External Secrets)

### `bootstrap/root-app/application.yaml`
- **TODO**: preencher `spec.source.repoURL` com o URL real do repo
- **TODO**: ajustar o branch (`targetRevision`)
- **TODO**: decidir se `syncPolicy.automated` fica ligado no root (recomendado)

### `apps/projects/platform.yaml`
- **TODO**: restringir `sourceRepos` (somente o necessário)
- **TODO**: restringir `destinations` (namespaces por ambiente)

### `apps/applications/*.yaml`
- **TODO**: para cada app, apontar `spec.source.path` para o diretório em `envs/<ambiente>/...`
- **TODO**: definir `syncOptions` e política de prune/selfHeal

### `envs/dev/*` e `envs/prod/*`
- **TODO**: colocar aqui manifests reais (kustomize/helm values) por ambiente
- **TODO**: segredos: usar SOPS/SealedSecrets/ExternalSecrets (não commitar segredo em claro)