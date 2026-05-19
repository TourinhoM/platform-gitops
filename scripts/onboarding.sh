#!/usr/bin/env bash
# Onboarding end-to-end do cluster: Argo CD + root app + ESO + Bitwarden.
#
# Etapas:
#   1. Instala Argo CD (bootstrap/argocd)
#   2. Espera o argocd-server ficar Ready
#   3. Aplica o root-app (que sincroniza tudo em apps/)
#   4. Espera o namespace external-secrets e o controller do ESO
#   5. Cria o Secret bitwarden-access-token (pede o token interativamente)
#   6. Gera o cert TLS self-signed do bitwarden-sdk-server
#   7. Espera o ClusterSecretStore bitwarden-homelab ficar Ready
#
# Idempotente: pode rodar de novo. Para reescrever o access token:
#   FORCE_REWRITE_TOKEN=1 bash scripts/onboarding.sh
set -euo pipefail

KUBECTL="${KUBECTL:-sudo k3s kubectl}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    %s\033[0m\n' "$*"; }

# ---------- 1. Argo CD ----------
step "1/7 Instalando Argo CD"
$KUBECTL apply -k "$REPO_ROOT/bootstrap/argocd"

# ---------- 2. Espera argocd-server ----------
step "2/7 Aguardando argocd-server ficar Ready"
$KUBECTL -n argocd rollout status deploy/argocd-server --timeout=5m

# ---------- 3. Root app ----------
step "3/7 Aplicando root-app"
$KUBECTL apply -f "$REPO_ROOT/bootstrap/root-app/application.yaml"

# ---------- 4. Espera ESO ----------
step "4/7 Aguardando External Secrets Operator"
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

# ---------- 5. bitwarden-access-token ----------
step "5/7 Secret bitwarden-access-token"
SECRET_EXISTS=0
if $KUBECTL -n external-secrets get secret bitwarden-access-token >/dev/null 2>&1; then
  SECRET_EXISTS=1
fi

if [[ "$SECRET_EXISTS" == "1" && "${FORCE_REWRITE_TOKEN:-0}" != "1" ]]; then
  info "Secret já existe — pulando. (use FORCE_REWRITE_TOKEN=1 para sobrescrever)"
else
  info "Cole o access token do machine account (Bitwarden Secrets Manager)."
  info "A entrada não vai ser ecoada."
  printf '    > '
  read -rs BW_TOKEN
  echo
  if [[ -z "${BW_TOKEN}" ]]; then
    echo "Token vazio. Abortando." >&2
    exit 1
  fi
  $KUBECTL -n external-secrets create secret generic bitwarden-access-token \
    --from-literal=token="$BW_TOKEN" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
  unset BW_TOKEN
fi

# ---------- 6. TLS sidecar ----------
step "6/7 Cert TLS do bitwarden-sdk-server"
KUBECTL="$KUBECTL" bash "$SCRIPT_DIR/bootstrap-bitwarden-sdk-tls.sh"

# ---------- 7. ClusterSecretStore Ready ----------
step "7/7 Aguardando ClusterSecretStore bitwarden-homelab"
for i in $(seq 1 60); do
  if $KUBECTL get clustersecretstore bitwarden-homelab >/dev/null 2>&1; then break; fi
  sleep 5
done
for i in $(seq 1 60); do
  STATUS=$($KUBECTL get clustersecretstore bitwarden-homelab \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [[ "$STATUS" == "True" ]]; then
    info "ClusterSecretStore Ready."
    break
  fi
  sleep 5
done

if [[ "${STATUS:-}" != "True" ]]; then
  warn "ClusterSecretStore ainda não está Ready. Verifique com:"
  warn "  $KUBECTL get clustersecretstore bitwarden-homelab -o jsonpath='{.status.conditions}'"
  exit 1
fi

step "Onboarding concluído"
info "Apps individuais que precisam de TLS de Ingress trazem seu próprio script"
info "(ex.: deploy-keycloak/scripts/bootstrap-tls.sh)."
