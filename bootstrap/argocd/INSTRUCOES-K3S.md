# Bootstrap em Cluster K3s Zerado

Este guia assume um cluster K3s novo, sem nada aplicado, e usa os manifests deste repositório.

## 1) Pré-requisitos

- Uma máquina Linux para o K3s (VM ou bare metal)
- `kubectl` instalado na sua máquina local
- Acesso SSH ao servidor
- Este repositório clonado localmente

## 2) Instalar o K3s (cluster zerado)

No servidor Linux:

```bash
curl -sfL https://get.k3s.io | sh -
sudo systemctl status k3s --no-pager
```

Verifique se o node subiu:

```bash
sudo k3s kubectl get nodes
```

## 3) Configurar kubeconfig na sua máquina local

No servidor, pegue o kubeconfig:

```bash
sudo cat /etc/rancher/k3s/k3s.yaml
```

Copie o conteúdo para sua máquina local em `~/.kube/config` (ou outro arquivo) e ajuste:

- `server:` para o IP/hostname real do servidor K3s
- Certifique-se de que sua máquina alcança esse endpoint (porta 6443)

Teste local:

```bash
kubectl get nodes
```

## 4) Aplicar Argo CD (bootstrap deste repo)

Na raiz do repositório:

```bash
kubectl apply -k bootstrap/argocd
```

Isso vai criar a stack padrão completa do Argo CD (manifests oficiais), incluindo:

- `Namespace` `argocd`
- `argocd-server`
- `argocd-repo-server`
- `argocd-application-controller`
- `argocd-redis`
- RBAC, ConfigMaps, Secrets e Services padrão
- `Ingress` `argocd-server` (Traefik)

Valide:

```bash
kubectl -n argocd get all
kubectl -n argocd get ingress
kubectl -n argocd get pods
```

## 5) Acesso ao Argo CD

Opção rápida com port-forward:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Abra:

- https://localhost:8080

Se quiser acessar via Ingress, ajuste `bootstrap/argocd/ingress.yaml` com host/TLS e DNS.

## 6) Subir o Root App (GitOps completo)

Antes de aplicar, edite:

- `bootstrap/root-app/application.yaml`

Preencha principalmente:

- `spec.source.repoURL` (URL real do seu repo)
- `spec.source.targetRevision` (branch correta)

Depois aplique:

```bash
kubectl apply -f bootstrap/root-app/application.yaml
```

Valide:

```bash
kubectl -n argocd get applications
```

## 7) Troubleshooting básico

Ver logs do servidor:

```bash
kubectl -n argocd logs deploy/argocd-server --tail=200
```

Se o pod não subir:

```bash
kubectl -n argocd describe pod -l app.kubernetes.io/name=argocd-server
```

Se o Ingress não responder:

- Verifique se o Traefik está ativo (`kube-system`)
- Confirme DNS/hosts apontando para o IP do node
- Confirme que a porta 80 está liberada

## Observação importante

Este bootstrap usa os manifests oficiais completos do Argo CD. Se você preferir customização avançada de valores, pode migrar para instalação via Helm chart (`argo-cd`) mantendo a versão pinada.
