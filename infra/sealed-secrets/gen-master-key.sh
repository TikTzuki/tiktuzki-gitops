#!/usr/bin/env bash
#
# Generate a Sealed-Secrets master key BEFORE the controller ever starts.
#
# The controller normally generates its own keypair on first start. If you never back that
# up, a cluster rebuild makes every committed SealedSecret permanently undecryptable —
# which is exactly how the key was lost here once already. Pre-generating inverts the
# order: the key exists and is backed up first, and the controller adopts it.
#
# Needs only openssl. No kubectl, no cluster — so it also works during a disaster recovery
# when there is nothing to talk to yet.
#
#   ./gen-master-key.sh                      # -> ~/cluster-backups/sealed-secrets-key.yaml
#   ./gen-master-key.sh /secure/vol/key.yaml
#
set -euo pipefail

OUT="${1:-$HOME/cluster-backups/sealed-secrets-key.yaml}"
NS="${SEALED_NS:-sealed-secrets}"
NAME="${SEALED_KEY_NAME:-sealed-secrets-key}"
BITS="${SEALED_KEY_BITS:-1024}"     # the controller's own default
DAYS="${SEALED_KEY_DAYS:-3650}"     # kubeseal encrypts against this cert: outlive the cluster
SUBJ="${SEALED_KEY_SUBJ:-/CN=sealed-secret/O=sealed-secret}"

die() { echo "ERROR: $*" >&2; exit 1; }

command -v openssl >/dev/null || die "openssl not found"

# ── Refuse to destroy an existing key ────────────────────────────────────────────────
# Overwriting a master key orphans every SealedSecret sealed against it. Make that
# impossible by accident.
[ -e "$OUT" ] && die "$OUT already exists.
  This file may be the ONLY copy of a key that existing SealedSecrets depend on.
  Move it aside deliberately before generating a new one."

OUTDIR=$(cd "$(dirname "$OUT")" 2>/dev/null && pwd || echo "$(dirname "$OUT")")

# ── Refuse to write inside a git work tree ───────────────────────────────────────────
# .gitignore here does not cover *.yaml, so a key dropped in the repo is one `git add -A`
# away from being published.
if git -C "$OUTDIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  die "$OUTDIR is inside a git work tree.
  This file contains the PRIVATE KEY. Write it somewhere untracked, e.g. ~/cluster-backups/."
fi

mkdir -p "$(dirname "$OUT")"; chmod 700 "$(dirname "$OUT")" 2>/dev/null || true

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
umask 077

echo "==> generating ${BITS}-bit RSA keypair, valid ${DAYS}d"
openssl req -x509 -nodes -newkey "rsa:${BITS}" \
  -keyout "$WORK/tls.key" -out "$WORK/tls.crt" \
  -subj "$SUBJ" -days "$DAYS" 2>/dev/null

# ── Prove the pair matches before anything depends on it ─────────────────────────────
pub_from_crt=$(openssl x509 -in "$WORK/tls.crt" -noout -pubkey | openssl md5)
pub_from_key=$(openssl rsa -in "$WORK/tls.key" -pubout 2>/dev/null | openssl md5)
[ "$pub_from_crt" = "$pub_from_key" ] || die "cert and key do not match — refusing to write"
echo "==> keypair verified ($pub_from_crt)"

# base64 without line wrapping, portable across GNU and BSD/macOS
b64() { base64 < "$1" | tr -d '\n'; }

cat > "$OUT" <<EOF
# Sealed-Secrets master key — PRE-GENERATED, not controller-generated.
#
# Apply this BEFORE the controller's first start; it adopts this keypair instead of
# generating its own. That ordering is the point: the key is backed up before any secret
# is sealed against it, so a rebuild is recoverable by construction.
#
# ⚠️ CONTAINS THE PRIVATE KEY. Never commit it — anything holding this file can decrypt
# every SealedSecret in the gitops repo. Store it encrypted, off node1 and off your laptop.
#
# Restore order on a new cluster:
#   kubectl create namespace ${NS}
#   kubectl apply -f $(basename "$OUT")
#   kubectl apply -f apps/base/sealed-secrets.yaml
#
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) · ${BITS}-bit RSA · expires $(openssl x509 -in "$WORK/tls.crt" -noout -enddate | cut -d= -f2)
apiVersion: v1
kind: Secret
type: kubernetes.io/tls
metadata:
  name: ${NAME}
  namespace: ${NS}
  labels:
    # The controller selects on this label at startup. Without it the key is ignored and
    # a fresh one is generated instead — silently.
    sealedsecrets.bitnami.com/sealed-secrets-key: active
data:
  tls.crt: $(b64 "$WORK/tls.crt")
  tls.key: $(b64 "$WORK/tls.key")
EOF

chmod 600 "$OUT"

echo "==> wrote $OUT"
openssl x509 -in "$WORK/tls.crt" -noout -subject -dates
cat <<EOF

NEXT:
  1. Copy this file to encrypted storage that is NOT node1 and NOT this machine.
  2. On the cluster, before the controller starts:
       kubectl create namespace ${NS}
       kubectl apply -f "$OUT"
       kubectl apply -f apps/base/sealed-secrets.yaml
  3. Re-seal secrets against it with kubeseal (see infra/sealed-secrets/README.md).
EOF
