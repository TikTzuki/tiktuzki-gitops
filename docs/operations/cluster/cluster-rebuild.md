---
title: "Rebuilding node1 from scratch"
tags: [kubernetes]
sidebar_position: 3
---

# Rebuilding node1 from scratch

A run-it-yourself checklist to take a bare MicroK8s install to a running cluster. Order
matters: everything is recoverable except step 5.

:::info[Ingress is Traefik now, not nginx]
MicroK8s 1.35's `ingress` addon installs **Traefik v3.6** (chart 37.4.0), not
ingress-nginx. Anything in the older guides about `nginx-ingress-microk8s-controller`,
the `nginx-ingress-tcp-microk8s-conf` ConfigMap, or patching the controller into
`hostNetwork` mode no longer applies. This repo now targets Traefik.
:::

## Step 0 — Confirm what you're on

```bash
ls -l --time-style=long-iso /var/snap/microk8s/current/certs/ca.crt   # CA mtime = cluster birth
microk8s status                                                       # which addons are on
grep authorization-mode /var/snap/microk8s/current/args/kube-apiserver
kubectl get pods -A                                                   # what's actually running
```

A CA newer than your kubeconfig explains both `x509: certificate signed by unknown
authority` from `kubectl` and every committed SealedSecret failing to decrypt.

## Step 1 — Addons

```bash
microk8s enable dns hostpath-storage rbac ingress
```

:::danger[`rbac` changes who you are]
Without it the API server runs `--authorization-mode=AlwaysAllow` and **every**
authenticated client is a full admin — every Role and ClusterRoleBinding is inert. Apply
the binding in step 2 *before* enabling it, or you lock yourself out.
:::

## Step 2 — Your kubectl credential

Full procedure in *kubectl credentials for a personal account*. Short version, from the
repo root:

```bash
kubectl apply -f infra/rbac/cluster-admins.yaml     # bind the group FIRST
# then mint a cert with CN=<you>, O=tiktuzki-admins  (see the credentials guide)
kubectl auth whoami                                  # Groups must include tiktuzki-admins
```

The old kubeconfig is **dead**, not stale — a new CA cannot validate the old client cert.
Re-mint rather than editing the server address.

:::tip[You may not need sudo]
`ca.key` is `root:microk8s 0660`. Anyone in the `microk8s` group can read it and mint
themselves a `cluster-admin` certificate without sudo — which is convenient here, and
worth understanding as a security property: **group membership is effectively
cluster-admin.**
:::

## Step 3 — ArgoCD

:::danger[ArgoCD must come before any Application]
`kind: Application` is a CRD that ships **with** ArgoCD. Applying `apps/base/*.yaml` first
fails with:

```
no matches for kind "Application" in version "argoproj.io/v1alpha1"
ensure CRDs are installed first
```

ArgoCD itself needs no ingress to install — reach it by port-forward until Traefik is back.
:::

```bash
kubectl apply -f bootstraps/argocd/install.yaml       # namespace devops, SA, Service, Ingress
kubectl apply -n devops -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n devops rollout status deploy/argocd-server --timeout=300s
kubectl get crd applications.argoproj.io             # the CRD step 4 depends on
```

Admin password, and the UI before its Ingress exists:

```bash
kubectl -n devops get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n devops port-forward svc/argocd-server 8080:443
```

## Step 4 — Hand Traefik to ArgoCD

The addon owns its Helm values at
`/snap/microk8s/current/addons/core/addons/ingress/values.yaml` and rewrites them on every
`microk8s enable ingress`. TCP entryPoints are **static** config living in those values, so
the addon cannot be their long-term owner.

```bash
microk8s disable ingress                    # drop the addon's Helm release, if still present
kubectl apply -f apps/base/traefik.yaml     # ArgoCD installs the same chart with our values
kubectl -n devops get app traefik -w        # wait for Synced/Healthy
```

Between the disable and the sync there is no ingress at all. That only affects
`*.tiktuzki.com`; `kubectl` goes to `:16443` directly and is unaffected.

## Step 5 — Sealed Secrets

:::danger[The master key does not survive a rebuild]
The controller generates an RSA keypair on first start. A new cluster generates a **new**
one, and every `SealedSecret` in Git was encrypted for the old key. Without a backup of
that key the ciphertext is permanently undecryptable.
:::

**If you have `sealed-secrets-key.yaml`**, apply it *before the controller first starts* so
it adopts the key instead of generating one:

```bash
kubectl create namespace sealed-secrets
kubectl apply -f sealed-secrets-key.yaml
kubectl apply -f apps/base/sealed-secrets.yaml
```

**If you do not** — the current situation — install the controller first, then recreate
each secret from its source value and re-seal. There are 12 in this repo:

```bash
kubectl apply -f apps/base/sealed-secrets.yaml
kubectl -n sealed-secrets rollout status deploy/sealed-secrets-controller

grep -rl "kind: SealedSecret" . --exclude-dir=.git    # the list to work through

kubectl create secret generic <name> -n <ns> --from-literal=<key>='<value>' \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace sealed-secrets \
           --controller-name sealed-secrets-controller --format yaml \
> <path/to/sealedsecret.yaml>
```

Then back the new key up immediately — off node1, encrypted:

```bash
kubectl -n sealed-secrets get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key.yaml
```

A backup on the disk you are protecting against is not a backup.

## Step 6 — Everything else

:::warning[`apps/base/` is not an app-of-apps]
Nothing syncs that directory automatically — each Application is applied by hand, and a
missed one fails silently as a service that simply never appears.
:::

```bash
for f in apps/base/*.yaml; do kubectl apply -f "$f"; done
kubectl apply -f clusters/dev/apps.yaml
kubectl get applications -n devops        # all Synced/Healthy
```

## Step 7 — Verify

:::danger[Never test ingress with `ss`]
Traefik binds `:80`, `:443` and every database port with **`hostPort`**, which the CNI
implements as iptables DNAT — **not** a listening socket. `ss -ltn` shows nothing on those
ports even when they work perfectly. Use `curl` or `nc`.
:::

```bash
# HTTP, locally and over the overlay — 404 from Traefik means reachable
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.5/
curl -s -o /dev/null -w '%{http_code}\n' http://100.66.50.60/

# TCP passthrough: both halves must exist
kubectl -n ingress get ds traefik -o json \
  | jq -r '.spec.template.spec.containers[].ports[] | "\(.name) hostPort=\(.hostPort // "none")"'
kubectl get ingressroutetcp -A

nc -z 100.66.50.60 5432 && echo "postgres reachable over overlay"

# end to end through NPM
curl -I https://argocd.tiktuzki.com
```

An entryPoint with no `IngressRouteTCP` accepts the connection and immediately closes it;
a route naming an entryPoint that doesn't exist is silently ignored. Check both.

## What a rebuild costs

| Artifact                         | Survives?           | Recovery                                       |
|----------------------------------|---------------------|------------------------------------------------|
| Sealed-Secrets master key        | **No**              | Restore from backup, or re-seal all 12 by hand |
| Cluster CA / all kubeconfigs     | No                  | Re-mint per person (step 2)                    |
| PVs and their data               | No — local hostPath | Restore from `infra/backup/`                   |
| Charts, Applications, ConfigMaps | Yes — in Git        | `kubectl apply`                                |
| Secrets never sealed             | **No**              | Recreate from source; never were in Git        |

The first, third and last rows are why PLAN.md step 5 — scheduled **off-node** backups —
outranks everything else on that list.

That is now in place: see **[Backing up the cluster](../backup-restore/backup-flow)**. A rebuild only costs
what the last successful backup did not capture, so the row above that reads "Restore from
backup" is only true for as long as `pull-backup.sh` keeps being run and its output keeps
leaving both machines.
