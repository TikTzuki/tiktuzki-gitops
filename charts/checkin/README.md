# checkin — attendance & overtime tracking

Next.js app (`demo-apps/checkin`) recording daily check-in/check-out with overtime,
backed by Postgres. Served at `checkin.tiktuzki.com`, namespace `demo`.

## What changed from the hackathon build

The app used to be a one-shot event check-in with a JSON file database. It is now a
daily timekeeping system, which changes three things for deployment:

|        | Before                                 | Now                                                 |
|--------|----------------------------------------|-----------------------------------------------------|
| State  | JSON file on a local PV at `/app/data` | Postgres only — `persistence` is off                |
| Config | `DATABASE_URL` alone                   | plus `AUTH_SECRET`, `ADMIN_EMAIL`, `ADMIN_PASSWORD` |
| Boot   | start the server                       | `prisma migrate deploy`, seed the admin, then start |

**`entrypoint.sh` runs with `set -e`, and the seed exits non-zero when `ADMIN_EMAIL`
or `ADMIN_PASSWORD` is missing.** Deploying the new image without the secret below is
not a degraded app — it is `CrashLoopBackOff`. Create the Secret first.

## 1. Database

The app needs its own database and a role that owns it. On PostgreSQL 15+ a plain role
cannot create tables in `public`, so ownership is the simplest correct grant:

```sql
CREATE ROLE checkin LOGIN PASSWORD '<generated>';
CREATE DATABASE checkin OWNER checkin;
\c checkin
GRANT ALL ON SCHEMA public TO checkin;
```

### Which endpoint

Use the **primary Service**, not pgdog:

```
DATABASE_URL=postgresql://checkin:<pw>@timescaledb-ha-primary.database.svc.cluster.local:5432/checkin?schema=public
```

Two reasons, both from `charts/timescaledb-ha/README.md`:

- **pgdog's reads may be stale.** Replication is asynchronous, and a read in a separate
  transaction right after a write can land on a replica that has not replayed it. The
  kiosk does exactly that — you check in, and the board re-polls a second later. Through
  pgdog that can render as "not checked in yet".
- **Migrations must not be multiplexed.** `prisma migrate deploy` runs multi-statement
  DDL under an advisory lock, which a transaction-mode pooler does not hold across
  statements. `timescaledb-ha-primary` always points at the current Patroni leader.

If this app ever outgrows a single replica, split the two: keep migrations on the
primary and move request traffic to `timescaledb-ha-pgdog:6432` — but only after the
stale-read behaviour above is handled.

> Note the host ports differ from the in-cluster ones. `100.66.50.60:5432` is the
> **standalone** `timescaledb`, a different server from the HA cluster on `:5433`.
> A role that exists on one does not exist on the other.

## 2. Secret

Everything the app reads at boot lives in one sealed Secret, `demo/checkin-env`:

```bash
kubectl create secret generic checkin-env \
  --namespace demo \
  --from-literal=DATABASE_URL='postgresql://checkin:<pw>@timescaledb-ha-primary.database.svc.cluster.local:5432/checkin?schema=public' \
  --from-literal=AUTH_SECRET="$(openssl rand -base64 48)" \
  --from-literal=ADMIN_EMAIL='admin@newera.inc' \
  --from-literal=ADMIN_NAME='Quản trị viên' \
  --from-literal=ADMIN_PASSWORD="$(openssl rand -base64 18)" \
  --dry-run=client -o yaml \
| kubeseal \
  --controller-namespace sealed-secrets \
  --controller-name sealed-secrets-controller \
  --format yaml \
> charts/checkin/templates/sealedsecret.yaml
```

Commit the result. Record `ADMIN_PASSWORD` in your password manager as you generate it —
it is bcrypt-hashed on first boot and cannot be read back.

**URL-encode special characters in the database password** (`#` → `%23`, `@` → `%40`).
An unencoded `@` truncates the host and the connection fails with a confusing error.

`AUTH_SECRET` must be at least 32 characters; `src/lib/auth/session.ts` throws rather
than falling back to a default, so a short value takes every admin route down.

### Rotating

- `AUTH_SECRET` — reseal and let Reloader roll the pod. Every admin is logged out.
- `ADMIN_PASSWORD` — **the seed only applies it when creating the account.** Changing it
  here does nothing to an existing admin; it is deliberate, so a redeploy cannot revert a
  password changed in the app. To actually reset, delete the `admin_users` row and let
  the next boot recreate it.
- `DATABASE_URL` — reseal; the pod re-runs migrations against the new target on restart.

## 3. Deploy

`apps/dev/checkin.yaml` already points Argo at this chart with `values-dev.yaml`.
Nothing to change there. After the Secret exists:

```bash
kubectl -n demo rollout status deploy/checkin
kubectl -n demo logs deploy/checkin --tail=40   # migrate + seed output
```

A healthy first boot logs `All migrations have been successfully applied.` then
`Admin created: <email>`. On later boots the seed prints `Admin already exists` — it is
idempotent by design.

## Verifying

```bash
curl -s https://checkin.tiktuzki.com/api/attendance/today | head -c 200   # public kiosk board
curl -so /dev/null -w '%{http_code}\n' https://checkin.tiktuzki.com/api/admin/sessions  # expect 401
```

Admin UI at `/admin`, kiosk at `/`. Excel export is under
`/api/admin/export/excel?from=&to=` and requires the session cookie.
