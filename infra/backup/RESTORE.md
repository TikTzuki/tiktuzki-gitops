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
2. **hostPath dirs must pre-exist** at the same paths with the right ownership, or PVs won't
   mount: the single-node Postgres/TimescaleDB want uid/gid **999**; Kafka, TimescaleDB-HA and
   openclaw want **1000**. TimescaleDB-HA additionally needs **one subdir per replica**
   (`.../timescaledb-ha/{0,1,2}`) — the chart creates a static local PV per ordinal.
3. **External edge is outside k8s.** NPM (TLS, `*.tiktuzki.com`), the NetBird overlay, and DNS
   are repointed to the new node's IP separately — none of it is in the cluster.

---

## Restore procedure (run on the NEW server)

### 0. Prereqs
```bash
sudo hostnamectl set-hostname node1                       # gotcha #1
# create the hostPath dirs (gotcha #2) — match your deployed values-dev.yaml files:
sudo mkdir -p /home/tik/data/{timescaledb,postgres,tigerbeetle,kafka,cv-hub/uploads,room-manager/logs}
sudo mkdir -p /home/tik/data/{openclaw,checkin-data,ollama-models}
sudo mkdir -p /home/tik/data/timescaledb-ha/{0,1,2}       # one per Patroni replica
sudo chown -R 999:999   /home/tik/data/{timescaledb,postgres}
sudo chown -R 1000:1000 /home/tik/data/{kafka,timescaledb-ha,openclaw}
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
> **empty** `/home/tik/data/timescaledb-ha/{0,1,2}` if you extracted them by accident.

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

## Backup hygiene
- `backup.sh` output contains **plaintext secrets and DB data** — store it encrypted/off-box.
- Schedule it (cron on node1, or a k8s CronJob) and keep N rotated copies.
- Adopting Sealed Secrets (option b) shrinks the secret-backup surface to a **single** key file
  (`sealed-secrets-key.yaml`); everything else then lives safely in Git.
