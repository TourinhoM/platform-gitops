## Postgres (dev)

Plano:
- **Decidir instalador**: Helm (ex.: Bitnami) vs manifests
- **Storage**: storageClass, tamanho, backup
- **Credenciais**: não versionar segredo em claro; usar External Secrets/SOPS/SealedSecrets
- **Networking**: Service ClusterIP, NetworkPolicy (se você usa)

