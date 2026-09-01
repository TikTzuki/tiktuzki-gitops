#!/usr/bin/env bash
#
# encrypt-file.sh — wrap a sensitive backup artifact (the Sealed-Secrets master key, a
# secrets dump, a DB dump) in AES-256 before it leaves this machine.
#
#   ./encrypt-file.sh ~/cluster-backups/sealed-secrets-key.yaml
#     -> ~/cluster-backups/sealed-secrets-key.yaml.gpg
#
# WHY SYMMETRIC (passphrase) AND NOT A GPG KEYPAIR
# ------------------------------------------------
# Encrypting a disaster-recovery backup to a public key creates a SECOND irreplaceable
# secret — the private key — which now also has to be backed up, on a machine that by
# definition may be the one that died. That is the same trap that lost the last master
# key. A passphrase you can hold in a password manager (or your head) has no such
# dependency: any machine with gpg can open the file.
#
# The trade-off is that the passphrase is the whole security boundary, so make it long.
# It is never passed on the command line or echoed — gpg prompts for it directly, which
# is also why this script must be run from a real terminal, not from an agent.
#
# Depends on: gpg, shasum/sha256sum.
#
set -euo pipefail

SRC="${1:-}"
[ -n "$SRC" ] || { echo "usage: $0 <file-to-encrypt>" >&2; exit 2; }
[ -f "$SRC" ] || { echo "ERROR: no such file: $SRC" >&2; exit 1; }

DST="${SRC}.gpg"
command -v gpg >/dev/null || { echo "ERROR: gpg not found" >&2; exit 1; }

# Refuse to clobber: an existing .gpg may be the only copy that matches a passphrase
# someone already wrote down.
[ -e "$DST" ] && { echo "ERROR: $DST already exists — move it aside first." >&2; exit 1; }

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}';
        else shasum -a 256 "$1" | awk '{print $1}'; fi; }

BEFORE="$(sha "$SRC")"

echo "==> encrypting $SRC (AES-256; you'll be prompted for a passphrase, twice)"
# --s2k-* : make an offline brute-force of the passphrase expensive.
gpg --symmetric \
    --cipher-algo AES256 \
    --s2k-mode 3 \
    --s2k-digest-algo SHA512 \
    --s2k-count 65011712 \
    --output "$DST" \
    "$SRC"

chmod 600 "$DST"

# Round-trip it. An encrypted backup nobody has ever decrypted is not a backup.
echo "==> verifying round-trip (passphrase prompt again)"
AFTER="$(gpg --quiet --decrypt "$DST" 2>/dev/null | sha /dev/stdin)"

if [ "$BEFORE" != "$AFTER" ]; then
  echo "ERROR: round-trip MISMATCH — $DST does not reproduce $SRC. Not deleting anything." >&2
  exit 1
fi

cat <<EOF

==> OK. $DST
    plaintext sha256 : $BEFORE
    encrypted size   : $(wc -c <"$DST" | tr -d ' ') bytes

NEXT
  1. Store the PASSPHRASE in your password manager, labelled with what it opens.
     Losing it is identical to losing the key.
  2. Copy $DST somewhere that is NOT this laptop and NOT node1 — those are the two
     machines a disaster takes out. Two destinations beats one.
  3. Once copied, remove the plaintext:
       rm -P "$SRC"
  4. Re-verify occasionally:
       gpg --decrypt "$DST" | shasum -a 256      # expect $BEFORE
EOF
