#!/usr/bin/env bash
#
# create-volume-dirs.sh — pre-create the node-local directories backing every static PV
# in this repo, with the uid/gid each workload runs as.
#
# Run on node1, as root:   sudo ./create-volume-dirs.sh
# Idempotent — safe to re-run after adding a chart.
#
# WHY THIS EXISTS
# ---------------
# The charts here do NOT use the default `microk8s-hostpath` StorageClass. Each one ships a
# static PersistentVolume pinned to node1 with an explicit path (charts/*/templates/pv.yaml).
# A hostPath/local PV does not create its directory, and for pods without an fsGroup the
# kubelet does not chown it either — so a missing or wrongly-owned directory shows up as a
# pod stuck in CrashLoopBackOff with a permission error, not as a scheduling failure.
#
# ⚠️ THE MOUNT GUARD BELOW IS THE IMPORTANT PART.
# /srv/k8s-volumes is a separate 500G LV (ubuntu-vg/k8s-data). If that LV is not mounted,
# these mkdirs happily create directories on the *root* filesystem underneath the empty
# mountpoint — 118G, shared with the OS, snap and containerd images. Everything then works
# until the root filesystem fills up and the node wedges. Refusing to run is the correct
# behaviour; mount the LV first.
#
set -euo pipefail

ROOT="${K8S_VOLUME_ROOT:-/srv/k8s-volumes}"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run me as root (sudo $0)" >&2; exit 1; }

# ── guard: refuse to scatter data across the root LV ───────────────────────────────────
if ! mountpoint -q "$ROOT"; then
  cat >&2 <<EOF
ERROR: $ROOT is not a mount point.

Creating volume directories now would put cluster data on the ROOT filesystem
($(df -h / | awk 'NR==2{print $2" total, "$4" free"}')) instead of the dedicated volume.

Check the LV is mounted:
    lsblk -o NAME,SIZE,MOUNTPOINT | grep k8s
    mount | grep $ROOT
    grep $ROOT /etc/fstab        # must be present, or it will not survive a reboot
EOF
  exit 1
fi

# ── path | owner | note ────────────────────────────────────────────────────────────────
# Owners come from each chart's securityContext (runAsUser:fsGroup). Where a chart declares
# none, the container runs as its image default — left root-owned here and marked, because
# guessing wrong yields a confusing permission error at first start rather than a clean one.
DIRS=(
  "timescaledb-ha/0|1000:1000|Patroni member 0"
  "timescaledb-ha/1|1000:1000|Patroni member 1"
  "timescaledb-ha/2|1000:1000|Patroni member 2"
  "kafka|1000:1000|broker log segments"
  "monitoring/prometheus|1000:2000|prometheus runs 1000:2000"
  "monitoring/grafana|472:472|grafana runs 472:472"
  "tigerbeetle||no securityContext in chart — image default"
)

for entry in "${DIRS[@]}"; do
  IFS='|' read -r rel owner note <<<"$entry"
  path="$ROOT/$rel"
  mkdir -p "$path"
  if [ -n "$owner" ]; then
    chown -R "$owner" "$path"
    printf '  %-34s %-11s %s\n' "$rel" "$owner" "$note"
  else
    printf '  %-34s %-11s %s\n' "$rel" "root:root" "$note"
  fi
done

# PGDATA must not be group/world readable or Postgres refuses to start.
# Only the Patroni members are listed: the single-node timescaledb/postgres charts are not
# provisioned here. Re-add their paths above AND here if you ever deploy them — the charts
# still declare PVs at /srv/k8s-volumes/{timescaledb,postgres}, so they would otherwise start
# against a directory that does not exist.
chmod 700 "$ROOT"/timescaledb-ha/? 2>/dev/null || true

echo
echo "==> $ROOT"
df -h "$ROOT" | awk 'NR==2{print "    "$2" total, "$4" free, mounted on "$6}'
ls -la "$ROOT"
