# Upstream Patterns: What to Copy From Where

**Rule: copy the template, not the defaults.** Upstream charts are written to work for anyone
on any cluster. Node1 is one specific cluster: no StorageClass, Argo CD rendering offline,
sealed secrets. Most of the work of vendoring is deleting the generality.

Paths are relative to `~/Desktop/repos/personal/`. `CP` = `cloud-pirates-helm-charts/charts`,
`BN` = `bitnami-charts`.

## Contents

- [The Argo CD gotcha: `lookup` and generated passwords](#the-argo-cd-gotcha-lookup-and-generated-passwords)
- [Which file to copy, by resource](#which-file-to-copy-by-resource)
- [Common-library helpers](#common-library-helpers)
- [Values conventions both upstreams share](#values-conventions-both-upstreams-share)
- [Vendoring checklist](#vendoring-checklist)
- [Bitnami images after August 2025](#bitnami-images-after-august-2025)

## The Argo CD gotcha: `lookup` and generated passwords

Argo CD renders charts with `helm template`, which has **no cluster access**, so Helm's
`lookup` function always returns empty. Both upstreams depend on `lookup` to keep an
auto-generated password stable across upgrades:

- CP `cloudpirates.secrets.lookup` (`CP/common/templates/_secrets.tpl`)
- BN `common.secrets.passwords.manage` / `common.secrets.lookup`

Under Argo, the lookup finds nothing, so **a new random password is rendered on every sync**.
The Secret changes and the database doesn't, so the app's credentials stop matching. Self-heal
then keeps re-applying the drift.

**Always set `existingSecret`** (backed by a SealedSecret) on every chart that generates
credentials. If a chart has no such option, template the Secret from the SealedSecret yourself
and disable the chart's own.

## Which file to copy, by resource

| Resource / concern                          | Best source                                                                                       | Why that one                                                                                                                                                                                |
|---------------------------------------------|---------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Whole-chart scaffold                        | `BN/template/CHART_NAME/`                                                                         | Every optional resource, already wired to `common.*`. Replace `CHART_NAME` and delete what you don't need. Its `README.md` lists the values every Bitnami-style chart is expected to expose |
| StatefulSet (database-style)                | `CP/postgres/templates/statefulset.yaml`                                                          | Plain official image, readable, config checksum annotations, security contexts via helpers                                                                                                  |
| StatefulSet with replication/sentinel       | `CP/redis/templates/statefulset.yaml` (+ `sentinel-*`, `headless-service.yaml`)                   | The architecture switch `standalone`/`replication` done in one template                                                                                                                     |
| Deployment (stateless)                      | `CP/nginx/templates/deployment.yaml`                                                              | Minimal, with HPA and ingress next to it                                                                                                                                                    |
| HPA                                         | `CP/nginx/templates/hpa.yaml`                                                                     | `autoscaling/v2`, CPU and memory targets                                                                                                                                                    |
| Ingress                                     | `CP/nginx/templates/ingress.yaml`, or our `charts/x-hrm/templates/ingress.yaml`                   | Ours already defaults to `className: public` and has no TLS                                                                                                                                 |
| PodDisruptionBudget                         | `CP/redis/templates/pdb.yaml`                                                                     | `minAvailable`/`maxUnavailable` both optional. On one node a PDB mostly blocks drains; keep `pdb.enabled: false` unless replicas > 1                                                        |
| NetworkPolicy                               | `CP/redis/templates/networkpolicy.yaml`, or `BN/template/CHART_NAME/templates/networkpolicy.yaml` | BN's version has the `allowExternal` + `extraIngress`/`extraEgress` pattern                                                                                                                 |
| ServiceMonitor (Prometheus)                 | `CP/redis/templates/servicemonitor.yaml` (+ `metrics-service.yaml`)                               | node1's Prometheus selects **every** ServiceMonitor (`serviceMonitorSelectorNilUsesHelmValues: false` in `apps/base/monitoring.yaml`), so no `release` label is needed                      |
| Secret with stable random password          | `CP/postgres/templates/secret.yaml`                                                               | Shows the lookup pattern. **Read the gotcha above first**                                                                                                                                   |
| Config file → ConfigMap + rollout on change | `CP/redis/templates/configmap.yaml` with the `checksum/config` annotation in its statefulset      | Pods restart when the config changes. Alternatively the cluster runs `reloader` (`apps/base/reloader.yaml`)                                                                                 |
| One-shot init/bootstrap Job                 | `CP/redis/templates/job.yaml`                                                                     | Cluster-init job as a Helm hook                                                                                                                                                             |
| CronJob (backups)                           | `BN/bitnami/postgresql/templates/backup/cronjob.yaml`                                             | `pg_dumpall` onto a PVC. Compare with `infra/backup`, which already backs up node1                                                                                                          |
| Volume-permission initContainer             | `BN/template/CHART_NAME/templates/_init_containers.tpl`                                           | `chown` of the data dir. Usually unnecessary here: `create-volume-dirs.sh` pre-chowns and `fsGroup` covers the rest                                                                         |
| Self-signed TLS secret                      | `BN/template/CHART_NAME/templates/tls-secret.yaml`                                                | `genCA`/`genSignedCert`. Regenerated on every render under Argo (same `lookup` problem). Only for in-cluster TLS                                                                            |
| RBAC (Role/Binding)                         | `BN/template/CHART_NAME/templates/role.yaml` + `clusterrolebinding.yaml`                          | Rules come from values, `rbac.create` toggle. Bind with a namespaced RoleBinding unless you really need cluster scope                                                                       |
| VPA                                         | `BN/template/CHART_NAME/templates/vpa.yaml`                                                       | Only if the VPA CRDs exist (they don't on node1 today)                                                                                                                                      |
| Escape hatch for extra manifests            | `CP/redis/templates/extraobjects.yaml` · `BN/template/CHART_NAME/templates/extra-list.yaml`       | `extraObjects`/`extraDeploy` rendered with `tpl`. Our `timescaledb-ha`/`postgresql-ha` follow CP's name                                                                                     |
| Unit tests                                  | `CP/redis/tests/*_test.yaml` (`helm unittest`) and `CP/redis/ci/*.yaml` (values for CI lint)      | Upstream tests are worth keeping when you vendor. Delete `openshift_test.yaml`                                                                                                              |
| values.schema.json                          | every CP chart                                                                                    | Fails on mistyped values at render time. CP generates it from `@param` comments                                                                                                             |

## Common-library helpers

Both libraries do the same job under different prefixes. Our `charts/common` is **Bitnami
2.13.3** (vendored, older than upstream 2.31.x). Charts vendored from CP declare `cloudpirates/common`
as an OCI dependency instead.

| Need                       | CloudPirates (`cloudpirates.*`)                                            | Bitnami (`common.*`)                                                                      |
|----------------------------|----------------------------------------------------------------------------|-------------------------------------------------------------------------------------------|
| Names                      | `cloudpirates.fullname`, `.name`, `.namespace`                             | `common.names.fullname`, `.name`, `.namespace`                                            |
| Labels                     | `cloudpirates.labels`, `.selectorLabels`                                   | `common.labels.standard`, `.matchLabels`                                                  |
| Image ref                  | `cloudpirates.image`, `.imagePullPolicy`, `.imagePullSecrets`              | `common.images.image`, `.pullSecrets`                                                     |
| Render a value as template | `cloudpirates.tplvalues.render`, `.merge`                                  | `common.tplvalues.render`, `.merge`                                                       |
| Security contexts          | `cloudpirates.renderPodSecurityContext`, `.renderContainerSecurityContext` | `common.compatibility.renderSecurityContext`                                              |
| Affinity presets           | `cloudpirates.affinities.{nodes,pods}.{soft,hard}`                         | `common.affinities.{nodes,pods}.{soft,hard}`                                              |
| Secret lookup              | `cloudpirates.secrets.lookup` ⚠️                                           | `common.secrets.passwords.manage`, `.lookup`, `.exists` ⚠️                                |
| Resource presets           | —                                                                          | `common.resources.preset` (`nano`…`2xlarge`). Prefer explicit `resources`, per house rule |
| API version switches       | —                                                                          | `common.capabilities.*.apiVersion`. Unneeded on a single modern cluster                   |
| Required-value checks      | `cloudpirates.validateRequired`                                            | `common.validations.values.*`                                                             |

For a chart you write yourself, **use neither**. Plain `_helpers.tpl` from `helm create` (as in
`charts/x-hrm`) has no dependency to resolve in Argo, and it's what most charts here do.

## Values conventions both upstreams share

Keep these names when you vendor, so `values-dev.yaml` reads the same across charts:

- `image.{registry,repository,tag,digest,pullPolicy}`
- `auth.existingSecret` + `auth.secretKeys.*` (or `existingSecret` at the top level), naming which
  Secret keys hold what
- `persistence.{enabled,size,accessModes,storageClass,existingClaim}`. Our overlay **adds**
  `useLocalVolume`, `localPath` and `nodeAffinity`
- `resources`, `podSecurityContext`, `containerSecurityContext`, `{liveness,readiness,startup}Probe`
- `metrics.{enabled,serviceMonitor.enabled}`, `networkPolicy.enabled`, `pdb.enabled`
- `extraEnvVars`, `extraVolumes`, `extraVolumeMounts`, `extraObjects`/`extraDeploy`
- `commonLabels`, `commonAnnotations`, `nameOverride`, `fullnameOverride`

## Vendoring checklist

Done that way for `keycloak` (CP 0.13.2) and `timescaledb` (CP 0.8.0). `diff -r` against the
upstream directory shows exactly what changed:

1. `cp -r CP/<chart> charts/<chart>`. Keep `LICENSE`, `values.schema.json` and `tests/`. Drop
   `CHANGELOG.md`, `ci/` and `artifacthub-repo.yml` if you like
2. Record the upstream version you copied (comment in `values-dev.yaml`, or `Chart.yaml`
   annotations)
3. `helm dependency build`. `Chart.lock` and `charts/*.tgz` are gitignored, and Argo resolves
   the OCI `common` dependency itself
4. Add `templates/pv.yaml` (+ `pvc.yaml` if the chart uses `existingClaim` rather than
   `volumeClaimTemplates`), plus the `persistence.useLocalVolume` values
5. Add `templates/<chart>-sealedsecret.yaml`, then set `existingSecret` in `values-dev.yaml`
6. Write `values-dev.yaml` with **only** the overrides. Leave `values.yaml` as upstream, so the
   next upgrade is a clean copy
7. `helm lint` + `helm template`, as in SKILL.md Step 4

Upgrading later means copying the new upstream over a scratch copy, then re-applying only
`pv.yaml`, `pvc.yaml`, the sealed secret and `values-dev.yaml`. That only works if step 6 held.

## Bitnami images after August 2025

From 2025-08-28, `docker.io/bitnami/*` keeps only hardened images tagged `latest`, meant for
development. Every versioned tag moved to `docker.io/bitnamilegacy/*` and **receives no further
updates**. Eight charts are now Secure-Images-only (listed at the end of the index).

So a Bitnami chart deployed as-is either runs a frozen image or an unpinned `latest`. Neither is
acceptable here. Bitnami images also run their own entrypoint scripts (`/opt/bitnami/scripts/…`,
`*_PASSWORD` env vars, `/bitnami/<app>` data paths), so swapping in the official image is a port
of the chart, not a one-line override. That's why CloudPirates comes first in the decision table
in SKILL.md.

*Facts about the upstreams were read from the local clones (Bitnami @ 2025-10-03, CloudPirates @
2026-01-26). Re-check paths after pulling.*
