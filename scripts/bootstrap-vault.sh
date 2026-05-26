#!/usr/bin/env bash
# Bootstrap completo do Vault após cluster limpo:
#   1. Aguarda pod do Vault
#   2. vault operator init (1 key share / 1 threshold)
#   3. Cria Secret vault-unseal-key (usado pelo postStart hook)
#   4. Unseal
#   5. Cria Secret vault-bootstrap-token e reinicia o Job de bootstrap
#      (habilita KV v2, Kubernetes auth, policies eso-read e crossplane-write, roles)
#   6. Cria todos os secrets de aplicação em secret/cluster/*
#
# Idempotente: detecta se o Vault já está inicializado e pula as etapas concluídas.
#
# Pré-requisitos: kubectl (ou k3s kubectl), jq
set -euo pipefail

KUBECTL="${KUBECTL:-sudo k3s kubectl}"
PLATFORM_SECURITY_PATH="${PLATFORM_SECURITY_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../platform-security" 2>/dev/null && pwd || echo "")}"

step()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
warn()  { printf '\033[1;33m    WARN: %s\033[0m\n' "$*"; }
ask()   { printf '    \033[1;33m%s\033[0m: ' "$*"; }
askml() { printf '    \033[1;33m%s\033[0m (cole o valor, depois ENTER + Ctrl-D):\n' "$*"; }

vexec() { $KUBECTL exec -n vault "$VAULT_POD" -- vault "$@"; }

# ---------- 1. Aguarda pod ----------
step "1/6 Aguardando pod do Vault"
for i in $(seq 1 60); do
  VAULT_POD=$($KUBECTL get pod -n vault -l app.kubernetes.io/name=vault \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "$VAULT_POD" ]]; then break; fi
  sleep 5
done
[[ -z "${VAULT_POD:-}" ]] && { echo "Pod do Vault não encontrado. Abortando." >&2; exit 1; }
# Espera Running (não Ready) — readiness probe só passa após init+unseal
for i in $(seq 1 60); do
  STATUS=$($KUBECTL get pod "$VAULT_POD" -n vault -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [[ "$STATUS" == "Running" ]] && break
  sleep 5
done
[[ "${STATUS:-}" != "Running" ]] && { echo "Pod do Vault não ficou Running. Abortando." >&2; exit 1; }
info "Pod: $VAULT_POD"

# ---------- 2. Init ----------
step "2/6 Inicializando Vault"
INIT_STATUS=$(vexec status -format=json 2>/dev/null | jq -r '.initialized' || echo "false")

if [[ "$INIT_STATUS" == "true" ]]; then
  info "Vault já inicializado — pulando init."
  info "Certifique-se de que vault-unseal-key e vault-bootstrap-token já existem."
else
  INIT_JSON=$(vexec operator init -key-shares=1 -key-threshold=1 -format=json)
  UNSEAL_KEY=$(echo "$INIT_JSON" | jq -r '.unseal_keys_b64[0]')
  ROOT_TOKEN=$(echo "$INIT_JSON" | jq -r '.root_token')

  info "Vault inicializado."
  warn "Guarde o root token em local seguro: $ROOT_TOKEN"

  # ---------- 3. vault-unseal-key ----------
  step "3/6 Criando Secret vault-unseal-key"
  $KUBECTL create secret generic vault-unseal-key \
    -n vault \
    --from-literal=key="$UNSEAL_KEY" \
    --dry-run=client -o yaml | $KUBECTL apply -f -

  # ---------- 4. Unseal ----------
  step "4/6 Unsealing Vault"
  vexec operator unseal "$UNSEAL_KEY"
  info "Vault unsealed."

  # ---------- 5. Bootstrap Job ----------
  step "5/6 Bootstrap Job (KV, Kubernetes auth, policies, roles)"
  $KUBECTL create secret generic vault-bootstrap-token \
    -n vault \
    --from-literal=token="$ROOT_TOKEN" \
    --dry-run=client -o yaml | $KUBECTL apply -f -

  # Reinicia job caso já exista de uma execução anterior
  $KUBECTL delete job vault-bootstrap -n vault --ignore-not-found

  if [[ -n "$PLATFORM_SECURITY_PATH" && -d "$PLATFORM_SECURITY_PATH/vault" ]]; then
    $KUBECTL apply -k "$PLATFORM_SECURITY_PATH/vault"
  else
    warn "PLATFORM_SECURITY_PATH não encontrado. Aplique manualmente:"
    warn "  kubectl apply -k <path>/platform-security/vault"
  fi

  info "Aguardando Job vault-bootstrap completar..."
  $KUBECTL wait job/vault-bootstrap -n vault --for=condition=complete --timeout=3m
  info "Bootstrap Job concluído."

  export VAULT_ROOT_TOKEN="$ROOT_TOKEN"
fi

# ---------- 6. Secrets de aplicação ----------
step "6/6 Criando secrets de aplicação no Vault"
info "Os valores serão lidos interativamente. A entrada não é ecoada."

# Solicita root token se não veio do init
if [[ -z "${VAULT_ROOT_TOKEN:-}" ]]; then
  ask "Root token do Vault"
  read -rs VAULT_ROOT_TOKEN
  echo
fi

export VAULT_ADDR="http://localhost:8200"
$KUBECTL port-forward -n vault svc/security-vault 8200:8200 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 2

export VAULT_TOKEN="$VAULT_ROOT_TOKEN"

read_secret() {
  ask "$1"
  read -rs VAL
  echo
  echo "$VAL"
}

read_multiline_secret() {
  askml "$1"
  VAL=$(cat)
  echo "$VAL"
}

# --- cluster/argocd ---
info ""
info "--- cluster/argocd (GitHub App do ArgoCD) ---"
ARGOCD_APP_ID=$(read_secret "github_app_id")
ARGOCD_INSTALL_ID=$(read_secret "github_app_installation_id")
info "  Cole a chave privada PEM (ENTER + Ctrl-D para finalizar):"
ARGOCD_PRIVATE_KEY=$(read_multiline_secret "github_app_private_key (PEM)")

vault kv put secret/cluster/argocd \
  github_app_id="$ARGOCD_APP_ID" \
  github_app_installation_id="$ARGOCD_INSTALL_ID" \
  github_app_private_key="$ARGOCD_PRIVATE_KEY"
info "secret/cluster/argocd criado."

# --- cluster/grafana ---
info ""
info "--- cluster/grafana ---"
GRAFANA_ADMIN_PW=$(read_secret "admin_password")
GRAFANA_DB_PW=$(read_secret "db_password")

vault kv put secret/cluster/grafana \
  admin_password="$GRAFANA_ADMIN_PW" \
  db_password="$GRAFANA_DB_PW"
info "secret/cluster/grafana criado."

# --- cluster/postgresql ---
info ""
info "--- cluster/postgresql ---"
PG_SUPERUSER_PW=$(read_secret "superuser_password")

vault kv put secret/cluster/postgresql \
  superuser_password="$PG_SUPERUSER_PW"
info "secret/cluster/postgresql criado."

# --- cluster/keycloak ---
info ""
info "--- cluster/keycloak ---"
KC_ADMIN_PW=$(read_secret "admin_password")

vault kv put secret/cluster/keycloak \
  admin_password="$KC_ADMIN_PW"
info "secret/cluster/keycloak criado."

# --- cluster/dtrack ---
info ""
info "--- cluster/dtrack ---"
DTRACK_DB_PW=$(read_secret "db_password")
warn "O api_key do Dependency Track é gerado pela aplicação após o primeiro boot."
warn "Execute depois: vault kv patch secret/cluster/dtrack api_key=<valor>"
warn "Deixando api_key vazio por enquanto."

vault kv put secret/cluster/dtrack \
  db_password="$DTRACK_DB_PW" \
  api_key=""
info "secret/cluster/dtrack criado (api_key pendente)."

step "Bootstrap do Vault concluído"
info ""
info "Próximos passos:"
info "  1. Após Dependency Track subir, recupere a API key e atualize:"
info "       vault kv patch secret/cluster/dtrack api_key=<valor>"
info "  2. Force-sync dos ExternalSecrets:"
info "       kubectl annotate es --all -A force-sync=\$(date +%s) --overwrite"
