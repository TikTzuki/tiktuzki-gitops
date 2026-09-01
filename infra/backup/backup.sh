#!/usr/bin/env bash
#
# backup.sh — capture the stateful + non-Git parts of this microk8s cluster so it can be
# rebuilt on a new server (see RESTORE.md). The cluster's DESIRED STATE (ArgoCD apps, Helm
# charts, values) already lives in Git — this script only captures what Git does NOT hold:
#
#   1. Database contents      — logical dumps (pg_dumpall) of postgres + timescaledb
#   2. Raw volume data        — tarballs of the node-local hostPath dirs (tigerbeetle, kafka, ...)
#   3. Secrets                — every non-system Secret across all namespaces
#   4. Sealed-Secrets key     — the controller's master key (if installed); THE one secret that
#                               must survive a migration, or committed SealedSecrets can't decrypt
#
# Run on node1 (needs kubectl access + sudo for the hostPath tarballs).
# Depends only on: kubectl, tar, gzip, sed  (no yq/jq required).
#
set -euo pipefail

# ----------------------------------------------------------------------------- config
KUBECTL="${KUBECTL:-kubectl}"                       # e.g. `microk8s kubectl`
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${BACKUP_DIR:-$HOME/cluster-backups}/$STAMP"
SEALED_NS="${SEALED_NS:-sealed-secrets}"            # namespace the controller runs in

# Logical DB dumps, one per line: "namespace|pod-or-selector|superuser|output-basename"
#
# The 2nd field is either a literal pod name or `label:<selector>`, resolved at run time.
# Patroni moves the leader between timescaledb-ha-{0,1,2} on every failover, so the HA cluster
# MUST be looked up by its `role: master` label — a hardcoded pod name silently dumps whichever
# replica happens to sit at that ordinal, which can lag the primary.
#
# The 4th field keeps the output filename stable (db/timescaledb-ha.sql.gz) regardless of which
# pod was leader at backup time, so RESTORE.md can name it.
DB_DUMPS=(
  "database|label:app.kubernetes.io/name=timescaledb-ha,role=master|postgres|timescaledb-ha"
  "database|timescaledb-0|postgres|timescaledb-0"   # single-node chart — drop once fully on -ha
  "database|postgres-0|postgres|postgres-0"
)

# Node-local hostPath dirs to tar (dev values). Edit to match your deployed values file.
# Sources: charts/*/values-dev.yaml `persistence.localPath` / `.path`.
DATA_DIRS=(
  /srv/k8s-volumes/tigerbeetle        # ledger — CRITICAL
  /srv/k8s-volumes/kafka              # broker log segments
  /srv/k8s-volumes/cv-hub             # uploaded blobs (chart mounts .../cv-hub/uploads)
  /srv/k8s-volumes/openclaw           # openclaw workspace/state
  /srv/k8s-volumes/checkin-data       # checkin app data
  /srv/k8s-volumes/timescaledb-ha     # Patroni PGDATA, one subdir per replica (0,1,2) — see NOTE
  /srv/k8s-volumes/timescaledb        # single-node chart (pre-HA) — drop once retired
  /srv/k8s-volumes/postgres
  # /srv/k8s-volumes/ollama-models       # re-downloadable model blobs (tens of GB) — off by default
  # /srv/k8s-volumes/room-manager/logs   # uncomment if you want logs too
  # /srv/k8s-volumes/monitoring          # Prometheus TSDB is re-derivable and large; Grafana's
                                         # sqlite holds only annotations/prefs (dashboards and
                                         # datasources are provisioned from Git). Off by default.
)
# NOTE: the PGDATA tars are taken from a LIVE cluster, so they are crash-consistent at best.
# They are a same-version fallback only — the logical dumps above are the authoritative restore
# path for Postgres/TimescaleDB (and the only sane one for the Patroni cluster; see RESTORE.md).
# ----------------------------------------------------------------------------- /config

log() { printf '\033[1;34m[backup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[backup] WARN:\033[0m %s\n' "$*" >&2; }

mkdir -p "$OUT"/{db,data,secrets}
log "writing to $OUT"

# 1. ----------------------------------------------------------------- database dumps
# Turn a DB_DUMPS 2nd field into a concrete pod name; empty output = nothing to dump.
resolve_pod() {
  local ns="$1" ref="$2"
  case "$ref" in
    label:*)
      "$KUBECTL" -n "$ns" get pod -l "${ref#label:}" --field-selector=status.phase=Running \
          -o go-template='{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}' 2>/dev/null \
        | head -1
      ;;
    *)
      "$KUBECTL" -n "$ns" get pod "$ref" >/dev/null 2>&1 && printf '%s\n' "$ref"
      ;;
  esac
}

for entry in "${DB_DUMPS[@]}"; do
  IFS='|' read -r ns ref user out <<<"$entry"
  pod="$(resolve_pod "$ns" "$ref" || true)"
  if [ -z "$pod" ]; then
    warn "skip $ns/$ref — no matching Running pod (DB not deployed?)"
    continue
  fi
  log "pg_dumpall $ns/$pod -> db/${out}.sql.gz"
  if "$KUBECTL" -n "$ns" exec "$pod" -- pg_dumpall -U "$user" 2>/dev/null \
      | gzip > "$OUT/db/${out}.sql.gz"; then
    log "  -> db/${out}.sql.gz ($(du -h "$OUT/db/${out}.sql.gz" | cut -f1))"
  else
    warn "dump of $ns/$pod failed (pod up but pg_dumpall errored) — check manually"
  fi
done

# 2. ------------------------------------------------------------------ hostPath data
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"
for dir in "${DATA_DIRS[@]}"; do
  if [ -d "$dir" ]; then
    name="$(echo "$dir" | sed 's#^/##; s#/#_#g')"
    log "tar $dir"
    $SUDO tar czf "$OUT/data/${name}.tgz" -C / "${dir#/}"
    log "  -> data/${name}.tgz ($(du -h "$OUT/data/${name}.tgz" | cut -f1))"
  else
    warn "skip $dir — not present on this host"
  fi
done

# 3. ---------------------------------------------------------------------- secrets
# All secrets except ServiceAccount tokens and Helm release blobs (both regenerate).
strip() { sed -e '/^\s*creationTimestamp:/d' -e '/^\s*resourceVersion:/d' \
              -e '/^\s*uid:/d' -e '/^\s*selfLink:/d'; }

log "exporting secrets (all namespaces, excl. SA tokens + helm releases)"
"$KUBECTL" get secret -A -o go-template='{{range .items}}{{if and (ne .type "kubernetes.io/service-account-token") (ne .type "helm.sh/release.v1")}}{{.metadata.namespace}} {{.metadata.name}}{{"\n"}}{{end}}{{end}}' \
  | while read -r ns name; do
      [ -z "$ns" ] && continue
      "$KUBECTL" -n "$ns" get secret "$name" -o yaml --show-managed-fields=false \
        | strip > "$OUT/secrets/${ns}.${name}.yaml"
    done
log "  -> $(ls -1 "$OUT/secrets" | wc -l | tr -d ' ') secret(s) under secrets/"

# 4. ------------------------------------------------------- sealed-secrets master key
if "$KUBECTL" -n "$SEALED_NS" get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
      -o name >/dev/null 2>&1; then
  log "backing up Sealed-Secrets master key from ns/$SEALED_NS"
  "$KUBECTL" -n "$SEALED_NS" get secret \
      -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml --show-managed-fields=false \
    | strip > "$OUT/sealed-secrets-key.yaml"
  warn "sealed-secrets-key.yaml is the cluster's decryption key — store it OFFLINE/encrypted."
else
  log "no Sealed-Secrets controller key found in ns/$SEALED_NS (not installed yet — fine)"
fi

# --------------------------------------------------------------------------- manifest
{
  echo "cluster backup $STAMP"
  echo "kubectl context: $("$KUBECTL" config current-context 2>/dev/null || echo n/a)"
  echo
  find "$OUT" -type f -printf '%P\t%s bytes\n' | sort
} > "$OUT/MANIFEST.txt"

log "done. Contents:"
cat "$OUT/MANIFEST.txt"
cat <<EOF

NEXT:
  • Copy "$OUT" off-box (it contains plaintext secrets + DB data — encrypt at rest).
  • To rebuild on a new server, follow infra/backup/RESTORE.md.
EOF
