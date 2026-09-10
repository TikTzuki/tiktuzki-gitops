# 9router

Self-hosted [9Router](https://github.com/decolua/9router) — an AI coding gateway that sits
between a coding client (Claude Code, Codex, Cursor, Cline, Copilot) and 40+ model providers,
with auto-fallback when one provider rate-limits.

MIT licensed. Image `decolua/9router`, multi-arch (amd64 + arm64), tag equals the upstream
git tag.

## What this chart deploys

```
Deployment (1 replica, Recreate)  ──>  PVC 9router-data  ──>  /app/data
        │                                                       db/  jwt-secret
        └─ Service :20128 (ClusterIP)  ──>  [Ingress, off by default]
```

One pod, one volume, no database. That is the whole topology, and it is not a simplification
that can be scaled away — see *Why one replica* below.

## First run — claim it before you expose it

This is the only step that is easy to get wrong and expensive to get wrong.

A fresh volume reports:

```json
{ "requireLogin": true, "hasPassword": false }
```

Login is required and **no password exists yet**. The instance is unclaimed: whoever reaches
it first and sets a password owns the gateway and every provider credential subsequently
stored in it. `ingress.enabled` is therefore `false` by default.

```bash
# 1. sync with the ingress off (the default), then reach it privately
kubectl -n demo port-forward svc/nine-router 20128:20128

# 2. open http://localhost:20128 and set the admin password

# 3. only now, set ingress.enabled: true in values-dev.yaml and let Argo CD sync
```

Login locks out after five failed attempts. The dashboard also supports OIDC and SAML, and
Google OIDC is the configured route here — see
[9Router SSO with Google](../../docs/operations/access/9router-google-sso.md).

Read that before enabling it. 9Router has **no authorization layer**: its OIDC callback signs
a session straight from the token with no allowlist, so whoever the IdP admits becomes gateway
admin. Argo CD survives the same issuer only because `policy.default: ''` catches strangers;
9Router has no equivalent, so the restriction has to be the Google consent screen set to
`User type: Internal`. Keep the local password as the way back in.

## Why `/app/data` and not `/data`

The upstream Quick Start says:

```bash
docker run -d -p 20128:20128 -v 9router-data:/data decolua/9router:latest
```

**That volume path is wrong.** `/data` does not exist in the image; the app reads
`DATA_DIR=/app/data`. Following the published command gives you a volume nothing ever writes
to, and state that vanishes on every restart. Verified against `0.5.69`:

```
$ docker run --rm --entrypoint sh decolua/9router:0.5.69 -c 'ls -lad /data /app/data'
ls: /data: No such file or directory
drwxr-xr-x  2 node node 4096 /app/data
```

After a clean boot `/app/data` contains `db/` and a `0600` `jwt-secret`. Losing it discards
all configuration and invalidates every issued token. The PVC carries
`helm.sh/resource-policy: keep` so `helm uninstall` cannot take the credentials with it.

Being `microk8s-hostpath`, the data sits on node1's disk. It is protected by the nightly
backup and by nothing else — see [backup-flow](../../docs/operations/backup-restore/backup-flow.md).

## Why the pod runs as root

The image entrypoint is:

```sh
chown -R node:node /app/data /app/data-home
exec su-exec node "$@"
```

It needs root to fix ownership on a newly provisioned volume, then drops to uid 1000 itself.
So `podSecurityContext` and `securityContext` are deliberately empty: setting
`runAsNonRoot: true` or `runAsUser: 1000` makes the `chown` fail on first boot and the server
cannot write its database. The process does not stay root:

```bash
kubectl -n demo exec deploy/nine-router -- id     # uid=1000(node)
```

## Why one replica

All state is local files on a ReadWriteOnce volume, with no external database and no leader
election. A second replica would either fail to schedule (RWO, single node) or race the first
on the same files. `replicaCount` is 1 and there is no HPA.

For the same reason the deployment strategy is `Recreate`, not `RollingUpdate`: a rolling
update would leave the new pod waiting on a volume the old pod still holds — a deadlock that
clears only when the old pod is deleted by hand. A few seconds of downtime is the better
trade for a single-replica service.

## Ingress

`className: public` — the MicroK8s ingress addon, which is **Traefik v3.6** since 1.35, not
ingress-nginx. `nginx.ingress.kubernetes.io/*` annotations are silently ignored by Traefik;
a couple of older charts here still carry them as no-ops. Don't copy that.

Streaming is the thing to watch. If long completions get truncated mid-stream, the timeout is
almost certainly **not** in Kubernetes:

| Where | What to change |
|---|---|
| Nginx Proxy Manager on the public VPS | `proxy_read_timeout` in the proxy host's Advanced tab — this is the nginx that actually buffers |
| Traefik | entrypoint / `ServersTransport` timeouts, not a per-Ingress annotation |
| 9Router itself | `KEEP_ALIVE_TIMEOUT` env var (ms) |

Public traffic reaches node1 via NPM over the NetBird mesh — see
[publish-private-server](../../docs/operations/cluster/publish-private-server.md).

## Configuration

Providers, routing **and SSO** are configured in the dashboard, not through values — they are
entered in the UI and stored in the volume. Only these env vars are read by the server:

| Variable | Use |
|---|---|
| `AUTH_COOKIE_SECURE` | `"true"` forces the `Secure` flag on the session cookie; otherwise set only when `X-Forwarded-Proto: https` arrives. `values-dev.yaml` sets it, because TLS terminates at NPM and the pod sees plain HTTP |
| `KEEP_ALIVE_TIMEOUT` | ms; raise if streamed completions are cut off |
| `NINEROUTER_PEER_TOKEN` | shared token for peer/tunnel features |
| `DEBUG_BACKGROUND_TOKEN_REFRESH` | verbose provider-token-refresh logging |

There is no OIDC env var. Issuer, client ID and client secret live in 9Router's database, so
SSO is a one-time manual step that the chart cannot express and a lost volume discards — see
[9Router SSO with Google](../../docs/operations/access/9router-google-sso.md).

If you need `NINEROUTER_PEER_TOKEN`, seal it and reference it with `envFrom` — this repo is
public, so never inline it. See [sealed-secrets](../../infra/sealed-secrets/README.md).

`/app/data-home` is chowned by the entrypoint but was empty after a clean boot and is
undocumented upstream; it is left ephemeral. If tunnel or Tailscale state turns out to live
there, give it its own claim rather than widening the data volume.

## Values worth knowing

| Key | Default | Note |
|---|---|---|
| `image.tag` | `0.5.69` | Pinned. Upstream says `latest`; releases land every few days |
| `replicaCount` | `1` | Do not raise — see above |
| `persistence.enabled` | `true` | On by default, unlike most charts here: this is credentials, not cache |
| `persistence.mountPath` | `/app/data` | Not `/data` |
| `ingress.enabled` | `false` | Claim the instance first |
| `resources.limits.memory` | `768Mi` | Holds buffers per in-flight stream; node1 has no headroom |
| `fullnameOverride` | `nine-router` | Resources cannot be called `9router`: Service names are DNS-1035 and must start with a letter |

## Verify

```bash
helm lint charts/9router -f charts/9router/values-dev.yaml

# --dry-run=SERVER, not client. Client-side dry-run validates schema but not name formats,
# so it happily accepted a Service called "9router" that the API server rejected: Service
# names are DNS-1035 labels and must start with a letter. Hence fullnameOverride below.
helm template 9router charts/9router -f charts/9router/values-dev.yaml | kubectl apply --dry-run=server -f -

kubectl -n demo exec deploy/nine-router -- wget -qO- localhost:20128/api/health   # {"ok":true}
kubectl -n demo exec deploy/nine-router -- id                                      # uid=1000(node)
kubectl -n demo get pvc nine-router-data
```

`/api/health` is the only endpoint that answers without a session — everything else 401s or
redirects to `/login`, so probes must not point at `/`.
