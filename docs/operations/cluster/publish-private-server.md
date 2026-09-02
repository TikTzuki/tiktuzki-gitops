---
title: "Publish a private k8s cluster (NetBird + NPM)"
tags: [kubernetes, networking, security]
sidebar_position: 1
---

# Publish a Private k8s Cluster via a Public Proxy

How to expose apps running on a **private server** (`node1`, a MicroK8s cluster with **no public IP** — at home/office
behind NAT) to the public internet, using a cheap **public VPS** as the edge and **NetBird** (a WireGuard mesh VPN) as
the private transport between them.

This is the current approach, and the only one. The earlier raw-WireGuard setup is retired
and no longer published: NetBird manages peers and keys itself, so there is no
hand-maintained `wg0.conf` to keep in sync. OpenVPN is not used either.

## Architecture

```
                          Internet
                              │  https://app.tiktuzki.com
                              ▼
   ┌──────────────────────── PUBLIC VPS (proxy) ────────────────────────┐
   │  Nginx Proxy Manager (NPM)   → owns :80 / :443, terminates TLS      │
   │  NetBird server              → VPN control plane (mgmt/signal/relay) │
   │  NetBird client              → makes the VPS a peer on the overlay   │
   └────────────────────────────────┬───────────────────────────────────┘
                                     │  encrypted NetBird overlay (100.66.0.0/16)
                                     ▼
   ┌──────────────────────── PRIVATE SERVER (node1) ────────────────────┐
   │  NetBird client              → peer 100.66.97.47                     │
   │  MicroK8s ingress (hostNetwork) → listens on node1:80               │
   │  your apps (Deployments + Services + Ingress)                        │
   └─────────────────────────────────────────────────────────────────────┘
```

**Request flow for an app:**

```
browser ─▶ Cloudflare DNS (grey/DNS-only) ─▶ NPM on the VPS (TLS)
        ─▶ [NetBird overlay] ─▶ node1:80 ingress (Host preserved)
        ─▶ k8s Service ─▶ pod
```

The VPS is the only thing with a public IP. NetBird carries traffic from the VPS to the private cluster. The cluster
never exposes a port to the internet.

:::tip[Why NetBird and not plain WireGuard]
NetBird gives you a managed mesh (auto key exchange, ACLs, NAT traversal, a dashboard) on top of WireGuard. The
trade-off is that its control plane speaks **gRPC over HTTP/2** and **UDP STUN**, which shapes how you must proxy it (
see the gotchas).
:::

---

## Hard-won gotchas (read first — each one cost hours)

1. **NetBird DNS records must be Cloudflare "DNS only" (grey cloud).** NetBird needs end-to-end **gRPC (HTTP/2)** and *
   *UDP 3478 (STUN)**; Cloudflare's proxy (orange cloud) carries neither and returns an HTML `403`/drops UDP. Web apps
   may be orange-clouded; `netbird.*` must stay grey.
2. **A k8s NodePort is NOT reachable over the NetBird overlay.** With Calico, traffic arriving on the VPN interface (
   `wt0`) destined for a pod is dropped by `cali-FORWARD`. Only **host-terminated** services work over the overlay: SSH,
   a hostNetwork ingress on `:80`, or a `socat`/TCP-stream forwarder. (That's why the ingress controller runs in
   `hostNetwork` mode.)
3. **NPM runs in Docker, so `127.0.0.1` inside it is the container, not the host.** To reach another container, put NPM
   on that container's Docker network and use the **container name**. Routable IPs (the overlay `100.66.x.x`) work
   directly from the container.
4. **NetBird's gRPC needs `HTTP/2` ON + `grpc_pass`** in the reverse proxy, not plain `proxy_pass`.

---

## Part A — Public VPS (the proxy/edge)

Minimum 2 vCPU / 1 GB RAM. Replace `tiktuzki.com` with your domain and `<VPS_PUBLIC_IP>` with the VPS IP.

### A1. Docker

```bash
curl -fsSL https://get.docker.com | sh
docker version && docker compose version
```

### A2. NetBird server (self-hosted, combined container)

```bash
mkdir -p /opt/netbird && cd /opt/netbird
export NETBIRD_DOMAIN=netbird.tiktuzki.com
export BIND_LOCALHOST_ONLY=true          # publish backend HTTP ports on 127.0.0.1 only
curl -fsSL https://github.com/netbirdio/netbird/releases/latest/download/getting-started.sh -o getting-started.sh
bash getting-started.sh
```

When prompted for a reverse proxy, pick **Manual / "my own proxy"** (NOT the built-in Traefik — it would grab
`:80/:443`). This brings up two containers on a Docker network (`netbird_netbird`):

| Container           | Internal port           | Serves                                                    |
|---------------------|-------------------------|-----------------------------------------------------------|
| `netbird-dashboard` | `80`                    | the web UI                                                |
| `netbird-server`    | `80` (h2c) + `3478/udp` | management + signal (gRPC), relay (WS), `/api`, `/oauth2` |

**Open `3478/udp` to the internet** (cloud firewall + host firewall) — STUN cannot be proxied. Everything else stays on
localhost / the Docker network.

### A3. Nginx Proxy Manager (the public edge)

NPM owns `:80/:443` and terminates TLS for every domain.

`/opt/npm/docker-compose.yml`:

```yaml
services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    container_name: npm
    restart: unless-stopped
    ports:
      - '80:80'
      - '443:443'
      - '81:81'      # admin UI
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    networks:
      - default
      - netbird       # so NPM can reach the netbird-* containers by name

networks:
  default:
  netbird:
    external: true
    name: netbird_netbird
```

```bash
cd /opt/npm && docker compose up -d
```

First run shows a setup wizard on `:81` — reach it with an SSH tunnel (`ssh -L 81:127.0.0.1:81 root@<VPS_PUBLIC_IP>` →
`http://localhost:81`) until you give it a domain.

**Issue a wildcard cert:** NPM → *SSL Certificates* → Add → Let's Encrypt → **Use a DNS Challenge** → Cloudflare (API
token, `Zone:DNS:Edit`) → `*.tiktuzki.com`. DNS challenge is required because there's no spare `:80` for HTTP-01 once
NPM is the edge, and it covers every subdomain at once.

### A4. Expose the NetBird server through NPM (the tricky one — gRPC)

NPM → *Hosts → Proxy Hosts → Add*:

- **Details:** Domain `netbird.tiktuzki.com` · Scheme `http` · Forward Hostname **`netbird-dashboard`** · Port **`80`
  ** · **Websockets Support: ON** · **HTTP/2 Support: ON**
- **SSL:** the `*.tiktuzki.com` cert · Force SSL
- **Advanced** (NPM's point-and-click can't express gRPC — paste raw nginx; note it targets the `netbird-server`
  container):

```nginx
location ~ ^/(relay|ws-proxy/) {
    proxy_pass http://netbird-server:80;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "Upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 1d;
}
location ~ ^/(signalexchange\.SignalExchange|management\.(ManagementService|ProxyService))/ {
    grpc_pass grpc://netbird-server:80;
    grpc_read_timeout 1d;
    grpc_send_timeout 1d;
    grpc_socket_keepalive on;
}
location ~ ^/(api|oauth2)/ {
    proxy_pass http://netbird-server:80;
    proxy_set_header Host $host;
}
```

**DNS:** Cloudflare → `netbird.tiktuzki.com` → A → `<VPS_PUBLIC_IP>`, **grey cloud (DNS only)**. Then open
`https://netbird.tiktuzki.com` and create the first admin (embedded IdP).

### A5. Make the VPS itself a peer

So the VPS can reach the private cluster over the overlay. Create a **Setup Key** in the NetBird dashboard, then:

```bash
curl -fsSL https://pkgs.netbird.io/install.sh | sh
netbird up --management-url https://netbird.tiktuzki.com --setup-key <SETUP_KEY>
netbird status        # Management/Signal: Connected
```

---

## Part B — Private server (node1, MicroK8s)

### B1. Join the overlay

```bash
curl -fsSL https://pkgs.netbird.io/install.sh | sh
netbird up --management-url https://netbird.tiktuzki.com --setup-key <SETUP_KEY>
netbird status        # note this peer's IP, e.g. 100.66.97.47
```

### B2. Ingress controller in hostNetwork mode

:::info[Superseded on MicroK8s 1.35+]
The `ingress` addon now installs **Traefik**, which binds `:80/:443` with **`hostPort`** out
of the box — and hostPort *is* reachable over the overlay (verified). There is no
`nginx-ingress-microk8s-controller` daemonset to patch and no hostNetwork step. Just:

```bash
microk8s enable ingress
```

Gotcha #2 below still holds for a **NodePort**, but no longer for hostPort. See
*Rebuilding node1 from scratch* for the current procedure.
:::

Historically a NodePort/hostPort couldn't be reached over the overlay, so the fix was a
**hostNetwork** ingress binding `node1:80` directly in the host netns:

```bash
# only for the old nginx-based addon
microk8s kubectl -n ingress patch daemonset nginx-ingress-microk8s-controller \
  -p '{"spec":{"template":{"spec":{"hostNetwork":true,"dnsPolicy":"ClusterFirstWithHostNet"}}}}'
```

Confirm it's reachable over the overlay from the VPS:

```bash
# on the VPS (a peer):
curl -H 'Host: anything' http://100.66.50.60/    # 404 from ingress = reachable
```

---

## Part C — Publish an HTTP app

Three pieces per app. Example: `app.tiktuzki.com` → a Service `app-svc:80`.

**1. k8s Ingress (on node1)** — maps the hostname to the Service:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app
spec:
  ingressClassName: public        # MicroK8s ingress class
  rules:
    - host: app.tiktuzki.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app-svc
                port:
                  number: 80
```

> The Service can be plain `ClusterIP` — the ingress reaches it in-cluster. You do **not** need a NodePort.

**2. NPM proxy host (on the VPS)** — *Hosts → Proxy Hosts → Add*:

- Domain `app.tiktuzki.com` · Scheme `http` · Forward **`100.66.97.47`** · Port **`80`** · Websockets ON
- SSL: `*.tiktuzki.com`, Force SSL

NPM keeps the original `Host` header, so node1's ingress matches the right rule.

**3. DNS:** `app.tiktuzki.com` → A → `<VPS_PUBLIC_IP>` (grey cloud is fine; orange also works for pure HTTP apps).

**Verify:**

```bash
curl -H 'Host: app.tiktuzki.com' http://100.66.97.47/   # on node1: the app responds
curl -I https://app.tiktuzki.com                        # end to end
```

---

## Part D — Publish a TCP service (databases, etc.)

A normal Ingress is HTTP-only. For raw TCP (Postgres, Redis, TigerBeetle…) use the MicroK8s ingress controller's **TCP
ConfigMap** — it makes the same hostNetwork controller listen on an extra TCP port (host-terminated →
overlay-reachable):

:::info[Traefik uses two objects, not a ConfigMap]
On MicroK8s 1.35+ the TCP ConfigMap does not exist. Traefik needs an **entryPoint** (static
Helm config, `apps/base/traefik.yaml`) *and* an **IngressRouteTCP**
(`infra/ingress-tcp/routes-tcp.yaml`) naming it:

```yaml
# 1. entryPoint + hostPort, in the Traefik Helm values
ports:
  postgres: { port: 5432, exposedPort: 5432, hostPort: 5432, protocol: TCP }
```

```yaml
# 2. the route
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata: { name: timescaledb, namespace: database }
spec:
  entryPoints: [ postgres ]
  routes:
    - match: HostSNI(`*`)      # the only valid match on a non-TLS port
      services: [ { name: timescaledb, port: 5432 } ]
```

An entryPoint with no route accepts then closes the connection; a route naming a
non-existent entryPoint is silently ignored. Verify with `nc -z`, **never** `ss` —
hostPort is iptables DNAT, not a listening socket.
:::

The old nginx mechanism, for reference:

```bash
# format:  "<listen-port>": "<namespace>/<service>:<port>"
microk8s kubectl -n ingress patch configmap nginx-ingress-tcp-microk8s-conf \
  --type merge -p '{"data":{"5432":"database/timescaledb:5432"}}'
```

Then connect over the overlay (no public proxy involved — DBs are not for the internet):

```bash
psql "host=100.66.97.47 port=5432 user=postgres dbname=postgres"
```

Make sure the NetBird **Access Control policy** permits the source peer → node1 on that port.

---

## Troubleshooting

| Symptom                                                     | Cause / fix                                                                                                                              |
|-------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------|
| NetBird client: `403 ... content-type "text/html"` on login | `netbird.*` is **orange-clouded** → set it to **grey (DNS only)** in Cloudflare.                                                         |
| NetBird dashboard loads but login/peers hang                | gRPC not passing → confirm **HTTP/2 ON** and the `grpc_pass` Advanced block on the NPM host.                                             |
| NPM `502 Bad Gateway` to a netbird container                | NPM used `127.0.0.1` (its own loopback). Use the **container name** + ensure NPM is on the `netbird_netbird` network.                    |
| App reachable on `node1:3xxxx` but not over the VPN         | It's a **NodePort** → Calico drops the overlay→pod forward. Expose via the **hostNetwork ingress** (`:80`) or the TCP ConfigMap instead. |
| Peers connect but can't reach each other                    | `3478/udp` not public, or NetBird **Access Control** policy / direction blocks it (make rules bidirectional).                            |
| `curl https://app...` → wrong app / wrong cert              | NPM has no proxy host for that domain → request falls through to the default vhost. Add the proxy host.                                  |

## Notes

- Keep NetBird records **grey cloud** permanently. If they keep flipping to orange, check Cloudflare bulk settings / any
  automation.
- Treat **setup keys** as secrets — never commit them.
- Everything the cluster publishes goes **VPS → overlay → node1**; the private server needs only **outbound** internet (
  to reach the NetBird control plane) and never a public port.
