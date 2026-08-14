# timescaledb-ha

Three TimescaleDB nodes under Patroni, fronted by two proxies with two different jobs.

```
                    ┌── timescaledb-ha-0   (replica)
Kubernetes API ─────├── timescaledb-ha-1   (replica)
  (the DCS:         └── timescaledb-ha-2   (LEADER)
   leader lock is a          ▲        ▲
   ConfigMap)                │        │
                             │        └──── haproxy :5000  primary-only TCP passthrough
                             │              haproxy :5001  replicas-only
                             │
                    pgdog :6432   writes → leader, reads round-robin across all three
                                  ▲
                            applications
```

**Who does what.** Patroni elects and promotes. pgdog *only follows* — it polls
`pg_is_in_recovery()` on each node (`role = "auto"`) and re-points writes. HAProxy *only
follows* — it health-checks Patroni's REST `/primary`. Neither proxy ever calls
`pg_promote()`, which is why the Patroni layer has to exist at all.

Ported from `docker-compose.postgres-ha.yml` in `payment-platform-backend`.

## What changed from the compose stack

| compose | here | why |
|---|---|---|
| etcd container holds the leader lock | **Kubernetes API** (`kubernetes.use_endpoints: false`) | The compose README called its single-node etcd an admitted SPOF. In-cluster, the API server's etcd is already there and already replicated — one fewer stateful thing to run, back up, and lose. |
| `ghcr.io/zalando/spilo-18` | `timescale/timescaledb-ha` | Spilo has no TimescaleDB. This image ships TimescaleDB + Patroni and its entrypoint is `patroni /etc/timescaledb/patroni.yaml`, so the chart supplies a `patroni.yaml` ConfigMap. |
| `SPILO_CONFIGURATION` env blob | `patroni-configmap.yaml` + `PATRONI_*` env | Spilo-specific. Cluster-wide config goes in the ConfigMap; per-pod values (name, connect addresses, passwords) are `PATRONI_*` env vars, which override the file. |
| `container_name` / `hostname` | StatefulSet stable pod DNS | `timescaledb-ha-0.timescaledb-ha-headless.<ns>.svc.cluster.local`. pgdog and HAProxy address nodes individually, so they need per-pod names, not a Service. |
| bind mounts under `./docker/data/` | static local PVs, one per replica | This cluster has **no StorageClass** — nothing would provision `volumeClaimTemplates`. See "Storage" below. |
| `depends_on: service_healthy` | probes + `publishNotReadyAddresses` | Patroni does its own ordering through the leader lock. |
| HAProxy for Debezium | HAProxy **and** a `role: master` Service | Kubernetes can do "always the current primary" with a label selector. HAProxy stays for the one thing a Service cannot do — see below. |

### Why HAProxy is still here

`timescaledb-ha-primary` is a plain Service selecting `role: master`, a label Patroni rewrites
on its own pod the instant it promotes. That is a perfectly good always-current-primary
endpoint, and it costs nothing.

What it does **not** do: when a node stops being primary, removing it from Endpoints leaves
**ESTABLISHED sockets untouched**. A Debezium connector stays attached to a demoted node until
something times out — reading a WAL stream that is no longer the cluster's timeline. HAProxy's
`on-marked-down shutdown-sessions` severs those connections immediately.

So: **use the Service for ordinary clients, HAProxy for CDC.** And Debezium cannot use pgdog
at all — logical decoding speaks the streaming-replication protocol, which a transaction-mode
pooler does not proxy.

## Install

**1. Create the data directories on the node** (one per replica, owned by the image's
postgres UID):

```bash
sudo mkdir -p /home/tik/data/timescaledb-ha/{0,1,2}
sudo chown -R 1000:1000 /home/tik/data/timescaledb-ha
```

Skip this and the pods CrashLoop on `could not create directory ... Permission denied`.

**2. Seal the credentials.** The chart takes no inline passwords — `auth.existingSecret` is
required and every password is read from it.

```bash
kubectl create secret generic timescaledb-ha-secret \
  --namespace database \
  --from-literal=superuser-password="$(openssl rand -base64 24)" \
  --from-literal=replication-password="$(openssl rand -base64 24)" \
  --from-literal=app-password="$(openssl rand -base64 24)" \
  --from-literal=pgdog-admin-password="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace sealed-secrets \
           --controller-name sealed-secrets-controller \
           --format yaml \
> charts/timescaledb-ha/templates/sealedsecret.yaml
```

Record the generated values somewhere before you lose them — a sealed secret cannot be read
back out of Git.

**3. Register the Argo app**: `apps/base/timescaledb-ha.yaml`.

## Operating it

```bash
# Who is leader
kubectl -n database exec -it timescaledb-ha-0 -- patronictl list

# Patroni's own role label — exactly one pod should say master
kubectl -n database get pods -l cluster-name=timescaledb-ha -L role

# What pgdog thinks the topology is
kubectl -n database exec -it deploy/timescaledb-ha-pgdog -- \
  psql -h localhost -p 6432 -U admin -d admin -c "SHOW REPLICATION"
```

`SHOW SERVERS`, `SHOW POOLS`, `SHOW CLIENTS`, `RELOAD` all work on that admin console.

### Verifying failover

```bash
kubectl -n database exec -it timescaledb-ha-0 -- patronictl list   # note the leader
kubectl -n database delete pod timescaledb-ha-<leader>             # simulate node loss
kubectl -n database exec -it timescaledb-ha-0 -- patronictl list   # timeline bumped
```

The compose stack measured **27 seconds** from kill to writes resuming, almost all of it
waiting for the leader lease to expire. `values-dev.yaml` lowers `ttl` to 20 / `loopWait` to 5,
which trades safety for speed. Patroni enforces `ttl >= loop_wait + 2 * retry_timeout`.

Clients **will** see errors during that window. This is failover, not zero-downtime.

## ⚠️ Read/write split can serve stale reads

Replication is asynchronous. A read in a **separate transaction** immediately after a write can
land on a replica that has not replayed it. Measured on the compose stack under write load:
**9 of 15 write-then-read rounds returned stale data.**

Reads *inside* the writing transaction are safe — pgdog pins a transaction to one server.

For anything where a stale read is a correctness bug — idempotency probes, saga state,
read-after-migrate — set `pgdog.readWriteSplit: prefer_primary`.

## ⚠️ Changing postgresql.conf after bootstrap

`patroni.parameters` in values.yaml is copied into the DCS **once**, at bootstrap. After that
Patroni owns the live values and editing values.yaml changes nothing — the pods restart, read
the new ConfigMap, and ignore it.

To change a parameter on a running cluster:

```bash
kubectl -n database exec -it timescaledb-ha-0 -- patronictl edit-config
```

`wal_level`, `max_connections`, `max_worker_processes`, `max_replication_slots` and friends are
postmaster-level: `patronictl restart <cluster>` afterwards, not a reload.

This is a genuine gap in the GitOps story — the DCS, not Git, is the source of truth for these
once the cluster exists. Keep values.yaml in sync by hand so a rebuild starts from the right
place.

## Wiping and re-bootstrapping

`bootstrap.post_init` runs once, ever. To re-run it (e.g. after changing `bootstrap.schemas`)
the cluster has to be destroyed:

```bash
kubectl -n database delete statefulset timescaledb-ha
kubectl -n database delete pvc -l cluster-name=timescaledb-ha
kubectl -n database delete configmap timescaledb-ha-leader timescaledb-ha-config \
                                     timescaledb-ha-failover timescaledb-ha-sync
sudo rm -rf /home/tik/data/timescaledb-ha/*/*   # on node1
```

Deleting the PVCs without deleting those ConfigMaps is the classic deadlock: the DCS still
holds the cluster's `initialize` key while every PGDATA is empty, and Patroni sits forever on
*"waiting for leader to bootstrap"*.

## Single-node caveat

`kubectl get nodes` returns one node. Three replicas on one machine gives you real *process*
failover to rehearse against and nothing else — the node dying takes all three with it.
`podAntiAffinity.type` is `soft` for exactly this reason; a hard rule would leave two pods
Pending forever. Flip it to `hard` the moment there is a second node.

## Connecting an application

```
host     timescaledb-ha-pgdog.database.svc.cluster.local
port     6432
user     app          (bootstrap.username)
database app          (bootstrap.database)
```

For JDBC behind a transaction pooler, disable server-side prepared statements —
`prepareThreshold=0` (JDBC) or `preparedStatementCacheQueries=0` (r2dbc). Prepared statements
live on a *shared* pooled backend: a migration that alters a table changes the result type of
an already-cached plan, and the next execute raises `0A000 cached plan must not change result
type`. Behind a pooler the poisoned connection can outlive an app restart.
