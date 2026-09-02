# tiktuzki-gitops

GitOps for **node1** — a single-node MicroK8s cluster reached over a NetBird mesh, with ArgoCD
syncing everything in this repo onto it.

This repo is the **operational source of truth**: the manifests, and the documentation that
explains them, both live here. Cluster docs are in **[`docs/`](docs/README.md)**; they are
mirrored onto [tiktuzki.com](https://www.tiktuzki.com/docs/dev-cluster) at build time and must
be edited here, never there.

| I want to…                           | Go to                                                |
|--------------------------------------|------------------------------------------------------|
| Understand or rebuild the cluster    | [`docs/README.md`](docs/README.md)                   |
| Find a host, port or credential name | [`ACCESS.md`](ACCESS.md)                             |
| See what hardening is next           | [`PLAN.md`](PLAN.md)                                 |
| Recover from a dead server           | [`infra/backup/RESTORE.md`](infra/backup/RESTORE.md) |

## Layout

```
tiktuzki-gitops/
├── docs/            cluster documentation — source of truth, mirrored to the site
│   └── dev-cluster/
├── bootstraps/      what you apply by hand once: ArgoCD, SSO
├── clusters/        per-cluster app-of-apps entry points
├── apps/            ArgoCD Applications (base + per-env overlays)
├── charts/          Helm charts owned by this repo
├── infra/           platform pieces: backup, monitoring, sealed-secrets, storage, limits, rbac
└── note/            scratch notes, not runbooks
```

## Bootstrapping

```bash
./startup.sh
```

Everything else is pulled by ArgoCD from this repo.

## Conventions

- Secrets are committed **sealed** (`infra/sealed-secrets/`). Nothing in this repo is a
  plaintext credential — `ACCESS.md` deliberately lists key *names* only.
- A change to how the cluster behaves and the doc describing it belong in the same commit.
- `note/` is for scratch. If something in it becomes a procedure someone follows, it graduates
  to `docs/`.
