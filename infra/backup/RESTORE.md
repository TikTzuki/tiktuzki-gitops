# Disaster Recovery — rebuild this cluster on a new server

This cluster is **GitOps-managed**: its entire desired state (ArgoCD Applications, Helm charts,
values) lives in this repo. A migration is therefore *not* a full-server clone — it's:

> fresh microk8s → restore data + secrets → bootstrap ArgoCD at this repo → it rebuilds everything.

`backup.sh` captures the four things Git does **not** hold. This runbook consumes that backup.

---

## ⚠️ The three things that break a "plug-and-run" migration

1. **Node name must be `node1`.** Every local PV pins `nodeAffinity` to
   `kubernetes.io/hostname: node1`, and microk8s derives the node name from the OS hostname.
   On the new box: `sudo hostnamectl set-hostname node1` **before** installing microk8s.
2. **A dedicated volume must be mounted at `/srv/k8s-volumes`, and the directories under it
   must pre-exist** with the right ownership. Every chart here ships a static local PV at an
   explicit path (`charts/*/templates/pv.yaml`) — a local PV never creates its own directory,
   and without an `fsGroup` the kubelet never chowns it, so a missing or misowned directory
   surfaces as CrashLoopBackOff with a permission error rather than a scheduling failure.
   `infra/storage/create-volume-dirs.sh` creates all of them; it refuses to run unless the
   volume is actually mounted, because otherwise the data lands on the much smaller root
   filesystem and fills it.
3. **External edge is outside k8s.** NPM (TLS, `*.tiktuzki.com`), the NetBird overlay, and DNS
   are repointed to the new node's IP separately — none of it is in the cluster.

---

## Restore procedure (run on the NEW server)

### 0a. Start the Deep Archive thaw — do this FIRST

The bulk half sits in Glacier Deep Archive and takes **12-48 hours** to become readable. Kick
it off before anything else; the whole rebuild below runs while it thaws, which hides almost
all of that wait. Forget it and you will finish the rebuild and then sit idle for half a day.

```bash
STAMP=20260901-093329           # the run you are restoring
aws s3api restore-object --bucket "$S3_BUCKET" \
  --key "node1/bulk/$STAMP.tar.zst.age" \
  --restore-request 'Days=7,GlacierJobParameters={Tier=Standard}'
```

### 0b. Fetch and open the critical half

`STANDARD_IA`, so this one is immediate. It carries the master key, the CA, the secrets and
the node state — everything the steps below need.

```bash
aws s3 cp "s3://$S3_BUCKET/node1/critical/$STAMP.tar.zst.age" .
age -d -i backup-identity.txt "$STAMP.tar.zst.age" | zstd -d | tar xv
```

`backup-identity.txt` is the age private key from your password manager. It never existed on
node1 — that is deliberate, and it is why a stolen node could not read its own backups.

Later, once the thaw completes (poll with
`aws s3api head-object --bucket "$S3_BUCKET" --key "node1/bulk/$STAMP.tar.zst.age" --query Restore`
until `ongoing-request` reads `false`), fetch the bulk half the same way. It supplies
`db/` and `data/` for steps 1 and 5.

### 0c. Prereqs on the new host
```bash
sudo hostnamectl set-hostname node1                       # gotcha #1

# gotcha #2 — the data volume. On the original node this is ubuntu-vg/k8s-data (500G)
# mounted at /srv/k8s-volumes via /etc/fstab. Recreate it, mount it, THEN:
sudo ./infra/storage/create-volume-dirs.sh
# That script owns the full path+ownership table, so it stays correct as charts are added.
# It aborts if /srv/k8s-volumes is not a mount point.
```

### 1. Restore raw volume data (BEFORE deploying workloads)
```bash
for t in <backup>/data/*.tgz; do sudo tar xzf "$t" -C /; done
```
This puts tigerbeetle/kafka/cv-hub/openclaw/checkin (and the raw DB files) back. Databases are
*also* restored logically in step 5 — prefer the logical dump for Postgres/TimescaleDB
(version-portable); the raw tar is the fallback only if the destination runs the **identical**
PG major version.

> **Skip the `timescaledb-ha` tarball unless you know you want it.** Those dirs are a live copy
> of three Patroni members' PGDATA, and the DCS state that says who was leader lives in
> Kubernetes endpoints — not in the tar. Restoring them onto an empty cluster makes three nodes
> that each believe they were primary. The supported path is: let Patroni bootstrap a **fresh**
> empty cluster, then logically restore into the leader (step 5). Re-`chown 1000:1000` and
> **empty** `/srv/k8s-volumes/timescaledb-ha/{0,1,2}` if you extracted them by accident.

### 2. Install microk8s + enable addons
```bash
sudo snap install microk8s --classic
sudo microk8s enable dns hostpath-storage ingress    # match the addons the old cluster used
sudo microk8s status --wait-ready
```

### 3. Restore Sealed-Secrets key, then the controller  *(if using Sealed Secrets — option b)*
The committed `SealedSecret` manifests can only be decrypted by the **original** controller key.
Restore it first, so the freshly-deployed controller adopts it instead of generating a new one:
```bash
microk8s kubectl create namespace sealed-secrets
microk8s kubectl apply -f <backup>/sealed-secrets-key.yaml
# controller itself is deployed by ArgoCD in step 4 (apps/base/sealed-secrets.yaml);
# on startup it picks up the restored key and can decrypt your committed SealedSecrets.
```
See `infra/sealed-secrets/README.md` for the full workflow.

### 4. Restore secrets + bootstrap ArgoCD
```bash
# Secrets NOT yet migrated to SealedSecrets still need to be applied directly:
microk8s kubectl apply -f <backup>/secrets/        # plaintext secret backups
# Bootstrap GitOps — ArgoCD then pulls THIS repo and recreates every app:
microk8s kubectl apply -f bootstraps/namespaces.yaml
microk8s kubectl apply -f bootstraps/argocd/install.yaml
# register the root app-of-apps / apps-base the same way the source cluster did
```
> Note: `argocd-secret` (in the secrets backup) holds the **repo SSH deploy key + server signing
> key** — ArgoCD can't pull this private repo without it. Apply it before ArgoCD starts syncing,
> or re-add the repo credentials in the ArgoCD UI.

### 5. Restore database contents (AFTER the DB pods are Running, empty)

**TimescaleDB-HA (Patroni).** Wait until one pod carries `role=master` and the other two report
`streaming` — restore into the **leader only**; the replicas pick it up over streaming
replication. Never restore into a replica (it is read-only) or into all three.
```bash
LEADER=$(microk8s kubectl -n database get pod \
  -l app.kubernetes.io/name=timescaledb-ha,role=master -o jsonpath='{.items[0].metadata.name}')
gunzip -c <backup>/db/timescaledb-ha.sql.gz \
  | microk8s kubectl -n database exec -i "$LEADER" -- psql -U postgres
microk8s kubectl -n database exec "$LEADER" -- patronictl list   # all members streaming?
```

**Single-node charts** (only if still deployed):
```bash
gunzip -c <backup>/db/timescaledb-0.sql.gz | microk8s kubectl -n database exec -i timescaledb-0 -- psql -U postgres
gunzip -c <backup>/db/postgres-0.sql.gz    | microk8s kubectl -n database exec -i postgres-0    -- psql -U postgres
```

**TimescaleDB note:** restoring hypertables via `pg_dumpall` needs the extension handled —
on the target run `SELECT timescaledb_pre_restore();` … restore … `SELECT timescaledb_post_restore();`
(or dump per-DB with `pg_dump` and follow the Timescale restore guide). Plain Postgres DBs restore as-is.
The pre/post-restore calls go to the **leader**, and `timescaledb_post_restore()` needs a fresh
session — reconnect after it before checking the data.

### 6. Repoint the external edge
- NPM proxy hosts (`*.tiktuzki.com`, the `:9094` Kafka stream, etc.) → new node IP.
- NetBird overlay → new node; DNS A records if not via overlay.

---

## Verify
```bash
microk8s kubectl get applications -n devops          # all Synced/Healthy
microk8s kubectl get pods -A | grep -vE 'Running|Completed'   # nothing stuck
# spot-check data: row counts, TigerBeetle account lookups, a Keycloak login, cv-hub uploads.
```

## How backups actually run

One timer, two steps. The second is the one that matters.

| | What runs | What it does | Schedule |
|---|---|---|---|
| **Collect** | `backup.sh` | writes a timestamped run to `/srv/k8s-volumes/backups`, keeps 7 | daily 02:30, `Persistent=true` |
| **Ship** | `cluster-backup upload` | archives, encrypts to an age recipient, pushes to S3 | same run, via drop-in |

The upload splits each run in two, because Deep Archive takes 12-48 hours to thaw:

| half | contents | class | cadence |
|---|---|---|---|
| `critical` | manifest, master key, secrets, node state | `STANDARD_IA` | every run |
| `bulk` | `db/`, `data/` | `DEEP_ARCHIVE` | `UPLOAD_BULK_DOW`, default Sunday |

Putting the master key and CA in Deep Archive would mean a rebuild cannot *start* for up to
two days. The critical half is tens of kilobytes, so keeping it warm is effectively free.
Bulk is weekly because Deep Archive bills a 180-day minimum per object regardless of deletion.

> ⚠️ **The staged copy on node1 is not a backup.** `ubuntu-vg/root` and `ubuntu-vg/k8s-data`
> are two LVs on the *same physical disk* (`sda`). A disk failure — the likeliest hardware
> failure on that box — destroys the cluster and all seven staged runs together. Local staging
> exists so the upload has something to read; **S3 is the backup**.

> `pull-backup.sh` still exists and pulls a passphrase-encrypted copy to your laptop. It is a
> convenience now, not the strategy: handy when you want a copy in hand, and independent of
> AWS being reachable.

`Persistent=true` is why this is a systemd timer and not cron: if the node is off at 02:30 the
run happens at next boot instead of being skipped in silence.

### Install on node1

One `install -T` per file, each with an explicit destination **filename**. Do not collapse
these into a single multi-source command: `install a b` with no trailing directory copies
`a` over `b`, so a truncated paste silently overwrites one unit with another's contents —
which produces `Unknown section 'Service'` from the timer and a unit that refuses to load.
`-T` makes the destination unambiguous, so the same mistake fails loudly instead.

```bash
sudo install -d /opt/cluster-backup
sudo install -m755 -T infra/backup/backup.sh   /opt/cluster-backup/backup.sh
sudo install -m644 -T infra/backup/RESTORE.md  /opt/cluster-backup/RESTORE.md
sudo install -m644 -T infra/backup/systemd/cluster-backup.service /etc/systemd/system/cluster-backup.service
sudo install -m644 -T infra/backup/systemd/cluster-backup.timer   /etc/systemd/system/cluster-backup.timer

# Confirm each unit is what it should be BEFORE loading it.
head -1 /etc/systemd/system/cluster-backup.timer     # must be [Unit], with [Timer] below
grep -c '^\[Service\]' /etc/systemd/system/cluster-backup.timer   # must print 0

sudo systemctl daemon-reload
sudo systemctl enable --now cluster-backup.timer
systemctl list-timers cluster-backup.timer      # a NEXT time must be shown
```

### Then the S3 uploader

`cluster-backup` is a Rust binary from `tik_scripts`. CI publishes one per target; take the
**musl** build, which is static-pie and has no glibc coupling.

```bash
gh release download vX.Y.Z -p 'cluster-backup-x86_64-unknown-linux-musl'   # on the laptop
scp cluster-backup-x86_64-unknown-linux-musl tik@node1:/tmp/
sudo install -m755 -T /tmp/cluster-backup-x86_64-unknown-linux-musl /opt/cluster-backup/cluster-backup

sudo install -d -m700 /etc/cluster-backup
sudo install -m600 -T infra/backup/systemd/s3.env.example /etc/cluster-backup/s3.env
sudo nano /etc/cluster-backup/s3.env      # bucket, region, age1… recipient, AWS keys
```

Prove it by hand **before** the timer touches it:

```bash
sudo /opt/cluster-backup/cluster-backup plan
sudo env $(grep -v '^#' /etc/cluster-backup/s3.env | xargs) \
     /opt/cluster-backup/cluster-backup upload --force-bulk
```

Only then install the drop-in that wires it into the nightly run:

```bash
sudo install -d -m755 /etc/systemd/system/cluster-backup.service.d
sudo install -m644 -T infra/backup/systemd/cluster-backup.service.d/10-s3-upload.conf \
     /etc/systemd/system/cluster-backup.service.d/10-s3-upload.conf
sudo systemctl daemon-reload
sudo systemctl start cluster-backup.service
```

A drop-in rather than lines in the base unit: without it the service still collects and stages
locally, so there is no half-configured state failing nightly. Deleting it plus a
`daemon-reload` disables uploads and leaves collection running.

### Operating it
```bash
sudo systemctl start cluster-backup.service     # run once, now
journalctl -u cluster-backup.service -f         # watch it
journalctl -u cluster-backup.service -n 50      # why did last night fail?
aws s3 ls s3://$S3_BUCKET/node1/critical/       # what actually landed offsite?
./infra/backup/pull-backup.sh                   # optional local copy, from the LAPTOP
```

### Hygiene
- The staged run is **plaintext**: every cluster Secret, the Sealed-Secrets master key, the
  microk8s CA private key and the Wi-Fi PSK. It is `0700 tik` on node1 and encrypted before it
  leaves. Never copy an unencrypted run anywhere else.
- node1 holds only the age **public** key. It can encrypt and upload and cannot read back what
  it sent, which matters because the host producing the archive is the host being backed up.
- `backup-identity.txt` is now as critical as the master key: it decrypts every archive. It
  belongs in a password manager and nowhere on node1.
- Give the node's IAM user `s3:PutObject` only. A host that cannot delete its own backups
  cannot be made to destroy them.
- Retention keeps old secrets alive: a credential rotated today is still readable in older
  archives. Shorten `BACKUP_KEEP` and the bucket lifecycle if that matters more than history.
- A restore you have never performed is a hypothesis. Test one — including the Deep Archive
  thaw, which is the part with a 12-48 hour surprise in it.
