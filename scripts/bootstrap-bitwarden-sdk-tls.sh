#!/usr/bin/env bash
# Gera um certificado self-signed para o bitwarden-sdk-server (sidecar do ESO)
# e cria/atualiza o Secret `bitwarden-tls-certs` no namespace external-secrets.
#
# O Secret guarda 3 chaves:
#   - tls.crt / tls.key  -> usados pelo SDK server
#   - ca.crt             -> referenciado pelo ClusterSecretStore (caProvider)
#
# Idempotente: rodar de novo gera novo cert e regrava o Secret.
set -euo pipefail

NS="external-secrets"
SECRET_NAME="bitwarden-tls-certs"
SVC_DNS="bitwarden-sdk-server.${NS}.svc.cluster.local"
DAYS=3650

KUBECTL="${KUBECTL:-sudo k3s kubectl}"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORKDIR/tls.key" \
  -out    "$WORKDIR/tls.crt" \
  -subj   "/CN=bitwarden-sdk-server" \
  -addext "subjectAltName=DNS:${SVC_DNS},DNS:bitwarden-sdk-server,DNS:bitwarden-sdk-server.${NS}" \
  -days   "$DAYS" >/dev/null 2>&1

$KUBECTL -n "$NS" create secret generic "$SECRET_NAME" \
  --from-file=tls.crt="$WORKDIR/tls.crt" \
  --from-file=tls.key="$WORKDIR/tls.key" \
  --from-file=ca.crt="$WORKDIR/tls.crt" \
  --dry-run=client -o yaml | $KUBECTL apply -f -

echo "Secret $SECRET_NAME atualizado em $NS (válido até $(openssl x509 -in "$WORKDIR/tls.crt" -noout -enddate | cut -d= -f2))"
