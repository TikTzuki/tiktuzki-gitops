# Cluster documentation

Everything written about **node1** lives in this repo, next to the manifests it describes, so
a change to the cluster and the change to its documentation land in the same commit.

These files are the source of truth. The public site at
[tiktuzki.com/docs/operations](https://www.tiktuzki.com/docs/operations) is a **copy**, pulled
in at build time by `tik_space/scripts/sync-knowledge.mjs` in the `TikTzuki` repo. Editing the site
copy does nothing — it is overwritten on every build.

## Published — `docs/operations/`

Synced to the site under `/docs/operations`. Every file needs Docusaurus front matter
(`title`, `tags`, `sidebar_position`); the tag must exist in `TikTzuki/tik_space/docs/tags.yml`
or **the site build fails**.

| Doc                                                                                          | What it answers                                                                                   |
|----------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------|
| [operations/cluster/publish-private-server.md](operations/cluster/publish-private-server.md) | **How the cluster is reached today** — NetBird mesh + Nginx Proxy Manager on a public VPS.        |
| [operations/cluster/static-ip-netplan.md](operations/cluster/static-ip-netplan.md)           | Pinning node1's address so MicroK8s API certs and the overlay peer stop breaking on DHCP renewal. |
| [operations/cluster/cluster-rebuild.md](operations/cluster/cluster-rebuild.md)               | Bare MicroK8s → running cluster, in order. Everything is recoverable except step 5.               |
| [operations/access/kubectl-credentials.md](operations/access/kubectl-credentials.md)         | Per-person kubectl certs instead of sharing the one `admin` cert.                                 |
| [operations/backup-restore/backup-flow.md](operations/backup-restore/backup-flow.md)         | **Setting backup up**: what gets captured, the two storage classes, encryption, and Steps 1–5.    |
| [operations/services/available-dev-service.md](operations/services/available-dev-service.md) | What is running and how to reach it.                                                              |

### Also published, from outside `docs/`

These stay beside the manifests they describe and are routed to the site by
`knowledge-map.yaml` at the repo root. Do not move them into `docs/` — the point is that a
manifest change and its doc change land in one commit.

| Source                                                                           | Published as                                |
|----------------------------------------------------------------------------------|---------------------------------------------|
| [../infra/monitoring/README.md](../infra/monitoring/README.md)                   | `operations/observability/monitoring-stack` |
| [../infra/sealed-secrets/README.md](../infra/sealed-secrets/README.md)           | `operations/secrets/sealed-secrets`         |
| [../bootstraps/argocd/sso/README.md](../bootstraps/argocd/sso/README.md)         | `operations/access/keycloak-sso`            |
| [../bootstraps/argocd/sso/GOOGLE-SSO.md](../bootstraps/argocd/sso/GOOGLE-SSO.md) | `operations/access/argocd-google-sso`       |
| [../charts/timescaledb-ha/README.md](../charts/timescaledb-ha/README.md)         | `operations/services/timescaledb-ha`        |

## Not published — repo-local by design

| Doc                                                      | Why it stays here                                                                                                                                                                    |
|----------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| [../ACCESS.md](../ACCESS.md)                             | A complete access-surface map of a live cluster. Records credential **key names** only, never values — but it is still not something to publish.                                     |
| [../PLAN.md](../PLAN.md)                                 | A hardening backlog is a list of what is not yet hardened.                                                                                                                           |
| [../infra/backup/RESTORE.md](../infra/backup/RESTORE.md) | Disaster-recovery runbook. Read from `/opt/cluster-backup/` on the node during an incident.                                                                                          |
| [history/](history/)                                     | Retired procedures, kept for the record. Never follow these. Currently the raw-WireGuard build and the old LVM/pg_dump backup flow — we no longer use WireGuard directly or OpenVPN. |
| [../note/](../note/)                                     | Scratch. Gitignored, holds paste-and-run one-liners with real credentials. Never commit it.                                                                                          |

## Adding a doc

Put it under `docs/operations/<area>/` with front matter:

```yaml
---
title: What this explains
tags: [ kubernetes ]
sidebar_position: 5
---
```

Tags must exist in `TikTzuki/tik_space/docs/tags.yml`. To publish something from outside
`docs/`, add a line to `knowledge-map.yaml` instead of moving the file.

To publish immediately rather than waiting for the nightly run:

```bash
gh api repos/TikTzuki/TikTzuki/dispatches -f event_type=knowledge-updated
```
