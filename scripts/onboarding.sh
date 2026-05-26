#!/usr/bin/env bash
# Onboarding end-to-end do cluster: Argo CD + root app + ESO + Vault.
#
# Pré-requisito: Vault já inicializado e com o auth method kubernetes configurado.
#
# Etapas:
#   1. Instala Argo CD (bootstrap/argocd)
#   2. Espera o argocd-server ficar Ready
#   3. Aplica o root-app (que sincroniza tudo em apps/)
#   4. Espera o namespace external-secrets e o controller do ESO
#   5. Espera o ClusterSecretStore vault-homelab ficar Ready
set -euo pipefail

KUBECTL="${KUBECTL:-sudo k3s kubectl}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    %s\033[0m\n' "$*"; }

# ---------- 1. Argo CD ----------
step "1/5 Instalando Argo CD"
$KUBECTL apply -k "$REPO_ROOT/bootstrap/argocd"

# ---------- 2. Espera argocd-server ----------
step "2/5 Aguardando argocd-server ficar Ready"
$KUBECTL -n argocd rollout status deploy/argocd-server --timeout=5m

# ---------- 3. Root app ----------
step "3/5 Aplicando root-app"
$KUBECTL apply -f "$REPO_ROOT/bootstrap/root-app/application.yaml"

# ---------- 4. Espera ESO ----------
step "4/5 Aguardando External Secrets Operator"
info "esperando namespace external-secrets..."
for i in $(seq 1 60); do
  if $KUBECTL get ns external-secrets >/dev/null 2>&1; then break; fi
  sleep 5
done
info "esperando deployment external-secrets..."
for i in $(seq 1 60); do
  if $KUBECTL -n external-secrets get deploy external-secrets >/dev/null 2>&1; then break; fi
  sleep 5
done
$KUBECTL -n external-secrets rollout status deploy/external-secrets --timeout=5m

# ---------- 5. ClusterSecretStore vault-homelab ----------
step "5/5 Aguardando ClusterSecretStore vault-homelab"
for i in $(seq 1 60); do
  if $KUBECTL get clustersecretstore vault-homelab >/dev/null 2>&1; then break; fi
  sleep 5
done

STATUS=""
for i in $(seq 1 60); do
  STATUS=$($KUBECTL get clustersecretstore vault-homelab \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [[ "$STATUS" == "True" ]]; then
    info "ClusterSecretStore Ready."
    break
  fi
  sleep 5
done

if [[ "${STATUS:-}" != "True" ]]; then
  warn "ClusterSecretStore vault-homelab ainda não está Ready. Verifique:"
  warn "  $KUBECTL get clustersecretstore vault-homelab -o jsonpath='{.status.conditions}'"
  warn "Certifique-se de que o Vault está unsealed e o auth method kubernetes está configurado."
  exit 1
fi

step "Onboarding concluído"
info "Apps individuais que precisam de TLS de Ingress trazem seu próprio script"
info "(ex.: deploy-keycloak/scripts/bootstrap-tls.sh)."
