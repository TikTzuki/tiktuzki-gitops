# Platform hardening plan

Ordered by value-for-cost. Each step lists what it fixes and what it costs, because the binding
constraint is node1's memory budget, not ambition.

## The constraint

```
memory limits : 14954Mi / 15354Mi   — 99%
memory requests:  6990Mi            — 46%
containers with NO memory limit: 21
```

Requests at 46% means scheduling is fine and nothing is at risk *today*. But limits at 99% means
there is no room to add anything, and the 21 unbounded containers are not counted in that figure
at all — they can grow without appearing in the budget.

**So step 1 is not "add a service", it is "make room".**

---

## Step 1 — Right-size existing limits  ✅ done

**Cost:** nothing. **Frees:** ~3.4Gi of limit budget.

Measured 24h peaks vs configured limits:

| Container | Limit | Peak | New limit | Frees |
|---|---|---|---|---|
| `timescaledb` × 3 | 2Gi | 149–176 Mi | **1Gi** | 3Gi |
| `pgdog` | 512Mi | 15 Mi | **256Mi** | 256Mi |
| `haproxy` | 256Mi | 20 Mi | **128Mi** | 128Mi |
| `redis` | 512Mi | 4 Mi | *unchanged* | — |
| `kafka-ui` | 512Mi | 332 Mi | *unchanged* | — |

⚠️ **Why timescaledb goes to 1Gi and not 256Mi**, despite a 176Mi peak: the databases are
**empty**. That peak is an idle measurement and is not representative. Once there is data,
`shared_buffers`, and real query concurrency (`max_connections: 300`), usage rises substantially.
Sizing from idle numbers is how the Grafana OOMKill happened, in the opposite direction.
Re-measure under real load before cutting further.

⚠️ **Why redis is left alone**: it holds its dataset in memory and has no `maxmemory` configured.
A container limit without a matching `maxmemory` in redis.conf means Redis grows past the limit
and gets OOMKilled rather than evicting. Tightening it requires setting both, together.

Result: limits drop from ~99% to roughly 75%, which makes every step below affordable.

## Step 2 — Dynamic storage provisioning  ✅ done (`microk8s-hostpath` is now the default class)

**Cost:** nothing. **Fixes:** the `Released` PV deadlock, hit **3 times** in one session.

```bash
microk8s enable hostpath-storage     # on node1
```

Every PV here is static + `Retain`. Deleting a PVC strands its PV forever: it keeps
`claimRef.uid` pointing at the deleted claim, and the replacement PVC never matches. Recovery is
a manual `kubectl patch pv ... claimRef=null` every single time.

With a provisioner, a new PVC gets a new volume and the failure class disappears. Existing static
PVs keep working — this is additive, not a migration.

Needs a command on node1; nothing in this repo changes.

## Step 3 — LimitRange per namespace  ✅ done — `infra/limits/`, `apps/base/limits.yaml`

**Cost:** nothing. **Fixes:** the 21 unbounded containers.

A default `LimitRange` in `database`, `monitoring`, `infrastructure`, `demo` gives every
container a limit whether or not its chart sets one. The Grafana k8s-sidecars ran unbounded until
it was noticed by hand; this makes that structurally impossible.

## Step 4 — Reloader  ✅ done — `apps/base/reloader.yaml`

**Cost:** ~30Mi. **Fixes:** stale config/secret in running pods.

`stakater/reloader` restarts a workload when a mounted ConfigMap or Secret changes.

This bit twice in one session: kafka-ui ran a **stale OAuth client secret** after it was
re-sealed, and Grafana needed a manual restart for the same reason. `secretKeyRef` env vars are
captured at container start and **never** refresh — the Secret being correct is not the same as
the pod using it.

## Step 5 — Scheduled backups  ← next

**Cost:** ~0 idle. **Fixes:** the highest-consequence gap here.

`infra/backup/backup.sh` exists but is a script, not a schedule. On a **single node with local
PVs**, node1's disk is the only copy of every database.

The critical artifact is the **sealed-secrets master key**: lose it and every SealedSecret in Git
becomes permanently undecryptable — the repo stops being a source of truth.

Needs: a CronJob, and an off-node destination. Off-node is the part that matters; a backup on the
disk you are protecting against is not a backup.

## Step 6 — cert-manager

**Cost:** ~50Mi. **Fixes:** `tls: no` on every Ingress.

TLS terminates upstream at NPM; NPM→pod is plain HTTP. cert-manager + Let's Encrypt (DNS-01,
since :80 is behind NPM) gives real in-cluster certificates.

## Step 7 — Loki

**Cost:** ~250Mi. **Fixes:** no log retention at all.

Metrics are covered; logs are not. Every debugging session relies on `kubectl logs`, and pods get
recreated constantly — the OOMKill history, the kafka-ui RBAC failures and the Patroni bootstrap
deadlock all vanished with their pods. Plugs into the existing Grafana.

## Step 8 — VPA (recommender mode) or Goldilocks

**Cost:** ~100Mi. **Fixes:** guessing at limits.

Grafana was sized at 256Mi and OOMKilled at a 255Mi peak. A recommender would have said so up
front, and would tell you how far the Step 1 numbers can safely come down once there is real load.

---

## Explicitly not doing

| | Why |
|---|---|
| MetalLB | nginx is hostNetwork on a single node; nothing to load-balance |
| Service mesh (Linkerd) | payoff is thin on one node with mostly-TCP workloads — see earlier analysis |
| descheduler | nothing to rebalance to |
| Trivy / kubescape | real value, but not before backups exist |
