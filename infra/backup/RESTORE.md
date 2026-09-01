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

### 0. Prereqs
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

Two halves, because neither is sufficient alone.

| | Where | What | Schedule |
|---|---|---|---|
| **Stage** | node1, `cluster-backup.timer` → `backup.sh` | writes a timestamped run to `/srv/k8s-volumes/backups`, keeps 7 | daily 02:30, `Persistent=true` |
| **Retain** | your laptop, `pull-backup.sh` | rsyncs the newest run, encrypts it, shreds the plaintext | manual |

> ⚠️ **The staged copy on node1 is not a backup.** `ubuntu-vg/root` and `ubuntu-vg/k8s-data`
> are two LVs on the *same physical disk* (`sda`). A disk failure — the likeliest hardware
> failure on that box — destroys the cluster and all seven staged runs together. Only what
> `pull-backup.sh` takes off the node counts, and only once it also exists somewhere that is
> not your laptop.

`Persistent=true` is why this is a systemd timer and not cron: if the node is off at 02:30 the
run happens at next boot instead of being skipped in silence.

### Install on node1
```bash
sudo mkdir -p /opt/cluster-backup
sudo cp infra/backup/backup.sh infra/backup/RESTORE.md /opt/cluster-backup/
sudo chmod 755 /opt/cluster-backup/backup.sh
sudo cp infra/backup/systemd/cluster-backup.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now cluster-backup.timer
systemctl list-timers cluster-backup.timer      # confirm a NEXT time is scheduled
```

### Operating it
```bash
sudo systemctl start cluster-backup.service     # run once, now
journalctl -u cluster-backup.service -f         # watch it
journalctl -u cluster-backup.service -n 50      # why did last night fail?
./infra/backup/pull-backup.sh                   # from the LAPTOP; prompts for a passphrase
```

### Hygiene
- Output is **plaintext**: every cluster Secret, the Sealed-Secrets master key, the microk8s
  CA private key and the Wi-Fi PSK. It is `0700 tik` on node1 and encrypted the moment it
  leaves. Never copy an unencrypted run anywhere else.
- Encryption deliberately happens on the laptop, not node1. The archive holds nothing that is
  not already on node1 in the clear, so encrypting it there would protect nothing while
  forcing a passphrase or private key onto the machine being backed up.
- Retention keeps old secrets alive: a credential rotated today is still readable in
  yesterday's run for 7 days. Shorten `BACKUP_KEEP` if that matters more than history.
- A restore you have never performed is a hypothesis. Test one.
