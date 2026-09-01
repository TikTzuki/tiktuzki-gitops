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
#   5. Node-level state       — microk8s CA + certs, the dqlite datastore, netplan (holds the
#                               Wi-Fi PSK) and NetBird peer identity. Only collectable on node1.
#
# Run on node1 (needs kubectl access + sudo). Run anywhere else and section 5 is skipped with
# a warning; sections 1-4 still work over any working kubeconfig.
#
# ⚠️ THE OUTPUT IS PLAINTEXT SECRETS. Every Secret in the cluster, the Sealed-Secrets master
# key, the microk8s CA private key and the Wi-Fi PSK all land in $OUT unencrypted. Wrap it
# with infra/backup/encrypt-file.sh before it leaves the node — see the NEXT block at the end.
#
# Depends only on: kubectl, tar, gzip, sed  (no yq/jq required).
#
set -euo pipefail

# ----------------------------------------------------------------------------- config
# Split on whitespace into an array: node1 has no bare `kubectl` binary, only the
# `microk8s kubectl` wrapper, and a quoted "$KUBECTL" would look for a command literally
# named "microk8s kubectl". Invoked as "${KUBECTL[@]}" everywhere below.
#   on node1:  KUBECTL="microk8s kubectl" ./backup.sh
read -r -a KUBECTL <<<"${KUBECTL:-kubectl}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${BACKUP_DIR:-$HOME/cluster-backups}/$STAMP"
SEALED_NS="${SEALED_NS:-sealed-secrets}"            # namespace the controller runs in
KEEP="${BACKUP_KEEP:-7}"                            # timestamped runs to keep; 0 disables pruning

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

# Node-local volume dirs to tar. Must stay in step with infra/storage/create-volume-dirs.sh,
# which provisions them — a dir listed here but not provisioned there only produces a warning,
# but one provisioned there and missing here is silently NOT backed up.
# Sources: charts/*/values-dev.yaml `persistence.localPath` / `.path`.
DATA_DIRS=(
  /srv/k8s-volumes/tigerbeetle        # ledger — CRITICAL
  /srv/k8s-volumes/kafka              # broker log segments
  /srv/k8s-volumes/timescaledb-ha     # Patroni PGDATA, one subdir per replica (0,1,2) — see NOTE

  # Provisioned but deliberately not archived:
  # /srv/k8s-volumes/monitoring        # Prometheus TSDB is re-derivable and large; Grafana's
                                       # sqlite holds only annotations/prefs (dashboards and
                                       # datasources are provisioned from Git).

  # Not provisioned on this node — the charts still declare PVs at these paths, so uncomment
  # here AND in create-volume-dirs.sh if one is ever deployed:
  # /srv/k8s-volumes/timescaledb  /srv/k8s-volumes/postgres      # single-node DB charts
  # /srv/k8s-volumes/cv-hub       /srv/k8s-volumes/openclaw
  # /srv/k8s-volumes/checkin-data /srv/k8s-volumes/room-manager/logs
  # /srv/k8s-volumes/ollama-models     # re-downloadable model blobs, tens of GB
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
      "${KUBECTL[@]}" -n "$ns" get pod -l "${ref#label:}" --field-selector=status.phase=Running \
          -o go-template='{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}' 2>/dev/null \
        | head -1
      ;;
    *)
      "${KUBECTL[@]}" -n "$ns" get pod "$ref" >/dev/null 2>&1 && printf '%s\n' "$ref"
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
  if "${KUBECTL[@]}" -n "$ns" exec "$pod" -- pg_dumpall -U "$user" 2>/dev/null \
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
"${KUBECTL[@]}" get secret -A -o go-template='{{range .items}}{{if and (ne .type "kubernetes.io/service-account-token") (ne .type "helm.sh/release.v1")}}{{.metadata.namespace}} {{.metadata.name}}{{"\n"}}{{end}}{{end}}' \
  | while read -r ns name; do
      [ -z "$ns" ] && continue
      "${KUBECTL[@]}" -n "$ns" get secret "$name" -o yaml --show-managed-fields=false \
        | strip > "$OUT/secrets/${ns}.${name}.yaml"
    done
log "  -> $(ls -1 "$OUT/secrets" | wc -l | tr -d ' ') secret(s) under secrets/"

# 4. ------------------------------------------------------- sealed-secrets master key
if "${KUBECTL[@]}" -n "$SEALED_NS" get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
      -o name >/dev/null 2>&1; then
  log "backing up Sealed-Secrets master key from ns/$SEALED_NS"
  "${KUBECTL[@]}" -n "$SEALED_NS" get secret \
      -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml --show-managed-fields=false \
    | strip > "$OUT/sealed-secrets-key.yaml"
  warn "sealed-secrets-key.yaml is the cluster's decryption key — store it OFFLINE/encrypted."
else
  log "no Sealed-Secrets controller key found in ns/$SEALED_NS (not installed yet — fine)"
fi

# 5. ------------------------------------------------------------------ node-level state
# Everything above can be collected from any machine with kubectl. This section only works
# ON node1, and covers what a fresh microk8s install would NOT reproduce.
if [ -d /var/snap/microk8s/current ]; then
  mkdir -p "$OUT/node"

  # The CA and every cert issued from it. Losing ca.key invalidates every kubeconfig ever
  # minted from this cluster — including your own client cert — and the only fix is to
  # regenerate the CA and re-mint them all.
  log "tar microk8s certs"
  $SUDO tar czf "$OUT/node/microk8s-certs.tgz" -C /var/snap/microk8s/current certs

  # dqlite datastore: the full API state. A convenience, not a necessity — ArgoCD rebuilds
  # all of it from Git. Worth having when you want the cluster back exactly as it WAS,
  # rather than as Git says it should be.
  log "microk8s dbctl backup"
  $SUDO microk8s dbctl backup -o "$OUT/node/dqlite-backup" \
    || warn "dbctl backup failed — cluster state not captured (Git still has desired state)"

  # Netplan carries the Wi-Fi PSK in cleartext at mode 0600.
  log "tar /etc/netplan"
  $SUDO tar czf "$OUT/node/netplan.tgz" -C /etc netplan

  # NetBird peer identity. Re-enrolling instead of restoring this assigns a NEW overlay IP,
  # which silently breaks every NPM proxy host still pointing at the old one.
  if [ -d /var/lib/netbird ] || [ -d /etc/netbird ]; then
    log "tar netbird state"
    $SUDO tar czf "$OUT/node/netbird.tgz" -C / \
      $([ -d /var/lib/netbird ] && echo var/lib/netbird) \
      $([ -d /etc/netbird ] && echo etc/netbird)
  fi

  # Facts needed to rebuild the host itself — none of it is in Git.
  {
    echo "hostname:  $(hostname)"          # node name is pinned in every PV's nodeAffinity
    echo "kernel:    $(uname -r)"
    echo "os:        $(. /etc/os-release && echo "$PRETTY_NAME")"
    echo
    echo "== microk8s =="; snap list microk8s 2>/dev/null
    microk8s status --format short 2>/dev/null | grep -E 'enabled' || true
    echo
    echo "== addresses =="; ip -4 -o addr show 2>/dev/null | awk '{print $2, $4}'
    echo
    echo "== block devices =="; lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null
    echo
    echo "== fstab =="; cat /etc/fstab
  } > "$OUT/node/node-info.txt" 2>&1

  # tar/dbctl ran as root; hand the results back so the archive is readable without sudo.
  $SUDO chown -R "$(id -u):$(id -g)" "$OUT/node"
  log "  -> node/ ($(du -sh "$OUT/node" | cut -f1))"
else
  warn "not running on node1 — skipped certs, dqlite, netplan and netbird state"
fi

# --------------------------------------------------------------------------- manifest
{
  echo "cluster backup $STAMP"
  echo "kubectl context: $("${KUBECTL[@]}" config current-context 2>/dev/null || echo n/a)"
  echo
  # `find -printf` is GNU-only and this script is allowed to run off-node (sections 1-4),
  # where find is BSD — so size the files portably instead.
  find "$OUT" -type f ! -name MANIFEST.txt | sort | while read -r f; do
    printf '%s\t%s bytes\n' "${f#"$OUT"/}" "$(wc -c <"$f" | tr -d ' ')"
  done
} > "$OUT/MANIFEST.txt"

# ------------------------------------------------------------------------- retention
# Timestamp dirs are YYYYmmdd-HHMMSS, so lexical order == chronological order.
# `head -n -N` would be simpler but is GNU-only, and this script also runs on macOS.
if [ "$KEEP" -gt 0 ]; then
  BASE="$(dirname "$OUT")"
  total="$(find "$BASE" -maxdepth 1 -type d -name '20*-*' | wc -l | tr -d ' ')"
  if [ "$total" -gt "$KEEP" ]; then
    find "$BASE" -maxdepth 1 -type d -name '20*-*' | sort | head -n "$((total - KEEP))" \
      | while read -r old; do
          log "prune $old (keeping newest $KEEP)"
          $SUDO rm -rf "$old"
        done
  fi
fi

log "done. Contents:"
cat "$OUT/MANIFEST.txt"
cat <<EOF

NEXT:
  • Encrypt it, then copy it off-box — it holds plaintext secrets, the Sealed-Secrets
    master key, the microk8s CA key and the Wi-Fi PSK:
        tar czf $OUT.tgz -C "$(dirname "$OUT")" "$(basename "$OUT")"
        infra/backup/encrypt-file.sh $OUT.tgz
        rm -rf "$OUT" $OUT.tgz        # once the .gpg is copied somewhere else
  • To rebuild on a new server, follow infra/backup/RESTORE.md.
EOF
