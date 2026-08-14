# Sealed Secrets — Git-safe secrets

Today secrets live two ways, both fragile for migration:
- a few committed **in plaintext** (`apps/base/database-secret.yaml`, etc.) — base64 is not encryption,
- several created **out-of-band** and only live in-cluster (`kafka-ui-oauth`, the `demo`/`openclaw`
  secrets, `argocd-secret`) — invisible to Git and lost if the cluster dies.

[Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) fixes both: you encrypt a Secret
into a `SealedSecret` CR that is **safe to commit**. Only the in-cluster controller (holding the
private key) can decrypt it into a real `Secret`. So every secret becomes reproducible from Git,
and a migration only has to carry **one** thing: the controller's master key.

## How it works

```
kubeseal (uses controller's PUBLIC cert) ──► SealedSecret (encrypted, commit to Git)
                                                     │  ArgoCD syncs it
                                                     ▼
controller (holds PRIVATE key) ──decrypts──► Secret (real, in-cluster, never in Git)
```

## One-time setup

1. **Deploy the controller** — `apps/base/sealed-secrets.yaml` (register it like the other
   `apps/base` apps). Pin `targetRevision` to the latest chart first (see the TODO in that file).
2. **Install the CLI** locally: `brew install kubeseal` (or grab the release matching the controller).

## Sealing a secret (the everyday workflow)

```bash
# Build a normal Secret manifest (do NOT commit this), then seal it:
kubectl create secret generic kafka-ui-oauth \
  --namespace database \
  --from-literal=client-secret='<keycloak-client-secret>' \
  --dry-run=client -o yaml \
| kubeseal \
  --controller-namespace sealed-secrets \
  --controller-name sealed-secrets-controller \
  --format yaml \
> charts/kafka/templates/... or apps/base/kafka-ui-oauth-sealed.yaml

# Commit the SealedSecret. The controller decrypts it into the real Secret on sync.
```

A `SealedSecret` is encrypted for a specific `namespace/name` by default — keep those matching
what the consuming chart expects (e.g. `database/kafka-ui-oauth`).

### Migrating existing secrets
For each plaintext/out-of-band secret, dump it (`kubectl get secret X -o yaml`), pipe through
`kubeseal`, commit the result, and delete the plaintext source from Git. Priorities here:
`database-secret` (now drifted — 3 live keys vs 1 in Git), `kafka-ui-oauth`, and the `demo`/`openclaw` secrets.

## ⚠️ The master key — back it up

The controller auto-generates an RSA key pair on first start, stored as a Secret labelled
`sealedsecrets.bitnami.com/sealed-secrets-key` in the `sealed-secrets` namespace. **If you lose it,
every committed SealedSecret becomes undecryptable.**

- `infra/backup/backup.sh` already captures it to `sealed-secrets-key.yaml`.
- On a new cluster, `kubectl apply` that key **before** the controller starts (see `RESTORE.md` §3),
  so the controller adopts it instead of generating a fresh one.
- Store the key file **offline / encrypted** — it is the root of trust for all your secrets.

## Result

After migration: secrets ride along in Git as SealedSecrets, the controller decrypts them, and the
only out-of-band artifact in the whole cluster is one backed-up key file.
