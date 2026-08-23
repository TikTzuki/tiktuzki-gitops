# neo-flagd

Self-hosted feature flag server: a Spring Boot (WebFlux + R2DBC) service that keeps flag state
in PostgreSQL and evaluates with `flagd-core`. Stateless — every replica holds an in-memory
snapshot per flag set and re-reads revisions on a timer, so Postgres is the only coordination
point.

Deployed to `demo` from `apps/dev/neo-flagd.yaml`.

## What is not wired up yet

`auth` and `rbac` in `values.yaml` are **rendered but inert**. The application does not read
them until the OAuth2 work lands on the image being deployed. Until then:

- The admin API is **unauthenticated in-process** — the upstream README says to terminate auth
  at a gateway.
- The audit trail's actor is whatever `X-Actor` header the caller sends, so it can be forged.
- `ingress.enabled` is therefore **off** in `values-dev.yaml`. In-cluster SDK clients poll the
  Service directly and do not need it; only the human console does, and the console does not
  exist yet.

Turn things on in this order, verifying each: image with OAuth2 support → Keycloak client →
confirm the `groups` claim → `auth.enabled` → `rbac.enabled` → `ingress.enabled`.

## Prerequisites

**The database.** Flyway creates the schema at startup; it does not create the database.

```sh
kubectl exec -n database timescaledb-0 -- psql -U postgres -c 'create database flags'
```

**The Postgres password**, in the `demo` namespace (Secrets are namespace-scoped, so the
existing `database/timescaledb-secret` is not reachable from here):

```sh
kubectl create secret generic neo-flagd-secret --namespace demo \
  --from-literal=postgres-password='<the timescaledb postgres password>' \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace sealed-secrets \
           --controller-name sealed-secrets-controller \
           --format yaml > templates/db-sealedsecret.yaml
```

**The OAuth client secret**, once the Keycloak client exists:

```sh
kubectl create secret generic neo-flagd-oauth --namespace demo \
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

`spring.r2dbc.url` and `spring.flyway.url` both point at plain `timescaledb.database:5432`.

Flyway takes a **session-level** advisory lock to serialise concurrent migrators, and a
transaction-mode pooler does not pin a session across statements, so the lock silently fails to
hold. And pgdog's read/write split buys nothing here: this service answers every read from
memory and touches Postgres only for the revision poll and admin writes.

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
| `database.existingSecret` | `""` | **Required.** Key `postgres-password` |
| `flagserver.refreshInterval` | `5s` | See the warning above |
| `auth.enabled` | `false` | Not implemented in the app yet |
| `auth.registrationId` | `keycloak` | Sets the callback path Keycloak must whitelist |
| `rbac.enabled` | `false` | Not implemented in the app yet; deny-by-default when on |
| `rbac.rolesClaim` | `groups` | Dotted path, so `realm_access.roles` also works |
| `ingress.enabled` | `false` | Leave off until `auth.enabled` is real |

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
