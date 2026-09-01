# Access points

Every way into this cluster, per service. Generated from the live cluster — re-verify with the
commands in "Regenerating this" rather than trusting it after a rebuild.

**No credential values are recorded here.** Only *where each one lives*. Read them with:

```bash
kubectl get secret <secret> -n <ns> -o jsonpath='{.data.<key>}' | base64 -d
```

## The two front doors

| | Address | Carries |
|---|---|---|
| **node1 — LAN** | `192.168.1.5` | everything below |
| **node1 — NetBird overlay** | `100.66.50.60` | same; this is how you reach it off-LAN (`:16443` is the kube API) |
| **HTTP(S)** | `*.tiktuzki.com` → NPM → node1:80 → Traefik ingress (class `public`) | web UIs |
| **Raw TCP** | node1:`<port>` → Traefik entryPoint (`apps/base/traefik.yaml`) + `IngressRouteTCP` (`infra/ingress-tcp/routes-tcp.yaml`) | databases, brokers |

⚠️ **`ss -ltn` shows nothing on the ingress ports.** Traefik binds them with `hostPort`,
which the CNI implements as iptables DNAT rather than a listening socket. Test reachability
with `curl` or `nc`, never with `ss` — a port can be fully working and invisible to it.

⚠️ **Every Ingress has `tls: no`.** TLS is terminated upstream at NPM; from NPM to the pod the
traffic is plain HTTP inside the cluster. Fine on a trusted host, worth knowing before assuming
end-to-end encryption.

---

## kafka

| Access | Address | Notes |
|---|---|---|
| In-cluster (apps) | `kafka.database.svc.cluster.local:9092` | `PLAINTEXT` listener, **no auth** — trusted network only |
| External | `node1:9094` | `SASL_PLAINTEXT`, SCRAM-SHA-512 |
| Controller (KRaft) | `kafka-headless.database.svc.cluster.local:9093` | internal quorum, never client-facing |
| **kafka-ui** | `https://kafka-ui.tiktuzki.com` | in-cluster: `kafka-ui.database.svc.cluster.local:8080` |

**Accounts**

| Account | Where | Used for |
|---|---|---|
| `admin` | `database/kafka-secret` → `kafka-admin-password` | SCRAM-SHA-512 on the external listener |
| `kafka-ui` (OIDC client) | `database/kafka-ui-oauth` → `client-secret` | Keycloak client, realm `homelab` |
| kafka-ui humans | Keycloak realm `homelab` | groups `kafka-admins` / `kafka-viewers` |

⚠️ `SASL_PLAINTEXT` **authenticates but does not encrypt** — SCRAM protects the password via
challenge-response, payloads travel in the clear. Use `SASL_SSL` if the overlay is ever untrusted.

⚠️ kafka-ui has **no local account**. If Keycloak is down or the group mapping breaks, the only
way back in is `kafkaUi.rbac.enabled: false` + re-sync.

---

## keycloak

| Access | Address |
|---|---|
| Public | `https://keycloak.tiktuzki.com` |
| In-cluster | `keycloak.infrastructure.svc.cluster.local:8080` |
| Realm used by every app | `homelab` — issuer `https://keycloak.tiktuzki.com/realms/homelab` |

**Accounts**

| Account | Where | Used for |
|---|---|---|
| `admin` | `infrastructure/keycloak-secret` → `admin-password` | Keycloak admin console (realm `master`) |
| DB user | `infrastructure/keycloak-secret` → `postgres-username` / `postgres-password` | Keycloak's own store, on TimescaleDB |

**OIDC clients registered in `homelab`:** `grafana`, `kafka-ui`, `argocd`.

⚠️ Realm `master` administers Keycloak itself — application clients and end users belong in
`homelab`. Anyone in `master` can administer the identity provider.

---

## monitoring

| Access | Address | Auth |
|---|---|---|
| **Grafana** | `https://grafana.tiktuzki.com` | Keycloak SSO **+** local admin |
| Grafana in-cluster | `monitoring-grafana.monitoring.svc.cluster.local:80` | |
| Prometheus | `monitoring-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090` | **none — not exposed** |
| Alertmanager | `monitoring-kube-prometheus-alertmanager.monitoring.svc.cluster.local:9093` | **none — not exposed** |

**Accounts**

| Account | Where | Used for |
|---|---|---|
| Grafana local admin | `monitoring/grafana-admin-secret` → `admin-user` / `admin-password` | **break-glass** — works when Keycloak does not |
| `grafana` (OIDC client) | `monitoring/grafana-oauth-secret` → `client-secret` | Keycloak client |
| Grafana humans | Keycloak realm `homelab` | client roles `admin` / `editor` on the `grafana` client |
| Telegram bot | `monitoring/alertmanager-telegram` → `token` | alert delivery |

⚠️ **Prometheus and Alertmanager have no authentication at all.** They are safe only because
neither has an Ingress — reach them with `kubectl port-forward`. If you ever expose them, put
oauth2-proxy in front: the Alertmanager UI can silence every alert in the cluster.

Grafana authorization is `role_attribute_strict: true` — a Keycloak user with no `admin`/`editor`
client role is **refused**, not given Viewer.

---

## redis-sentinel

| Access | Address |
|---|---|
| Redis — in-cluster | `redis-sentinel.database.svc.cluster.local:6379` |
| Sentinel — in-cluster | `redis-sentinel.database.svc.cluster.local:26379` |
| Redis — external | `node1:6379` |
| Sentinel — external | `node1:26379` |
| Per-pod | `redis-sentinel-headless.database.svc.cluster.local` |

**Accounts**

| Account | Where | Used for |
|---|---|---|
| default (`requirepass`) | `database/redis-secret` → `redis-password` | both Redis and Sentinel |

---

## timescaledb (single node)

The standalone instance — **not** the HA cluster. Separate data, separate credentials.

| Access | Address |
|---|---|
| In-cluster | `timescaledb.database.svc.cluster.local:5432` |
| External | `node1:5432` |

**Accounts**

| Account | Where | Used for |
|---|---|---|
| `postgres` | `database/timescaledb-secret` → `postgres-password` | superuser |

Currently PostgreSQL **18.4** (`timescaledb:2.28.0-pg18`).

---

## timescaledb-ha (Patroni cluster)

Three nodes behind two proxies with different jobs. **Which endpoint you pick is a correctness
decision, not a preference** — see `charts/timescaledb-ha/README.md`.

| Access | In-cluster | External | Use for |
|---|---|---|---|
| **pgdog** | `timescaledb-ha-pgdog.database.svc.cluster.local:6432` | `node1:6432` | **applications** — pooling + read/write split |
| pgdog console | same, database `admin` | `node1:6432` | `SHOW SERVERS / POOLS / REPLICATION` |
| **HAProxy → primary** | `timescaledb-ha-haproxy.database.svc.cluster.local:5000` | `node1:5433` | **Debezium/CDC**, `pg_basebackup`, migrations |
| HAProxy → replicas | `timescaledb-ha-haproxy.database.svc.cluster.local:5001` | `node1:5434` | read-only, bypassing pgdog |
| HAProxy stats | `timescaledb-ha-haproxy.database.svc.cluster.local:7000` | — | UI at `/`, Prometheus at `/metrics` |
| Service → leader | `timescaledb-ha-primary.database.svc.cluster.local:5432` | — | psql/admin straight to the leader |
| Service → replicas | `timescaledb-ha-replica.database.svc.cluster.local:5432` | — | read-only, round-robin |
| One specific node | `timescaledb-ha-<N>.timescaledb-ha-headless.database.svc.cluster.local:5432` | — | per-node debugging |
| Patroni REST | same host `:8008` | — | `/health`, `/primary`, `/replica`, `/metrics` |
| postgres_exporter | same host `:9187` | — | Prometheus |
| pgdog metrics | `timescaledb-ha-pgdog.database.svc.cluster.local:9102` | — | Prometheus |

**Accounts** — all in `database/timescaledb-ha-secret`

| Account | Key | Postgres role? | Used for |
|---|---|---|---|
| `postgres` | `superuser-password` | superuser | admin, extensions, `patronictl`, `pg_rewind` |
| `app` | `app-password` | LOGIN, owns db `app`, **`pg_monitor`** | applications via pgdog; also postgres_exporter |
| `standby` | `replication-password` | REPLICATION | Patroni's streaming replication, pod-to-pod only |
| `debezium` | `debezium-password` | LOGIN **REPLICATION** | CDC via HAProxy `:5433` |
| `cdc_reader` | — | NOLOGIN group | holds the CDC table grants; `debezium` inherits |
| `admin` | `pgdog-admin-password` | **no** | pgdog's own console only |

Database `app`. Currently PostgreSQL **18.4**, TimescaleDB **2.29.1**.

⚠️ `admin` is **not** a Postgres role — it exists only inside pgdog. Connecting to a Postgres
node as `admin` fails.

⚠️ **Debezium cannot use pgdog.** Logical decoding speaks the streaming-replication protocol,
which a transaction-mode pooler does not proxy. Use HAProxy `:5433`.

⚠️ `app` holds `pg_monitor` for a functional reason, not a monitoring one — pgdog polls
`pg_is_in_recovery()` as that role to track the topology. Revoke it and the read/write split
silently stops following failovers.

---

## Also on node1 (not in scope, listed so ports are not reused)

| Port | Target |
|---|---|
| `3000` | `database/tigerbeetle:3000` |
| `80` / `443` | Traefik ingress (all `*.tiktuzki.com`) |
| `16443` | Kubernetes API |

Other web UIs on the same ingress: `argocd.tiktuzki.com`, `cv-hub.tiktuzki.com`,
`my-pwd.tiktuzki.com`.

## argocd

| Access | Address |
|---|---|
| Public | `https://argocd.tiktuzki.com` |
| In-cluster | `argocd-server.devops.svc.cluster.local:443` (HTTPS, self-signed) |

**Accounts**

| Account | Where | Used for |
|---|---|---|
| Google SSO | Google OAuth client; authorization in `devops/argocd-rbac-cm` | `long.tpt@newera.inc` → `role:admin` |
| OIDC client secret | `devops/argocd-oidc-secret` → `clientSecret` | **out-of-band** — see below |
| `admin` (local) | `devops/argocd-secret` → `admin.password` | break-glass; disabled once SSO is proven |

⚠️ Google issues **no `groups` claim**, so Argo CD authorizes on the `email` claim
(`scopes: '[email]'`). `policy.default: ''` is load-bearing: Google authenticates any Google
account, and the only thing denying a stranger is that they match no line in `policy.csv`.

⚠️ `devops/argocd-oidc-secret` is created **out of band** by
`bootstraps/argocd/sso/create-oidc-secret.sh`, not from Git. A cluster rebuild destroys it;
re-run the script from the value in your password manager.

⚠️ Once `admin.enabled: "false"` is set, the **cluster-admin client certificate is the only
break-glass path** into Argo CD — recovery is a `kubectl patch` on `argocd-cm`.

---

## Known credential debt

- **`database/database-secret`** still holds `kafka-admin-password`, `postgres-password` and
  `redis-password`, but only `postgres-password` is consumed (by the single-node `timescaledb`).
  Kafka moved to `kafka-secret` and Redis to `redis-secret`; those two keys are orphaned.
- Values committed in plaintext before sealing should be treated as leaked and rotated, not
  merely re-sealed.

## Regenerating this

```bash
# public HTTP
kubectl get ingress -A -o json | jq -r '.items[] |
  "\(.metadata.namespace)/\(.metadata.name) \([.spec.rules[]?.host]|join(",")) tls=\(if .spec.tls then "yes" else "no" end)"'

# public TCP — two halves, and BOTH must agree
kubectl get ingressroutetcp -A -o json | jq -r '.items[] |
  "\(.metadata.namespace)/\(.metadata.name) entryPoints=\(.spec.entryPoints|join(",")) -> \([.spec.routes[].services[]|"\(.name):\(.port)"]|join(","))"'
kubectl -n ingress get ds traefik -o json | jq -r '.spec.template.spec.containers[].ports[] |
  "\(.name) container=\(.containerPort) hostPort=\(.hostPort // "none")"'

# internal
kubectl get svc -A -o json | jq -r '.items[] |
  "\(.metadata.name).\(.metadata.namespace).svc.cluster.local \([.spec.ports[]|"\(.name):\(.port)"]|join(","))"'

# credential KEY NAMES only (never values)
kubectl get secret -n <ns> -o json | jq -r '.items[] | "\(.metadata.name): \(.data|keys|join(", "))"'
```
