# x-hrm

New Era HRM: CV hub, the TA weekly report and the recruiting dashboard, in one image. uvicorn
serves the FastAPI API **and** the statically exported Next.js UI from the same origin, so there
is one Deployment, one Service and one ingress host. State: Postgres, plus a volume for uploaded
CV / JD files.

Source and image build: the `x-hrm` repo (`Dockerfile` at its root).

## Shape, and why

| Choice                                                        | Why                                                                                                                                                                                                                                                                                                                                                                                                                             |
|---------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **1 replica, `RollingUpdate`** (maxSurge 1, maxUnavailable 0) | Zero-downtime deploys: the old pod serves until the new one passes `/readyz` for 5s, and a 5s preStop sleep lets Traefik drop it before SIGTERM. Still never 2 replicas: jobs run on an in-process thread pool and startup marks every `running` job failed. During the few-second overlap of a deploy, a job running on the old pod is lost (as it was under Recreate) and may show `failed` while still finishing. Re-run it. |
| Migrations as an **initContainer** (`alembic upgrade head`)   | One replica plus maxSurge 1 means one migrator at a time. A failed migration stalls the rollout while the old pod keeps serving. That old pod runs on the migrated schema, so **migrations must be backward compatible**: expand, deploy, contract later.                                                                                                                                                                       |
| DB via **postgresql-ha HAProxy :5000**, not pgdog             | Alembic runs DDL and takes session locks, and psycopg uses server-side prepared statements. A transaction-mode pooler breaks both. :5000 follows the Patroni leader. This is the same deviation as `neo-flagd`.                                                                                                                                                                                                                 |
| Own database **`hrm`**, owned by `app`                        | Table names like `users` and `candidates` would collide in the shared `app` database.                                                                                                                                                                                                                                                                                                                                           |
| Readiness = `/readyz`, liveness = `/livez`                    | `/readyz`: database, schema at head, uploads writable. `/livez`: uvicorn answers. A database blip takes the pod out of the Service. It shouldn't restart it.                                                                                                                                                                                                                                                                    |
| Static local PV at `/srv/k8s-volumes/x-hrm`, `Retain`         | The cluster has no StorageClass. Deleting the Argo app must never delete CVs.                                                                                                                                                                                                                                                                                                                                                   |

## First deploy

**1. Image.** node1 is amd64, so build it for that platform:

```bash
# in the x-hrm repo
docker buildx build --platform linux/amd64 -t tiktuzki/x-hrm:$(git rev-parse --short HEAD) -t tiktuzki/x-hrm:latest --push .
```

**2. Database** (once). Create it on the current leader:

```bash
LEADER=$(kubectl -n database get pod -l role=master -o name | head -1)
kubectl -n database exec "$LEADER" -- psql -U postgres -c 'CREATE DATABASE hrm OWNER app;'
```

**3. Secret.** Seal `demo/x-hrm-secret`. The app reads one full URL, so **URL-encode the
password**: `openssl rand -base64` passwords contain `/` and `+`, which break a URL.

```bash
PW=$(kubectl -n database get secret postgresql-ha-secret -o jsonpath='{.data.app-password}' | base64 -d)
ENC=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$PW")

kubectl create secret generic x-hrm-secret --namespace demo \
  --from-literal=database-url="postgresql+psycopg://app:${ENC}@postgresql-ha-haproxy.database:5000/hrm" \
  --from-literal=secret-key="$(openssl rand -hex 32)" \
  --from-literal=anthropic-api-key='<sk-ant-…>' \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets-controller --format yaml \
> charts/x-hrm/templates/sealedsecret.yaml
```

The keys:

- `database-url`: required.
- `secret-key`: required. It signs session JWTs; changing it logs everyone out.
- `anthropic-api-key`: optional. Leave it out when `app.aiProvider` isn't `anthropic`.
- `migrate-db-url`: optional. Use it only when migrations should run as a different role.

To rotate one key, use `kubeseal --merge-into` (see `note/seal.md`). Reloader restarts the pod.

**4. Volume directory**, on node1:

```bash
sudo ./infra/storage/create-volume-dirs.sh    # creates /srv/k8s-volumes/x-hrm as 10001:10001
```

**5. Public access and Google login.**

- **NPM:** add a proxy host `hrm.tiktuzki.com` → node1:80 in Nginx Proxy Manager, with TLS
  there.
- **Google Cloud,** on the OAuth client in `app.googleClientId`:
  - add `https://hrm.tiktuzki.com` to *Authorized JavaScript origins*, or the sign-in button
    won't render;
  - enable the **Google Drive API** and **Google Sheets API** in that project, for the CV
    folder import and the candidate sheet sync.

**6. Commit** the chart, `apps/dev/x-hrm.yaml` and the sealed secret. The `dev-apps`
app-of-apps picks the Application up.

**7. Check:**

```bash
kubectl -n demo logs deploy/x-hrm -c migrate      # alembic output, ends at head
kubectl -n demo get pod -l app.kubernetes.io/name=x-hrm
curl -s https://hrm.tiktuzki.com/readyz            # {"status":"ready","checks":{"database":"up","schema":"head","uploads":"writable"}}
```

Sign in as `app.rootUserEmail`. That account is always HR_ADMIN.

## Moving existing data in (optional)

From a local database into the new one:

```bash
pg_dump -Fc --no-owner -d <local-hrm-url> -f hrm.dump
pg_restore --no-owner --role=app -d "postgresql://app:<pw>@node1:5432/hrm" hrm.dump
```

`node1:5432` is the postgresql-ha HAProxy primary (see `charts/postgresql-ha/README.md`).
Uploaded files are separate: copy them into `/srv/k8s-volumes/x-hrm/uploads/` on node1,
owned by `10001:10001`.

## Values that matter

| Value                                     | Default                  | Notes                                                                                |
|-------------------------------------------|--------------------------|--------------------------------------------------------------------------------------|
| `image.tag`                               | `latest`                 | Pin to a sha once CI publishes one.                                                  |
| `app.googleClientId`, `app.rootUserEmail` | —                        | **Required.** The render fails without them.                                         |
| `app.aiProvider` / `anthropicBaseUrl`     | `anthropic` / empty      | Set `anthropicBaseUrl: http://nine-router.demo:20128` to use the in-cluster gateway. |
| `migrations.enabled`                      | `true`                   | If turned off, run `alembic upgrade head` before every schema change.                |
| `persistence.localPath`                   | `/srv/k8s-volumes/x-hrm` | Must match `infra/storage/create-volume-dirs.sh`.                                    |
