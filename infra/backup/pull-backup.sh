#!/usr/bin/env bash
#
# pull-backup.sh — fetch the newest backup from node1, encrypt it, and shred the plaintext.
# Run from your laptop (NOT on node1):
#
#   ./pull-backup.sh
#   BACKUP_HOST=tik@100.66.50.60 ./pull-backup.sh     # over the NetBird overlay, off-LAN
#
# WHY A SEPARATE STEP
# -------------------
# `cluster-backup.timer` on node1 writes to /srv/k8s-volumes/backups. That is STAGING, not a
# backup: ubuntu-vg/root and ubuntu-vg/k8s-data are two LVs on the SAME physical disk (sda),
# so a disk failure — the most likely hardware failure on that box — takes the cluster and
# every staged copy with it. Only what leaves node1 is a backup.
#
# Encryption happens HERE rather than on node1 on purpose. The archive contains nothing that
# is not already sitting on node1 in plaintext (dqlite holds every Secret, the CA key is in
# /var/snap, the Wi-Fi PSK is in /etc/netplan), so encrypting it there protects nothing — and
# would force a passphrase or private key onto the very machine being backed up. The risk
# starts when the archive leaves node1, which is exactly where this script encrypts it.
#
set -euo pipefail

HOST="${BACKUP_HOST:-tik@192.168.1.5}"
REMOTE_DIR="${BACKUP_REMOTE_DIR:-/srv/k8s-volumes/backups}"
LOCAL_DIR="${BACKUP_LOCAL_DIR:-$HOME/cluster-backups}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '\033[1;34m[pull]\033[0m %s\n' "$*"; }

[ -x "$HERE/encrypt-file.sh" ] || die "encrypt-file.sh not found next to this script"
command -v rsync >/dev/null || die "rsync not found"

log "looking for the newest run on $HOST:$REMOTE_DIR"
newest="$(ssh "$HOST" "ls -1d '$REMOTE_DIR'/20*-* 2>/dev/null | sort | tail -1" || true)"
[ -n "$newest" ] || die "no backup runs under $HOST:$REMOTE_DIR — has cluster-backup.timer fired yet?
    check with:  ssh $HOST 'systemctl list-timers cluster-backup.timer'"

stamp="$(basename "$newest")"
dest="$LOCAL_DIR/$stamp"
[ -e "$dest" ] && die "$dest already exists — already pulled this run?"
[ -e "$dest.tgz.gpg" ] && die "$dest.tgz.gpg already exists — already pulled and encrypted this run"

mkdir -p "$LOCAL_DIR"; chmod 700 "$LOCAL_DIR"
umask 077

log "rsync $stamp"
rsync -a --info=stats1 "$HOST:$newest/" "$dest/"

# A run that died mid-way still leaves a directory behind. The manifest is written last, so
# its presence is the marker that backup.sh actually reached the end.
[ -f "$dest/MANIFEST.txt" ] || die "$dest has no MANIFEST.txt — that run did not complete. \
Inspect it, then delete it and check: ssh $HOST 'journalctl -u cluster-backup.service -n 50'"

log "manifest:"
sed 's/^/    /' "$dest/MANIFEST.txt"

log "creating archive"
tar czf "$dest.tgz" -C "$LOCAL_DIR" "$stamp"

# encrypt-file.sh prompts for the passphrase and verifies the round-trip before returning 0,
# so reaching the next line means the ciphertext provably reproduces the archive.
"$HERE/encrypt-file.sh" "$dest.tgz"

log "shredding plaintext"
find "$dest" -type f -exec rm -P {} + 2>/dev/null || find "$dest" -type f -delete
rm -rf "$dest"
rm -P "$dest.tgz" 2>/dev/null || rm -f "$dest.tgz"

cat <<EOF

==> $dest.tgz.gpg

REMAINING STEP — this is still on one machine:
  Copy it somewhere that is neither this laptop nor node1. A disk failure in either
  currently loses a copy; only the third location makes this a real backup.

  Then optionally free the staging copy on node1 (the timer keeps 7 runs anyway):
      ssh $HOST 'rm -rf $newest'
EOF
