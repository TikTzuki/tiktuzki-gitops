# monitoring

Whole-cluster metrics: Prometheus + Grafana + node-exporter + kube-state-metrics, via
`kube-prometheus-stack`.

Two Argo apps, deliberately split:

| App | Source | What it is |
|---|---|---|
| `monitoring` | upstream `kube-prometheus-stack` chart, `apps/base/monitoring.yaml` | The stack itself, configured through `valuesObject` |
| `monitoring-extras` | this directory, `apps/base/monitoring-extras.yaml` | Static PVs + ServiceMonitors for things the chart knows nothing about |

They are split because the second depends on CRDs the first installs. One app would have to
sync both in a single pass and would fail on first install; two apps let the second one retry.

## Install

**1. Create the data directories on node1**, with the UIDs each image actually runs as:

```bash
sudo mkdir -p /home/tik/data/monitoring/{prometheus,grafana}
sudo chown -R 1000:2000 /home/tik/data/monitoring/prometheus
sudo chown -R 472:472   /home/tik/data/monitoring/grafana
```

**2. Seal the Grafana admin credentials:**

```bash
kubectl create secret generic grafana-admin-secret \
  --namespace monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace sealed-secrets \
           --controller-name sealed-secrets-controller \
           --format yaml \
> infra/monitoring/grafana-admin-sealedsecret.yaml
```

⚠️ Record the password before you lose it — a SealedSecret cannot be read back out of Git.

The secret must exist in the `monitoring` namespace, which the `monitoring` app creates. On a
cold install: sync `monitoring` first, then seal, then sync `monitoring-extras`. Grafana
CrashLoops until the secret is there.

**3. Sync `monitoring`, then `monitoring-extras`.**

Grafana lands at **https://grafana.tiktuzki.com** (ingress class `public`, same path as
`argocd`/`keycloak`/`kafka-ui`).

## What gets scraped

Everything in the TimescaleDB HA stack exposes Prometheus metrics **natively** — no exporter
sidecars:

| Target | Port | Series worth knowing |
|---|---|---|
| Patroni (all 3 pods) | `:8008/metrics` | `patroni_primary`, `patroni_cluster_unlocked`, `patroni_xlog_replayed_location` |
| pgdog | `:9102/metrics` | `clients`, `servers`, `pools` — pool waiters and checkout time |
| HAProxy | `:7000/metrics` | `haproxy_backend_active_servers{proxy="primary"}` |

`patroni_cluster_unlocked == 1` means nobody holds the leader lock — writes are failing
cluster-wide. It is the first alert worth writing.

`haproxy_backend_active_servers{proxy="primary"} == 0` means no node passes Patroni's
`/primary` check, so everything on `:5433` (Debezium, migrations) has nowhere to go.

⚠️ **pgdog exports unprefixed metric names** — `clients`, `servers`, `pools`, not
`pgdog_clients`. Always qualify by job in PromQL: `clients{job="timescaledb-ha-pgdog"}`.
A bare `clients` will silently pick up anything else that exports the same name.

## Not covered yet

- **Postgres internals** (table sizes, bloat, slow queries, replication lag in bytes) need
  `postgres-exporter`, **one per node, connecting directly to each pod's DNS name**. Through
  pgdog or HAProxy the metrics get attributed to whichever backend the pooled connection landed
  on. It also needs a `pgmon` role, which `charts/timescaledb-ha`'s bootstrap does not create —
  see that chart's README, "Roles this chart does NOT create".
- **Kafka** needs a JMX exporter sidecar.
- **Alert delivery.** Alertmanager is running and routing, but every route currently ends at
  the `null` receiver — see "Alerting" below.

## Alerting

Rules: `alerts-timescaledb-ha.yaml` (15 alerts). Routing: the `alertmanager` block in
`apps/base/monitoring.yaml`.

Every expression was written against metric names read off the **live** endpoints, then checked
with `promtool check rules`. Do the same when adding rules — Patroni and pgdog both export
names that are easy to guess wrong (`patroni_xlog_replayed_location`, not `..._replay_lsn`;
`cl_waiting`, not `pgdog_clients_waiting`).

Node, pod, PV and kubelet alerts are **not** here — kube-prometheus-stack ships those.

| Severity | Alert | Fires when |
|---|---|---|
| critical | `PatroniClusterUnlocked` | No leader lock held — whole cluster is read-only |
| critical | `PatroniNoPrimary` | No node reports itself primary |
| critical | `PatroniSplitBrain` | More than one node claims primary |
| critical | `HAProxyNoPrimaryBackend` | `:5433` has no writable node — Debezium/migrations dead |
| critical | `PgdogDown` | Applications have no database, however healthy the cluster is |
| warning | `PatroniNodeDown` | Postgres down on a node |
| warning | `PatroniReplicaNotStreaming` | Replica up but not replaying — not a failover candidate |
| warning | `PatroniReplicationLagHigh` | >16MB behind (the point pgdog bans it from reads) |
| warning | `HAProxyNoReplicaBackends` | `:5434` has nowhere to send reads |
| warning | `PatroniDcsUnreachable` | Patroni can't reach the k8s API — ~20s before the lease expires |
| warning | `PgdogClientsWaiting` | Pool exhausted, clients queuing |
| warning | `PgdogServerErrors` | Backend connections erroring |
| warning | `PatroniPendingRestart` | Config in the DCS ≠ config actually running |
| warning | `PatroniPaused` | Auto-failover left disabled for 30m |
| info | `PatroniFailoverOccurred` | Timeline advanced — a promotion happened |

### Routing decisions

**The inhibit rule is the important one.** A failover sets off the whole redundancy group at
once — replicas stop streaming, lag spikes, HAProxy loses backends, pgdog logs errors. None of
that is separately actionable while there is no leader, so `PatroniClusterUnlocked` /
`PatroniNoPrimary` suppress all of it. You get "no leader", not six symptoms of the same event.

**`Watchdog` is routed to `null` on purpose.** It fires constantly by design — it is the dead
man's switch proving the alert pipeline is alive. It is only useful pointed at a service
watching for its *absence* (healthchecks.io, Cronitor). Anywhere else it is noise.

**`repeat_interval` is 12h, not the 4h default.** Re-notifying every 4h about something you
already know is how you learn to mute the channel.

### Delivering alerts

Delivery is **Telegram**. Two steps, both required before the app will sync cleanly.

**1. Create the bot and seal its token.** Talk to [@BotFather](https://t.me/BotFather),
`/newbot`, keep the token:

```bash
kubectl create secret generic alertmanager-telegram \
  --namespace monitoring \
  --from-literal=token='<bot-token-from-BotFather>' \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace sealed-secrets \
           --controller-name sealed-secrets-controller \
           --format yaml \
> infra/monitoring/alertmanager-telegram-sealedsecret.yaml
```

The token is read via `bot_token_file`, so it never appears in `monitoring.yaml`, in Git, or in
`kubectl get alertmanager -o yaml`. The operator mounts it at
`/etc/alertmanager/secrets/alertmanager-telegram/token`.

**2. Set the chat ID.** Send any message to the bot (or add it to a group and post there), then:

```bash
curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | jq '.result[-1].message.chat.id'
```

Put that number in `chat_id` in `apps/base/monitoring.yaml`. Group chats are **negative**
(`-1001234567890`); a direct message is positive. It is an integer — do not quote it.

⚠️ **`chat_id` ships as `0`, which is invalid.** Alertmanager will CrashLoop with
`missing chat_id on telegram_config` until you replace it. That is deliberate: a loud failure at
config load beats the alternative, where a plausible-but-wrong ID lets Alertmanager start and
then drop every alert on a Telegram 400. Prometheus and Grafana are unaffected either way.

Verify before syncing:

```bash
# extract the rendered config and check it
amtool check-config <(...)      # SUCCESS expected: 2 receivers, 1 inhibit rule
```

**On the HTML formatting:** `parse_mode: HTML` makes Telegram reject the *entire message* with a
400 if the text contains an unescaped `<`, `>` or `&` — and Alertmanager does not retry a 400,
so the alert is silently dropped. No current rule annotation contains those characters (checked),
but keep it that way when adding rules, or set `parse_mode: ""` to make it structurally
impossible.

### Testing the pipeline end to end

Fire a synthetic alert straight at Alertmanager, bypassing Prometheus:

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093 &
curl -XPOST http://localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[{
  "labels": {"alertname":"TestAlert","severity":"critical"},
  "annotations": {"summary":"pipeline test","description":"delete me"}
}]'
```

A Telegram message should arrive within `group_wait` (30s). To test a real rule instead, delete
the leader pod and wait for `PatroniFailoverOccurred` — see `charts/timescaledb-ha/README.md`,
"Verifying failover".

## Decisions worth knowing

**microk8s control-plane scrape jobs are off.** `kubeControllerManager`, `kubeScheduler`,
`kubeProxy` and `kubeEtcd` run as host processes bound to localhost on microk8s, not as pods
with the labels the chart's ServiceMonitors expect. Left enabled they sit permanently DOWN and
fire `*Down` alerts forever, which is how you learn to ignore alerts.

**`serviceMonitorSelectorNilUsesHelmValues: false` is load-bearing.** Without it the Prometheus
CR only selects ServiceMonitors carrying this release's labels, so everything in this directory
is ignored — no error, no warning, targets just never appear.

**`ServerSideApply=true` is required, not stylistic.** The Prometheus CRDs are hundreds of KB;
a client-side apply stuffs the whole manifest into the `last-applied-configuration` annotation
and blows the 256KB limit with `metadata.annotations: Too long`.

**Grafana's PV is a scratchpad.** Dashboards built in the UI survive a restart, but anything
you want reproducible belongs in Git as a provisioned dashboard ConfigMap.

## Resource budget

Sized for a single 15Gi node that was already ~78% committed on limits before this landed:

| | requests | limits |
|---|---|---|
| Prometheus | 200m / 512Mi | 1 / 1536Mi |
| Grafana | 50m / 128Mi | 300m / 256Mi |
| kube-state-metrics | 20m / 64Mi | 200m / 128Mi |
| node-exporter | 20m / 32Mi | 100m / 64Mi |
| operator | 50m / 64Mi | 200m / 128Mi |

≈2.1Gi of limits, taking node1 to roughly 13.9Gi of 15.3Gi. That is tight. Watch
`prometheus_tsdb_head_series` — past ~500k, raise Prometheus's limit before the OOM killer
finds it, or cut `retention`.
