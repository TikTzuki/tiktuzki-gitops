---
name: new-chart
description: Build a new Helm chart in tiktuzki-gitops for node1. Pick an upstream to start from (CloudPirates or Bitnami, from a local index of 136 charts), or write one in house style, then wire it into Argo CD with a static local PV, SealedSecret, Traefik ingress and values-dev.yaml. Use when asked to "add a chart", "deploy X to the cluster", "vendor the X chart", "is there a chart for X", or to copy a template pattern (PDB, NetworkPolicy, ServiceMonitor, StatefulSet) from upstream.
argument-hint: "[software-or-chart-name]"
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# New Chart

Charts here aren't installed from a Helm repo. Each one lives in `charts/<name>/` and Argo CD
renders it from git. Upstream charts are **raw material**: copy one, then make it fit node1, a
single node with no StorageClass, sealed secrets and TLS terminated off-cluster.

## Sources

| Source                                                  | Local clone                                                  | Use it for                                                                                                         |
|---------------------------------------------------------|--------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------|
| [upstream-index.md](references/upstream-index.md)       | — (generated)                                                | **Start here.** Every upstream chart: version, image, workload kind, optional features, whether we already have it |
| CloudPirates                                            | `~/Desktop/repos/personal/cloud-pirates-helm-charts/charts/` | 18 charts on **official upstream images**. First choice to vendor                                                  |
| Bitnami                                                 | `~/Desktop/repos/personal/bitnami-charts/bitnami/`           | 118 charts plus `template/CHART_NAME/`. A **pattern library**: their images are frozen (see below)                 |
| [upstream-patterns.md](references/upstream-patterns.md) | —                                                            | Which upstream file to copy for each resource type, common-library helpers, and how to strip a vendored chart      |

Rebuild the index after pulling either clone:

```bash
git -C ~/Desktop/repos/personal/cloud-pirates-helm-charts pull
git -C ~/Desktop/repos/personal/bitnami-charts pull
python3 .claude/skills/new-chart/scripts/index-upstream.py
```

## Step 1: decide how to build it

Look the software up in [upstream-index.md](references/upstream-index.md), then pick:

| Situation                                        | Do this                                                                                                                                                                                                                                                                                                                                                                |
|--------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| The index says `vendored` or `own x`             | **Stop.** We already have one. Extend `charts/x` rather than adding a second. `own postgres`/`own kafka`/`own postgresql-ha` are deliberately hand-written; read their `values.yaml` header for why                                                                                                                                                                    |
| CloudPirates has it                              | **Vendor it** (`cp -r`) like `keycloak` and `timescaledb`, then apply the node1 overlay (Step 2)                                                                                                                                                                                                                                                                       |
| Only Bitnami has it                              | Its default images are `bitnamilegacy/*` (frozen, no CVE fixes) or hardened `latest` only. Either **vendor and repoint `image.*` at the official upstream image**, checking the entrypoint and env vars, which Bitnami images customise heavily, or **write your own** chart and borrow Bitnami's templates. A simple single-container app is usually quicker to write |
| Nobody has it, or it's our own app               | **Write it in house style.** Copy `charts/x-hrm` (deployment + PV + SealedSecret + ingress, fully commented) and rename                                                                                                                                                                                                                                                |
| It's an operator or a big multi-component system | Prefer the project's own official chart, kept as a pinned dependency or an Argo `Application` pointing at its repo (see `apps/base/traefik.yaml`, `monitoring.yaml`). Don't vendor thousands of lines of CRDs                                                                                                                                                          |

State the choice and the reason in the chart's `values.yaml` header comment. Every chart here
explains itself, and the next reader needs to know why it isn't plain upstream.

## Step 2: the node1 overlay (every chart)

These are the house conventions. A chart missing any of them either fails on node1 or fails
review.

1. **Storage is a static local PV.** There is no StorageClass. Add `templates/pv.yaml` and
   `templates/pvc.yaml` as in `charts/x-hrm` (vendored charts: `charts/timescaledb/templates/pv.yaml`):
   `persistence.useLocalVolume: true`, `localPath: /srv/k8s-volumes/<name>`, `nodeAffinity` on
   `kubernetes.io/hostname: node1`, `persistentVolumeReclaimPolicy: Retain`, and the PVC pinned
   by `volumeName`. For a StatefulSet with `volumeClaimTemplates`, the PV must match the
   template's claim name and size instead.
2. **Register the directory** in `infra/storage/create-volume-dirs.sh` with the uid:gid the
   container runs as. A missing or wrongly owned dir shows up as CrashLoopBackOff with a
   permission error. On node1, run the script **after** checking `/srv/k8s-volumes` is mounted.
   The script refuses to run otherwise.
3. **Secrets are SealedSecrets.** Never put plaintext in `values*.yaml`. Use the chart's
   `existingSecret` (the index's `features` column says which charts accept one) and commit
   `templates/<name>-sealedsecret.yaml`. Generate it like this:
   ```bash
   kubectl create secret generic <name>-secret -n <ns> --from-literal=key=… --dry-run=client -o yaml \
   | kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets-controller \
       --format yaml > charts/<name>/templates/<name>-sealedsecret.yaml
   # add/rotate one key without the others:  … | kubeseal … --merge-into <existing file>
   ```
   Run it as a single shell line and keep it out of shell history. Don't save the
   `--from-literal` one-liner to `note/`, even though that directory is gitignored.
   Vendored charts often also template their **own** Secret; disable it or bypass it
   (`existingSecret` usually does).
4. **Ingress:** Traefik, `className: public`, `tls: []`. TLS terminates at NPM on the public VPS,
   so you add a proxy host `<host> → node1:80` there. TCP services (databases) don't use
   Ingress: add an entryPoint in `apps/base/traefik.yaml` plus an `IngressRouteTCP` in
   `infra/ingress-tcp/routes-tcp.yaml`. Both are required (see that file's header).
5. **Resources:** set memory requests and limits, plus a CPU **request**, and **no CPU limit**
   (house rule, `infra/limits/limitranges.yaml`).
6. **Images:** pin a real tag. Built on a Mac: `--platform linux/amd64`, because node1 is amd64.
7. **`values.yaml` holds safe defaults** (no ingress, nothing pointing at a real database).
   **`values-dev.yaml` holds node1's settings.** Comment every non-obvious value with *why*.
8. **Probes:** separate liveness (process alive, no dependencies) from readiness (dependencies
   OK). Copy the reasoning block in `charts/x-hrm/values.yaml`.

## Step 3: wire it into Argo CD

- An app or demo → `apps/dev/<name>.yaml`. Shared infrastructure (a database, broker, identity) →
  `apps/base/<name>.yaml`. Copy `apps/dev/x-hrm.yaml`: `path: charts/<name>`,
  `valueFiles: [values-dev.yaml]`, automated prune + selfHeal, retry backoff.
- Namespace: data stores go in `database` (`CreateNamespace=false`, it already exists), apps in
  `demo`. A system with its own operators, RBAC or many components gets its own namespace
  (`monitoring`, `openclaw`, `ai-model`) with `CreateNamespace=true`.
- Pin `releaseName` when other config bakes in pod DNS names (see `apps/base/timescaledb-ha.yaml`).

## Step 4: verify before committing

```bash
helm dependency build charts/<name>          # only if Chart.yaml has dependencies
helm lint charts/<name> -f charts/<name>/values-dev.yaml
helm template t charts/<name> -f charts/<name>/values-dev.yaml -n <ns> > /tmp/<name>.yaml
grep -nE 'kind: (Secret|PersistentVolume)\b' /tmp/<name>.yaml   # no plaintext Secret; PV present
grep -n 'storageClassName' /tmp/<name>.yaml                       # must be "" (static PV)
```

Then check the service list doc (`docs/operations/services/available-dev-service.md`) and
`ACCESS.md` (key **names** only) for an entry to add. Per the repo README, a change to the
cluster and the doc describing it go in the same commit.

## Licensing

Both upstreams are Apache-2.0. A vendored chart keeps its `LICENSE` file (or the header comments
in its templates). Note the upstream version you copied in `Chart.yaml` `annotations` or the
values header, so a later diff against upstream is possible.
