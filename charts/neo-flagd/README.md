# neo-flagd

Self-hosted feature flag server: a Spring Boot (WebFlux + R2DBC) service that keeps flag state
in PostgreSQL and evaluates with `flagd-core`. Stateless — every replica holds an in-memory
snapshot per flag set and re-reads revisions on a timer, so Postgres is the only coordination
point.

Deployed to `demo` from `apps/dev/neo-flagd.yaml`.

## Chart defaults are off; dev is on

`values.yaml` ships with `auth`, `rbac` and `ingress` all disabled, because a chart that
authenticates by default fails closed on a cluster with no identity provider.
`values-dev.yaml` turns all three on.

What dev expects to exist in Keycloak realm `homelab`:

- Client `neo-flagd`, confidential, redirect URI
  `https://flagd.tiktuzki.com/login/oauth2/code/keycloak` — the path ends in
  `auth.registrationId`, not the client id.
- Groups `flag-admins`, `flag-operators`, `flag-viewers`.
- A Group Membership mapper putting `groups` in the **access** token. Id-token-only leaves
  bearer callers (CI) with no roles.

Then `GET /api/v1/me` to confirm the claim actually arrived before trusting the policy.

## Prerequisites

**The database.** Nothing to create by hand in dev: `values-dev.yaml` puts neo-flagd in a
`flagd` schema of the existing `app` database on the HA cluster, and Flyway creates that
schema on first start because `app` owns the database. Verified against a stand-in with a
pre-existing `public` table — the four tables and `flyway_schema_history` all land in `flagd`
and nothing else is touched.

Taking a whole database instead (`database.schema: ""`) means creating it first:

```sh
kubectl exec -n database timescaledb-0 -- psql -U postgres -c 'create database flags'
```

**Both credentials live in one Secret**, `neo-flagd-secret` in `demo`, already sealed at
`templates/db-sealedsecret.yaml`:

| Key | What it is | Consumed as |
|---|---|---|
| `pg-password` | copy of the HA cluster's `app` password | `database.passwordKey` |
| `client-secret` | Keycloak client secret | `auth.clientSecretKey` |

Secrets are namespace-scoped, so the Postgres password has to be copied out of
`database/timescaledb-ha-secret` — this pod cannot read it there. Re-seal both keys together
with `--merge-into` so one does not clobber the other:

```sh
PW=$(kubectl get secret timescaledb-ha-secret -n database -o jsonpath='{.data.app-password}' | base64 -d)

kubectl create secret generic neo-flagd-secret --namespace demo \
  --from-literal=pg-password="$PW" \
  --from-literal=client-secret='<from Keycloak>' \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace sealed-secrets \
           --controller-name sealed-secrets-controller \
           --format yaml \
           --merge-into templates/db-sealedsecret.yaml
```

⚠️ Rotating `app-password` on the cluster does not update this copy — that is the trade-off
every namespace-local credential copy carries. Re-seal when you rotate.

⚠️ The key is `pg-password`, not `app-password`. It is the *value* of the cluster's
`app-password`; the name differs because this Secret also carries the OAuth secret.

## Chart defaults are off; dev is on

`values.yaml` ships with `auth`, `rbac` and `ingress` all disabled, because a chart that
authenticates by default fails closed on a cluster with no identity provider.
`values-dev.yaml` turns all three on.

What dev expects to exist in Keycloak realm `homelab`:

- Client `neo-flagd`, confidential, redirect URI
  `https://flagd.tiktuzki.com/login/oauth2/code/keycloak` — the path ends in
  `auth.registrationId`, not the client id.
- Groups `flag-admins`, `flag-operators`, `flag-viewers`.
- A Group Membership mapper putting `groups` in the **access** token. Id-token-only leaves
  bearer callers (CI) with no roles.

Then `GET /api/v1/me` to confirm the claim actually arrived before trusting the policy.

## Prerequisites

**The database.** Nothing to create by hand in dev: `values-dev.yaml` puts neo-flagd in a
`flagd` schema of the existing `app` database on the HA cluster, and Flyway creates that
schema on first start because `app` owns the database. Verified against a stand-in with a
pre-existing `public` table — the four tables and `flyway_schema_history` all land in `flagd`
and nothing else is touched.

Taking a whole database instead (`database.schema: ""`) means creating it first:

```sh
kubectl exec -n database timescaledb-0 -- psql -U postgres -c 'create database flags'
```

**The Postgres password**, in the `demo` namespace. Secrets are namespace-scoped, so the pod
cannot read `database/timescaledb-ha-secret`; copy the value across:

```sh
PW=$(kubectl get secret timescaledb-ha-secret -n database -o jsonpath='{.data.app-password}' | base64 -d)

kubectl create secret generic neo-flagd-secret --namespace demo \
  --from-literal=app-password="$PW" \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace sealed-secrets \
           --controller-name sealed-secrets-controller \
           --format yaml > templates/db-sealedsecret.yaml
```

⚠️ Rotating `app-password` on the cluster does not update this copy. It is the same trade-off
every namespace-local credential copy carries; re-seal when you rotate.

**The OAuth client secret**, once the Keycloak client exists:

```sh
kubectl create secret generic neo-flagd-secret --namespace demo \
  --from-literal=client-secret='<from Keycloak>' \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace sealed-secrets \
           --controller-name sealed-secrets-controller \
           --format yaml > templates/oauth-sealedsecret.yaml
```

Neither SealedSecret is committed yet — sealing requires the controller's public key, so it has
to happen against the live cluster. See `note/seal.md` for the `--merge-into` form used to
rotate an existing one.

## Two things this chart deliberately overrides

### Readiness includes `flagSnapshots`

```yaml
management.endpoint.health.group.readiness.include: readinessState,flagSnapshots
```

This is the most important line in the chart. `FlagSnapshotHealthIndicator` is registered as a
plain `@Component`, so by default it appears **only** in the aggregate `/actuator/health` — not
in the `readiness` group, which otherwise contains just `readinessState`.

Verified against a running server. With the stock config, after the refresh loop died:

```
/actuator/health            -> DOWN     (correct)
/actuator/health/readiness  -> UP       (pod stays in the Service)
/actuator/health/liveness   -> UP       (pod is never restarted)
```

A replica in that state keeps answering `200` from a permanently frozen snapshot. With the
override above, the same failure produces:

```
/actuator/health/readiness  -> DOWN, components: [flagSnapshots(DOWN), readinessState(UP)]
```

which is what dequeues the pod. The upstream README claims this happens by default; it does not.

### Both database URLs bypass pgdog

`spring.r2dbc.url` and `spring.flyway.url` both point at HAProxy's primary port
(`timescaledb-ha-haproxy.database:5000`), not pgdog `:6432`. This deviates from the house rule
in `ACCESS.md` that applications go through pgdog, on purpose:

- Flyway takes a **session-level** advisory lock to serialise concurrent migrators, and a
  transaction-mode pooler does not pin a session across statements, so the lock silently
  fails to hold. `ACCESS.md` already records the same constraint for Debezium.
- pgdog's read/write split buys nothing here. This service answers every read from an
  in-memory snapshot and touches Postgres only for the 5s revision poll and admin writes, all
  of which must reach the primary anyway.

`:5000` follows the leader, so this survives a Patroni failover.

## Do not lower `flagserver.refreshInterval`

It looks like a simple propagation-latency knob. It is also a deadline, in two places:

1. **Startup.** Warming every flag set is given exactly `6 × refreshInterval`, after which the
   process **exits** — not degrades. Measured: 5,006 flag sets warm in 13.3 s, which starts
   fine at `5s` (30 s budget) and fails to boot at `1s` (6 s budget) with
   `IllegalStateException: Timeout on blocking read`. In Kubernetes that is a CrashLoopBackOff
   triggered by tenant growth.

2. **Steady state.** A refresh that outlasts one interval raises an `OverflowException` from
   `Flux.interval` that is *upstream* of the error handler in `refresh()`, terminating the
   subscription for the life of the pod. One write to a large enough flag set is sufficient.

The governing rule: rebuild time for all simultaneously-changed flag sets must stay under
`refreshInterval`, where rebuild is roughly **1.5 ms per flag set + 50 µs per flag** (measured
with realistic targeting rules; trivial flags are cheaper). At the `5s` default that means no
single flag set much above ~100,000 flags. Keeping any one set at 5,000 or fewer leaves a 25×
margin and keeps admin writes under 200 ms.

## Sizing

Measured: 91,100 flags across 6 flag sets occupied **106 MB of live heap** — about 1 KB per
flag. The default 768Mi limit yields a ~576Mi heap under the image's
`-XX:MaxRAMPercentage=75`, roughly 5× headroom over a large real corpus.

Reads do not need scaling headroom: a single replica served ~58,000 req/s of ETag-`304` polls.
What does scale with client count is egress after each write, since a revision bump invalidates
every client's cached document at once — roughly `clients × documentSize / pollInterval`, where
documents run ~209 bytes per flag. That is the real argument for splitting flag sets.

## Values

| Key | Default | Notes |
|---|---|---|
| `replicaCount` | `1` | Stateless; dev runs 2 |
| `database.existingSecret` | `""` | **Required.** Key from `database.passwordKey` |
| `database.schema` | `""` | Set to share a database: adds `?currentSchema=` and Flyway owns that schema |
| `flagserver.refreshInterval` | `5s` | See the warning above |
| `auth.enabled` | `false` | On in dev. Needs the Keycloak client and a sealed secret |
| `auth.registrationId` | `keycloak` | Sets the callback path Keycloak must whitelist |
| `rbac.enabled` | `false` | On in dev. Deny-by-default; needs `auth.enabled` too |
| `rbac.rolesClaim` | `groups` | Dotted path, so `realm_access.roles` also works |
| `ingress.enabled` | `false` | On in dev, safe now that auth is enforced |

### RBAC shape

Resources: `flagset`, `flag`, `audit`, `evaluate`, `appconfig`.

| Resource | Actions |
|---|---|
| `flag` | `view`, `toggle`, `edit`, `delete`, `all` |
| `flagset` | `view`, `create`, `edit`, `delete`, `all` |
| `audit` | `view` |
| `evaluate` | `run` |
| `appconfig` | `view` |

There is no `create` on `flag`: the admin API creates a flag with the same PUT that replaces
one, so `edit` covers create-or-replace. `create` applies to flag sets.

`toggle` is separate from `edit` on purpose, and the server enforces the difference rather
than trusting the caller: `POST /api/v1/admin/flag-sets/{set}/flags/{key}/toggle` takes only a
variant name and rebuilds the definition from the stored one, so a caller holding `toggle` has
nowhere to put a new targeting rule. An on-call engineer can kill a feature without being able
to rewrite how it targets.

There is no wildcard across *resources*, only the `all` action within one — so `flag: [all]`
grants nothing on `audit`, and widening a role stays a visible diff.

`GET /api/v1/me` reports the caller's roles and effective permissions so the console can grey
out controls. It is an affordance only; every call is re-checked server-side.

Deny-by-default: a caller matching no role can do nothing. Both switches must be on —
`rbac.enabled` alone does nothing without `auth.enabled`, because there is no verified
principal to attribute a decision to.

## Verifying a deploy

```sh
# Flyway ran
kubectl -n demo logs deploy/neo-flagd | grep -i flyway

# readiness must list flagSnapshots — this is the whole point of the health override
kubectl -n demo exec deploy/neo-flagd -- wget -qO- localhost:8080/actuator/health/readiness

# a flag round-trip
kubectl -n demo port-forward svc/neo-flagd 8080:8080 &
curl -s localhost:8080/api/v1/flag-sets/default/flags.json
```
