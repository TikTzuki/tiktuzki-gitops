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

## Users

Every password lives in the `timescaledb-ha-secret` Secret (`auth.existingSecret`). Nothing in
this chart accepts an inline password.

| User | Secret key | Created by | Postgres role? | What it is for |
|---|---|---|---|---|
| `postgres` | `superuser-password` | Patroni, at bootstrap | superuser | Admin work the app role cannot do: extensions, `patronictl`, migrations. Also `pg_rewind` — no separate rewind role is configured, so Patroni falls back to the superuser. |
| `app` | `app-password` | `post_init` hook | LOGIN, owns the `app` database, **`pg_monitor`** | The application role. pgdog authenticates to the backends as this user. |
| `standby` | `replication-password` | Patroni, at bootstrap | REPLICATION | Streaming replication and `pg_basebackup` clones, between pods only. Never use it from an application. |
| `admin` | `pgdog-admin-password` | — | **no** | pgdog's *own* console credential. See the warning below. |

Change the usernames via `auth.superuserUsername`, `auth.replicationUsername`, and
`bootstrap.username`; the keys via `auth.secretKeys.*`.

**`admin` is not a Postgres role.** It exists only inside pgdog and only on pgdog's admin
database. Connecting to a Postgres node as `admin` fails — the role does not exist there.

**Why `app` has `pg_monitor`.** pgdog runs `role = "auto"`, which means it polls
`pg_is_in_recovery()` and `pg_current_wal_lsn()` *as the app role* to work out which node is
the leader and how far the replicas lag. Revoke `pg_monitor` and pgdog stops seeing the
topology: the read/write split silently keeps sending writes to a demoted node.

### Roles this chart does NOT create

The compose stack's `post-init.sh` also created `debezium` (LOGIN REPLICATION), `cdc_reader`
(the group role holding the outbox table grants), and `pgmon` (for postgres_exporter). None of
them are here — this chart's bootstrap is deliberately generic.

If you need CDC or per-node metrics, add them through `bootstrap.extraSQL` **before the first
install**. `post_init` runs once, ever; adding them later means either applying the SQL by hand
against the live leader or wiping the cluster.

## Access points

Two columns because there are two ways in: pod DNS from inside the cluster, and node1's host
ports over the NetBird overlay (mapped in `infra/ingress-tcp/configmap.yaml`).

| Endpoint | In-cluster | Via node1 | Use it for |
|---|---|---|---|
| **pgdog** | `timescaledb-ha-pgdog.database.svc.cluster.local:6432` | `:6432` | **Applications.** Pooling + read/write split. |
| pgdog console | same host, database `admin` | `:6432` | `SHOW SERVERS / POOLS / REPLICATION / CLIENTS`, `RELOAD` |
| **HAProxy primary** | `timescaledb-ha-haproxy.database.svc.cluster.local:5000` | `:5433` | **Debezium/CDC**, `pg_basebackup`, migrations. Raw TCP to the leader. |
| HAProxy replicas | `timescaledb-ha-haproxy.database.svc.cluster.local:5001` | `:5434` | Read-only clients that must bypass pgdog |
| Service → leader | `timescaledb-ha-primary.database.svc.cluster.local:5432` | — | psql/admin straight to the leader, no proxy |
| Service → replicas | `timescaledb-ha-replica.database.svc.cluster.local:5432` | — | Read-only, round-robin |
| One specific node | `timescaledb-ha-<N>.timescaledb-ha-headless.database.svc.cluster.local:5432` | — | Per-node debugging; **postgres-exporter must use this** |
| Patroni REST | same host, `:8008` | — | `/health`, `/liveness`, `/readiness`, `/primary`, `/replica`, `/metrics` |
| pgdog metrics | `timescaledb-ha-pgdog.database.svc.cluster.local:9102/metrics` | — | Prometheus |
| HAProxy stats | `timescaledb-ha-haproxy.database.svc.cluster.local:7000/` | — | Stats UI at `/`, Prometheus at `/metrics` |

Which user goes where:

```
app       → pgdog :6432                          (normal application traffic)
postgres  → pgdog :6432, HAProxy :5433, -primary (admin, migrations, extensions)
admin     → pgdog :6432, database "admin"        (pooler console only)
standby   → pod-to-pod :5432                     (Patroni's business, not yours)
```

**A metrics note that matters:** postgres-exporter must connect to each pod's own DNS name,
never through pgdog or HAProxy. A pooled connection reports whichever backend it happened to
land on, so the metrics get attributed to the wrong node — one exporter per node, direct.

## Setting up a Debezium user

⚠️ **`bootstrap.cdc.enabled` will not help on this cluster.** Everything under `bootstrap` runs
in `post_init`, which fires once, on the first leader, and has already fired. The value exists
so a rebuilt cluster reproduces this setup — for the live one, apply the same SQL by hand.

### 1. The role

Run against the **current leader** (`kubectl get pods -l cluster-name=timescaledb-ha -L role`):

```sql
-- REPLICATION is what allows a logical replication connection. Deliberately NOT superuser,
-- and NOT the `standby` role Patroni uses — a CDC consumer that can also re-clone the
-- cluster has more authority than the job needs.
CREATE ROLE debezium LOGIN REPLICATION PASSWORD '<sealed-value>';

-- Group role holds the table grants; debezium inherits and holds none directly, so adding or
-- rotating a CDC principal is one GRANT rather than an audit of every schema.
CREATE ROLE cdc_reader NOLOGIN;
GRANT cdc_reader TO debezium;
GRANT CONNECT ON DATABASE app TO debezium;

-- Per captured table — NOT "GRANT SELECT ON ALL TABLES" and not DEFAULT PRIVILEGES. The
-- publication decides what is decoded, but SELECT decides what a snapshot can read.
GRANT USAGE ON SCHEMA <schema> TO cdc_reader;
GRANT SELECT ON <schema>.<table> TO cdc_reader;
ALTER TABLE <schema>.<table> REPLICA IDENTITY FULL;   -- Debezium needs the old row for UPDATE/DELETE

CREATE PUBLICATION dbz_publication;
ALTER PUBLICATION dbz_publication ADD TABLE <schema>.<table>;
```

`REPLICA IDENTITY FULL` is metadata-only — no table rewrite — but without it Debezium cannot
serialize the "before" image of updates and deletes.

**No pg_hba change is needed.** The rule `host replication standby ...` covers *physical*
replication only; a **logical** decoding connection matches the ordinary database entry, which
`host all all 0.0.0.0/0 scram-sha-256` already provides.

### 2. Connect through HAProxy, never pgdog

| | |
|---|---|
| in-cluster | `timescaledb-ha-haproxy.database.svc.cluster.local:5000` |
| via node1 | `:5433` |

Logical decoding speaks the streaming-replication protocol, which a transaction-mode pooler
does not proxy — pgdog cannot carry this connection at all. HAProxy is raw TCP passthrough and
health-checks Patroni's `/primary`, so it follows a failover and severs the old connection
(`on-marked-down shutdown-sessions`) instead of leaving Debezium attached to a demoted node.

### 3. ⚠️ Make the slot survive failover

This is the part that quietly breaks CDC. A logical replication slot lives on one node. When
Patroni promotes a different node, the slot is not there, and Debezium fails and re-snapshots.

Postgres here is **17.10**, which supports failover slots — but three settings currently work
against it:

```
sync_replication_slots = off      hot_standby_feedback = off      max_slot_wal_keep_size = -1
```

Declare the slot to Patroni so it maintains and copies it, and turn on slot sync:

```bash
kubectl -n database exec -it timescaledb-ha-1 -- patronictl edit-config
```

```yaml
slots:
  debezium_slot:
    type: logical
    database: app
    plugin: pgoutput
postgresql:
  parameters:
    sync_replication_slots: "on"
    hot_standby_feedback: "on"       # required for slot sync to work
    max_slot_wal_keep_size: "4GB"    # see below
```

Declaring the slot in Patroni also stops Patroni from treating it as unknown. Then point
Debezium at `slot.name=debezium_slot` rather than letting it create its own.

Mirror these into `values.yaml` `patroni.parameters` by hand — the DCS is the live source of
truth once a cluster exists, so the two drift silently otherwise.

### 4. ⚠️ An inactive slot will fill the volume

`max_slot_wal_keep_size = -1` means unlimited. A slot whose consumer is stopped — connector
paused, Debezium redeployed, Kafka down — pins WAL forever, and the data volume is **20Gi**. A
full PGDATA takes the whole cluster read-only, not just CDC.

Bounding it at `4GB` makes Postgres invalidate the slot instead of filling the disk. That trade
is deliberate: an invalidated slot means Debezium must re-snapshot, which is recoverable; a full
volume is an outage. Watch it:

```sql
SELECT slot_name, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots WHERE slot_type = 'logical';
```

Alert on `active = false` on a logical slot — that is the leading indicator.

### 5. The password

Add a `debezium-password` key to `timescaledb-ha-secret` (see `infra/sealed-secrets`), then set
`auth.secretKeys.debeziumPasswordKey` so a rebuilt cluster picks it up automatically.

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

Host, port, user and database are in [Access points](#access-points) — `app` on pgdog `:6432`.
One thing that is not obvious from the connection string:

For JDBC behind a transaction pooler, disable server-side prepared statements —
`prepareThreshold=0` (JDBC) or `preparedStatementCacheQueries=0` (r2dbc). Prepared statements
live on a *shared* pooled backend: a migration that alters a table changes the result type of
an already-cached plan, and the next execute raises `0A000 cached plan must not change result
type`. Behind a pooler the poisoned connection can outlive an app restart.
