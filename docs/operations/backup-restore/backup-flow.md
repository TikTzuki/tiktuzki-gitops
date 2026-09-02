---
title: "Backing up the cluster"
tags: [kubernetes, storage]
sidebar_position: 1
---

# Backing up node1

The cluster's **desired state** — ArgoCD Applications, Helm charts, values — already lives in
this same repo. Backup only has to capture what Git does *not* hold, which turns
"clone the whole server" into a much smaller problem.

Two steps, one nightly timer:

|             | What runs               | What it does                                                               |
|-------------|-------------------------|----------------------------------------------------------------------------|
| **Collect** | `backup.sh`             | writes a timestamped run to `/srv/k8s-volumes/backups`, keeps the newest 7 |
| **Ship**    | `cluster-backup upload` | archives, encrypts and pushes it to S3                                     |

Both fire from `cluster-backup.timer` at 02:30 daily. The second is the one that matters.

:::danger[The copy on node1 is not a backup]
`ubuntu-vg/root` and `ubuntu-vg/k8s-data` are two LVs on the **same physical disk** (`sda`).
A disk failure — the likeliest hardware failure on that box — destroys the cluster and all
seven staged runs together.

Local staging exists so the upload has something to read. **S3 is the backup.**
:::

## What gets captured

`backup.sh` collects five things:

1. **Database dumps** — `pg_dumpall` per cluster. The Patroni cluster is resolved by its
   `role=master` label, never a fixed pod name: the leader moves between
   `timescaledb-ha-{0,1,2}` on every failover, and a hardcoded ordinal silently dumps
   whichever replica happens to sit there.
2. **Volume data** — tarballs of the local PV directories under `/srv/k8s-volumes`.
3. **Secrets** — every Secret in every namespace, excluding ServiceAccount tokens and Helm
   release blobs, both of which regenerate.
4. **Sealed-Secrets master key** — the one secret whose loss is unrecoverable: without it
   every committed `SealedSecret` is permanently undecryptable.
5. **Node-level state** — `certs/` including **`ca.key`** (lose it and every kubeconfig ever
   minted here is invalid), the dqlite datastore, `/etc/netplan` (which carries the Wi-Fi PSK
   in cleartext), NetBird peer identity, and `node-info.txt`.

Deliberately **not** captured: the Prometheus TSDB (large, re-derivable), Ollama model blobs
(re-downloadable, tens of GB), and application logs.

## Two halves, two storage classes

`cluster-backup` splits each run in two and files them differently.

| half       | contents                                  | class          | retrieval       |
|------------|-------------------------------------------|----------------|-----------------|
| `critical` | manifest, master key, secrets, node state | `STANDARD_IA`  | immediate       |
| `bulk`     | `db/`, `data/`                            | `DEEP_ARCHIVE` | **12–48 hours** |

:::danger[Never put the master key in Deep Archive]
Deep Archive takes 12–48 hours to thaw. If the Sealed-Secrets master key and the microk8s CA
live only there, a rebuild cannot *start* for up to two days — you would be sitting on a dead
cluster waiting for AWS.

The critical half is tens of kilobytes. Keeping it instantly retrievable costs fractions of a
cent per month, and is the difference between rebuilding tonight and rebuilding on Thursday.
:::

Objects land at `s3://BUCKET/PREFIX/{critical,bulk}/YYYYmmdd-HHMMSS.tar.zst.age`.

**Cadence differs too.** Deep Archive bills a **180-day minimum per object** regardless of when
you delete it, so uploading gigabytes daily bills roughly 180 copies at steady state rather
than 7. The critical half goes up every night; the bulk half only on `UPLOAD_BULK_DOW`
(default Sunday).

## Encryption

node1 holds only an age **recipient** — a public key. It can encrypt and upload, and cannot
read back a byte of what it sent. The identity file never touches it.

This matters because the machine producing the archive *is* the machine being backed up. A
passphrase would have to live in a file on that host, so anyone who stole an archive would
also hold its key.

The pipeline is `tar -> zstd -> age`, in that order. Compressing after encrypting would
*inflate* the archive, since age output is indistinguishable from random.

## Prerequisites

- `/srv/k8s-volumes` mounted and in `/etc/fstab`; volume dirs created by
  `infra/storage/create-volume-dirs.sh`
- an S3 bucket, and an IAM user for node1
- an age keypair, generated **on your laptop**
- the `cluster-backup` binary, from the `tik_scripts` release

## Step 1 — the collection timer

If `cluster-backup.timer` is already enabled, skip to step 2.

:::danger[Use one `install -T` per file]
`install a b` with no trailing directory copies `a` **over** `b`. Collapsing these into one
multi-source command means a truncated paste silently overwrites one unit with the other's
contents — which surfaces later as `Unknown section 'Service'` from the timer. `-T` names the
destination explicitly, so the same slip fails loudly instead.
:::

```bash
sudo install -d /opt/cluster-backup
sudo install -m755 -T infra/backup/backup.sh  /opt/cluster-backup/backup.sh
sudo install -m644 -T infra/backup/RESTORE.md /opt/cluster-backup/RESTORE.md
# this file too — a rebuild needs it and may not have GitHub
sudo install -m644 -T docs/operations/backup-restore/backup-flow.md /opt/cluster-backup/backup-flow.md
sudo install -m644 -T infra/backup/systemd/cluster-backup.service /etc/systemd/system/cluster-backup.service
sudo install -m644 -T infra/backup/systemd/cluster-backup.timer   /etc/systemd/system/cluster-backup.timer

grep -c '^\[Service\]' /etc/systemd/system/cluster-backup.timer   # must print 0

sudo systemctl daemon-reload
sudo systemctl enable --now cluster-backup.timer
sudo systemctl start cluster-backup.service       # produce a run to work with
```

A systemd timer rather than cron for one reason: `Persistent=true`. If the node is off at
02:30 the run happens at next boot instead of being skipped in silence.

## Step 2 — bucket, IAM and keypair

Create the bucket with **versioning on**, and ideally Object Lock, so a stolen key cannot
rewrite history.

Give node1 an IAM user with only this:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:AbortMultipartUpload"],
      "Resource": "arn:aws:s3:::YOUR-BUCKET/node1/*"
    }
  ]
}
```

A host that cannot delete or read its own backups cannot be made to destroy them — which is
the entire point of pushing them off the box.

:::note[Verification needs one more permission]
`cluster-backup` calls `head_object` after each upload to confirm size and storage class. That
needs `s3:GetObject`. Add it and uploads are verified; leave it out and they are not. The
least-privilege side is the better default for an unattended host, but the trade is real.
:::

Generate the keypair on your laptop, **never on node1**:

```bash
brew install age
age-keygen -o backup-identity.txt      # prints the age1… public key
```

:::danger[The identity file is now as critical as the master key]
`backup-identity.txt` decrypts every archive you will ever upload. Put it in your password
manager. Losing it means the backups exist and cannot be opened — the same class of failure
as losing the Sealed-Secrets key, which is what forced the last rebuild.
:::

## Step 3 — install the binary

`cluster-backup` lives in `tik_scripts/crates/cluster-backup`. CI builds it for six targets
and attaches them to a GitHub release; take the **musl** one, which is static-pie and has no
glibc coupling.

```bash
# from the tik_scripts checkout, once the release workflow has run for your tag
gh release download vX.Y.Z -p 'cluster-backup-x86_64-unknown-linux-musl'
scp cluster-backup-x86_64-unknown-linux-musl tik@100.66.50.60:/tmp/
ssh -t tik@100.66.50.60 \
  'sudo install -m755 -T /tmp/cluster-backup-x86_64-unknown-linux-musl /opt/cluster-backup/cluster-backup'
```

To cut a release: tag the commit, push the tag, then dispatch `release-bin.yml`
**against that tag** — the workflow attaches assets to the release for the ref it runs on, so
dispatching from a branch produces nothing.

## Step 4 — configure and prove it by hand

```bash
sudo install -d -m700 /etc/cluster-backup
sudo install -m600 -T infra/backup/systemd/s3.env.example /etc/cluster-backup/s3.env
sudo nano /etc/cluster-backup/s3.env     # bucket, region, age1… recipient, AWS keys
```

Credentials go in that file, mode 0600, rather than `Environment=` lines in the unit — a unit
file is world-readable and this holds a live AWS secret key.

Now run it manually, before it is anywhere near the timer:

```bash
sudo /opt/cluster-backup/cluster-backup plan          # what would be uploaded?
sudo env $(grep -v '^#' /etc/cluster-backup/s3.env | xargs) \
     /opt/cluster-backup/cluster-backup upload --force-bulk
```

`--force-bulk` overrides the weekday check so you exercise both halves once.

## Step 5 — wire it into the timer

Only after step 4 succeeds:

```bash
sudo install -d -m755 /etc/systemd/system/cluster-backup.service.d
sudo install -m644 -T infra/backup/systemd/cluster-backup.service.d/10-s3-upload.conf \
     /etc/systemd/system/cluster-backup.service.d/10-s3-upload.conf
sudo systemctl daemon-reload
sudo systemctl start cluster-backup.service
```

This is a **drop-in**, not an edit to the base unit. Without it the service still collects and
stages locally; with it, uploads run. There is no half-configured state that fails every night
at 02:30, and removing the file plus `daemon-reload` cleanly disables uploads.

The drop-in has no `-` prefix on `ExecStartPost` on purpose: a failed upload marks the unit
failed and shows in `systemctl --failed`. A backup that silently stops leaving the node is
exactly the failure this exists to prevent, and the staged copy is already written by then, so
failing loudly costs nothing.

## Optional — a local copy as well

`pull-backup.sh` rsyncs the newest run to your laptop, encrypts it with a passphrase and
shreds the plaintext. It is now a *convenience*, not the strategy: useful when you want a copy
in hand without waiting on S3, and independent of AWS being reachable.

```bash
./infra/backup/pull-backup.sh
BACKUP_HOST=tik@100.66.50.60 ./infra/backup/pull-backup.sh   # off-LAN, over the overlay
```

It uses a passphrase rather than the age key because a human is present to type one.

## Operating it

```bash
systemctl list-timers cluster-backup.timer            # when does it next run?
sudo systemctl start cluster-backup.service           # run now
sudo journalctl -u cluster-backup.service -n 50       # why did last night fail?
aws s3 ls s3://YOUR-BUCKET/node1/critical/            # what actually landed?
```

Retention is split: `BACKUP_KEEP` (default 7) prunes local runs, while S3 objects persist
until a bucket lifecycle rule removes them. Set one, remembering the 180-day minimum makes
early deletion of Deep Archive objects pointless.

:::caution[Retention keeps old secrets alive]
A credential you rotate today stays readable in older archives. That is the trade for having
history; shorten it if it matters more than history does.
:::

## Restoring

The full runbook is [`infra/backup/RESTORE.md`](https://github.com/TikTzuki/tiktuzki-gitops/blob/main/infra/backup/RESTORE.md), installed to
`/opt/cluster-backup/RESTORE.md` on the node so it survives alongside the backup.

The critical half is immediate:

```bash
aws s3 cp s3://YOUR-BUCKET/node1/critical/20260901-093329.tar.zst.age .
age -d -i backup-identity.txt 20260901-093329.tar.zst.age | zstd -d | tar xv
```

The bulk half must be thawed first, and this is the step people forget:

```bash
aws s3api restore-object --bucket YOUR-BUCKET \
  --key node1/bulk/20260901-093329.tar.zst.age \
  --restore-request 'Days=7,GlacierJobParameters={Tier=Standard}'

# Standard ~12h, Bulk up to 48h. Poll until Restore says ongoing-request="false":
aws s3api head-object --bucket YOUR-BUCKET \
  --key node1/bulk/20260901-093329.tar.zst.age --query Restore
```

Start the thaw **first**, then restore the critical half and rebuild the cluster while it
runs. The two are independent, and sequencing them that way hides most of the 12 hours.

:::danger[A restore you have never performed is a hypothesis]
Every script in this flow had a bug that appeared only when it was executed — a GNU-only
`find -printf` that killed the run after writing secrets but before the manifest, a quoted
`"$KUBECTL"` that could not invoke `microk8s kubectl` on the one host it was written for, and
an rsync flag that does not exist in macOS's `openrsync`. Reading a backup script proves
nothing about it.
:::

## Troubleshooting

| Symptom                                        | Cause / fix                                                                                                                          |
|------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------|
| `has no MANIFEST.txt — incomplete run`         | The collection step died partway. `journalctl -u cluster-backup.service`. Never treat that directory as a backup.                    |
| `unknown storage class 'DEEP-ARCHIVE'`         | It is `DEEP_ARCHIVE`. Rejected deliberately — letting S3 default to `STANDARD` is how you store terabytes at 20× the intended price. |
| `not a valid age recipient`                    | `AGE_RECIPIENT` must be the `age1…` **public** key, not the identity file.                                                           |
| `no AWS region configured`                     | Set `AWS_REGION` in `/etc/cluster-backup/s3.env`.                                                                                    |
| `head_object … AccessDenied`                   | The IAM user lacks `s3:GetObject`. Either add it or accept unverified uploads.                                                       |
| Uploads stored as `STANDARD`                   | A bucket lifecycle rule is overriding the requested class. The binary warns rather than failing; the data is intact.                 |
| `Unknown section 'Service'` from the timer     | The service file's contents were copied over the timer. Reinstall with `install -T`.                                                 |
| `rsync: unrecognized option '--info=stats1'`   | macOS `openrsync`. Already fixed in `pull-backup.sh`; use `--stats`.                                                                 |
| `ERROR: /srv/k8s-volumes is not a mount point` | The data LV is not mounted; creating dirs would fill the 118 GB root filesystem.                                                     |
| Volume tarballs only ~130 bytes                | Correct when the volumes are empty.                                                                                                  |
