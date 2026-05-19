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

## Pré-requisito: setup no Bitwarden Secrets Manager

Antes de rodar o onboarding, prepare a conta do Bitwarden. Tudo é feito no
[Web Vault](https://vault.bitwarden.com/) (plano free serve).

1. **Organization** — em *Settings → New organization*, cria (ou usa uma existente).
2. **Habilitar Secrets Manager** — no menu lateral, abre *Secrets Manager*. Na
   primeira vez, ativa para essa organization.
3. **Project** — em *Secrets Manager → Projects*, cria o project (lab usa `homelab`).
4. **Secrets** — em *Secrets*, cria com estes nomes (associando ao project `homelab`):
   - `postgres-superuser-password`
   - `keycloak-admin-password`
5. **Machine account** — em *Machine accounts → New*, cria um (ex.: `eso-homelab`).
   Em *Projects*, dá acesso de leitura ao `homelab`. Em *Access tokens → New*,
   gera um token, **copia agora** (não dá pra ver de novo).
6. **IDs** — copia o `organizationID` (UUID na URL ou em *Settings*) e o
   `projectID` (URL do project). Edita
   `cluster-config/external-secrets/clustersecretstore-bitwarden-homelab.yaml`
   trocando `organizationID` e `projectID` pelos seus.

Com o access token em mãos e o ClusterSecretStore apontando pros seus IDs,
o onboarding abaixo finaliza o resto.

## Quickstart (onboarding completo)

Script único que faz Argo CD → root-app → ESO → Bitwarden em um só passo.
Idempotente; pede o access token do Bitwarden em runtime.

```bash
bash scripts/onboarding.sh
```

O que ele executa, em ordem:

1. `kubectl apply -k bootstrap/argocd`
2. Espera `argocd-server` ficar Ready
3. `kubectl apply -f bootstrap/root-app/application.yaml`
4. Espera o namespace `external-secrets` e o controller do ESO
5. Pede o **access token** do machine account (Bitwarden Secrets Manager) e cria o Secret `bitwarden-access-token`
6. Roda `scripts/bootstrap-bitwarden-sdk-tls.sh` (cert self-signed do sidecar)
7. Espera o `ClusterSecretStore bitwarden-homelab` virar Ready

Para reescrever o token depois:

```bash
FORCE_REWRITE_TOKEN=1 bash scripts/onboarding.sh
```

Apps individuais que precisam de TLS no próprio Ingress trazem seu script
(ex.: `deploy-keycloak/scripts/bootstrap-tls.sh` gera o `keycloak-tls`).

## Bootstrap manual (passo a passo)

Se preferir rodar à mão em vez do script:

```bash
kubectl apply -k bootstrap/argocd
kubectl apply -f bootstrap/root-app/application.yaml
```

Depois, dois segredos precisam ser criados **fora do Git** (chicken-and-egg):

1. **Access token** do machine account no Bitwarden Secrets Manager:

   ```bash
   sudo k3s kubectl -n external-secrets create secret generic bitwarden-access-token \
     --from-literal=token='<COLE_O_ACCESS_TOKEN>'
   ```

2. **Certificado TLS self-signed** para o `bitwarden-sdk-server`:

   ```bash
   bash scripts/bootstrap-bitwarden-sdk-tls.sh
   ```

   O script gera um cert válido por 10 anos com SAN cobrindo o DNS interno
   `bitwarden-sdk-server.external-secrets.svc.cluster.local` e cria/atualiza o
   Secret `bitwarden-tls-certs` (chaves: `tls.crt`, `tls.key`, `ca.crt`).

Validar:

```bash
sudo k3s kubectl get clustersecretstore bitwarden-homelab \
  -o jsonpath='{.status.conditions}'   # type=Ready, status=True
```

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