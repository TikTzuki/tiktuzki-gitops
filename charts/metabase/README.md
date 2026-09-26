# metabase

Metabase, open-source edition: self-service charts and dashboards for HR, and **signed
(static) embeds** that x-hrm shows inside its own pages. Metabase's own state (users,
questions, dashboards, saved connections) lives in its application database on
postgresql-ha. The pod is stateless, so the chart has no volume.

## Shape, and why

| Choice                                                                                | Why                                                                                                                                                                          |
|---------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **1 replica, `strategy: Recreate`**, not configurable                                 | An upgrade runs Liquibase migrations on the application database at start. An old and a new version must never run against it at once.                                       |
| Application DB on **postgresql-ha HAProxy :5000**, not pgdog                          | Liquibase takes session-level locks while migrating, and a transaction-mode pooler breaks them. :5000 follows the Patroni leader. Same deviation as `x-hrm` and `neo-flagd`. |
| Own database **`metabase`**, owned by `app`                                           | Keeps Metabase's ~200 tables out of the shared `app` database. Never the built-in H2 file: it lives inside the container and is lost on restart.                             |
| Image tag **pinned** (`v0.63.18.2`)                                                   | Metabase can't be downgraded after its migrations have run, so `latest` could upgrade it by accident on a restart.                                                           |
| Runs as **2000:2000, read-only root filesystem**, `/tmp` and `/plugins` as `emptyDir` | The image starts as root by default. Started as a non-root uid it runs Java directly. Checked locally on v0.63.18.2.                                                         |
| **Ingress off in `values-dev.yaml`** until setup is done                              | Until the setup wizard is finished, whoever opens the URL first becomes admin.                                                                                               |
| Probes on `/api/health`, 10-minute startup budget                                     | It answers 503 until migrations finish: 1–2 min on first start, longer on some upgrades.                                                                                     |
| 1 Gi request / 2 Gi limit, heap 75% of the limit                                      | It's a JVM. The default heap (25% of the limit) is too small for dashboard queries.                                                                                          |

## First deploy

**1. Database** (once). Create it on the current leader:

```bash
LEADER=$(kubectl -n database get pod -l role=master -o name | head -1)
kubectl -n database exec "$LEADER" -c postgresql -- psql -U postgres -c 'CREATE DATABASE metabase OWNER app;'
```

**2. Secret.** Seal `demo/metabase-secret`. The DB password is passed as-is, not inside a URL,
so it needs no URL-encoding.

```bash
PW=$(kubectl -n database get secret postgresql-ha-secret -o jsonpath='{.data.app-password}' | base64 -d)

kubectl create secret generic metabase-secret --namespace demo \
  --from-literal=db-password="$PW" \
  --from-literal=encryption-secret-key="$(openssl rand -hex 32)" \
  --from-literal=session-secret-key="$(openssl rand -hex 32)" \
  --from-literal=embedding-secret-key="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets-controller --format yaml \
> charts/metabase/templates/sealedsecret.yaml
```

The keys:

- `db-password`: required.
- `encryption-secret-key`: required. It encrypts the passwords Metabase stores for the
  databases it charts. **Set it before the first start and never change it.** Losing or
  rotating it makes every saved connection unreadable. Keep a copy outside the cluster.
- `session-secret-key`: required. It signs login sessions; changing it logs everyone out.
- `embedding-secret-key`: signs static-embed tokens. **x-hrm needs the same value** (as
  `METABASE_SECRET_KEY` in `demo/x-hrm-secret`) to generate embed URLs.

To rotate one key, use `kubeseal --merge-into` (see `note/seal.md`). Reloader restarts the pod.

**3. Commit** the chart, `apps/dev/metabase.yaml` and the sealed secret. The `dev-apps`
app-of-apps picks the Application up. Watch the first start:

```bash
kubectl -n demo logs deploy/metabase -f      # wait for "Metabase Initialization COMPLETE"
```

**4. Create the admin, over port-forward**, before anything is public:

```bash
kubectl -n demo port-forward svc/metabase 3000:3000     # → http://localhost:3000
```

Finish the setup wizard: create the admin account, and **skip "Add your data"** for now (see
step 7).

**5. Go public.**

- Set `ingress.enabled: true` in `values-dev.yaml` and commit.
- **NPM:** add a proxy host `bi.tiktuzki.com` → node1:80 in Nginx Proxy Manager, with TLS
  there, the same as `hrm.tiktuzki.com`.

**6. Google sign-in** (optional). Create an OAuth client, or add the origin to x-hrm's, with
`https://bi.tiktuzki.com` under *Authorized JavaScript origins*. Put its client id in
`app.googleClientId`. Set `app.googleAutoCreateDomain: newera.inc` only if every Google
Workspace user should get an account automatically. Otherwise leave it empty and invite people
under *Admin → People*.

**7. Connect x-hrm's data.** Add it under *Admin → Databases* with a **read-only role** on the
**replica** (`postgresql-ha-replica.database:5432`), limited to the `reporting` schema:
aggregates and IDs only, no candidate names, emails or CV text. The role and schema come from
x-hrm migrations (see `docs/REPORTING.md` in the x-hrm repo, once that exists). Don't connect the
`hrm` database as `app`: that role can write, and it sees every candidate's personal data.

**8. Static embedding.** It's switched on by `app.enableStaticEmbedding` and signed with
`embedding-secret-key`. Per dashboard: *Share → Embed → Static*, set each filter to **Locked**
(set by x-hrm, e.g. the TA's own id), **Editable** or **Disabled**, then **Publish**.

## Operating it

- **Upgrade:** bump `image.tag` and `appVersion` together. Read the release notes first, and
  back up the `metabase` database; migrations don't roll back.
- **Backup:** everything is in the `metabase` database on postgresql-ha. There's no volume to
  back up, but `infra/backup/backup.sh` has no Postgres dump yet.
- **Logs:** `kubectl -n demo logs deploy/metabase`. Metabase logs every API call, and failed
  queries show the SQL error.
