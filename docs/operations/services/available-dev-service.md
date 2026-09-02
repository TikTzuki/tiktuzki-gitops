---
title: "Available dev services"
tags: [kubernetes]
sidebar_position: 1
---

# Available development services

What runs on node1 and how to reach it.

:::warning[Do not load-test this cluster]
It is a single bare-metal node. There is no capacity headroom and no second node to fail
over to.
:::

:::info[Credentials are not here]
This page lists **what exists and on which port**, never a username or password. Credential
*key names* live in [`ACCESS.md`](https://github.com/TikTzuki/tiktuzki-gitops/blob/main/ACCESS.md)
at the repo root, which is deliberately not published; the values themselves come from the
cluster's sealed secrets. Ask if you need access.
:::

## Getting on the network

Private services are reachable over the **NetBird** mesh, not a public address. We no longer
use raw WireGuard or OpenVPN — there is no `.ovpn` profile and no Tunnelblick step.

1. Get invited to the NetBird account and install the client from
   [netbird.io/downloads](https://netbird.io/downloads).
2. Sign in. Your machine joins the mesh and picks up a peer address automatically.
3. Public web services need no VPN at all — they come in through Nginx Proxy Manager on the
   public VPS. See
   [Publish a private k8s cluster](../cluster/publish-private-server).

The node's own mesh address and the port mapping are in `ACCESS.md`; below, **mesh** means
"reachable once NetBird is up" and the port is the NodePort.

## Web services

Reached over HTTPS through the public proxy — no VPN needed.

| Service             | URL                               |
|---------------------|-----------------------------------|
| Nginx Proxy Manager | `https://proxy.tiktuzki.com`      |
| Kafka UI            | `https://kafka-ui.tiktuzki.com`   |
| Reposilite          | `https://reposilite.tiktuzki.com` |
| Jenkins             | `https://jenkins.tiktuzki.com`    |
| Argo CD             | `https://argocd.tiktuzki.com`     |
| Grafana             | `https://grafana.tiktuzki.com`    |
| Keycloak            | `https://keycloak.tiktuzki.com`   |

Argo CD, Grafana and kafka-ui authenticate through Keycloak — see
[Keycloak SSO](../access/keycloak-sso).

## Services on the mesh

| Namespace | Service                  | Access | Port  |
|-----------|--------------------------|--------|-------|
| kafka     | Kafka                    | mesh   | 31442 |
| kafka     | NATS JetStream           | mesh   | 32308 |
| kafka     | NATS monitoring          | mesh   | 32309 |
| database  | PostgreSQL / TimescaleDB | mesh   | 30687 |
| database  | Redis (master)           | mesh   | 32749 |
| database  | MongoDB                  | mesh   | 31317 |
| database  | Cassandra                | mesh   | —     |

`ACCESS.md` is the authoritative port list and is regenerated from the live cluster; if this
table and that one disagree, trust `ACCESS.md`.

## Connecting

Once NetBird is up, use the node's mesh address as the host. Fetch credentials from the
cluster rather than pasting them anywhere:

```bash
# the value never needs to leave your shell
kubectl -n database get secret <secret-name> -o jsonpath='{.data.<key>}' | base64 -d
```

```bash
# PostgreSQL, using the key names listed in ACCESS.md
psql -h <netbird-peer-address> -p 30687 -U <user> -d <database>

# Redis
redis-cli -h <netbird-peer-address> -p 32749
```

## Notes

- Web services go through the public proxy; database and broker ports do not and require
  the mesh.
- Ports are NodePorts on a single node, so they are stable but not load-balanced.
- KubeSphere is **no longer installed**. The cluster is plain MicroK8s driven by Argo CD —
  see [Rebuilding node1 from scratch](../cluster/cluster-rebuild).
