#!/usr/bin/env bash
#
# Create argocd-oidc-secret OUT OF BAND (not a SealedSecret, nothing committed).
#
# Prompts for the Google client secret with echo off, so the value never lands in shell
# history, in a file, or in a terminal transcript.
#
#   ./create-oidc-secret.sh
#
# ⚠️ TRADE-OFF: this Secret exists ONLY in the cluster. It is invisible to Git and is lost
# on a rebuild — you must re-run this script after any cluster rebuild, and the Google
# client secret must be retrievable from your password manager to do so. That is the exact
# class of credential infra/sealed-secrets/README.md calls out as fragile. Deliberate here;
# just do not forget it exists.
#
set -euo pipefail

NS="${ARGOCD_NS:-devops}"
NAME="${SECRET_NAME:-argocd-oidc-secret}"

die() { echo "ERROR: $*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl not found"
kubectl get ns "$NS" >/dev/null 2>&1 || die "namespace $NS not found"

if kubectl -n "$NS" get secret "$NAME" >/dev/null 2>&1; then
  echo "NOTE: $NS/$NAME already exists — it will be REPLACED."
  printf "  continue? [y/N] "; read -r ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || die "aborted"
fi

# -s = no echo. Read into a variable that is never exported or logged.
printf "Google client secret: "
read -rs CLIENT_SECRET
echo
[ -n "$CLIENT_SECRET" ] || die "empty value"

# ── The label is load-bearing ────────────────────────────────────────────────────────
# Argo CD resolves `$argocd-oidc-secret:clientSecret` (from oidc.config) ONLY against
# Secrets labelled app.kubernetes.io/part-of=argocd. Without it Argo cannot read the object
# at all and logs a *missing key* error, which misleads — the key is fine, the Secret is
# invisible. Login then fails at token exchange with an empty client secret.
kubectl create secret generic "$NAME" \
  --namespace "$NS" \
  --from-literal=clientSecret="$CLIENT_SECRET" \
  --dry-run=client -o yaml \
| kubectl label --local -f - \
    app.kubernetes.io/part-of=argocd \
    -o yaml \
| kubectl apply -f - >/dev/null

unset CLIENT_SECRET

echo "==> created $NS/$NAME"
kubectl -n "$NS" get secret "$NAME" \
  -o custom-columns=NAME:.metadata.name,KEYS:.data,LABEL:.metadata.labels.'app\.kubernetes\.io/part-of' 2>/dev/null \
  | sed 's/map\[clientSecret:[^]]*\]/[clientSecret]/'

lbl=$(kubectl -n "$NS" get secret "$NAME" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}')
[ "$lbl" = "argocd" ] || die "label missing — Argo will not be able to read this Secret"
echo "==> label app.kubernetes.io/part-of=argocd present"

cat <<EOF

NEXT:
  kubectl -n $NS rollout restart deploy/argocd-server
  kubectl -n $NS logs deploy/argocd-server | grep -i oidc    # no 'failed to resolve' lines
EOF
