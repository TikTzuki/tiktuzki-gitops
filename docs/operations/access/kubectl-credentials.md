---
title: "kubectl credentials per person"
tags: [kubernetes, security]
sidebar_position: 1
---

# Personal kubectl credentials for the MicroK8s cluster

MicroK8s ships one credential — the `admin` cert in `microk8s config`, subject
`CN=admin, O=system:masters`. Copy it to every laptop and they all share one identity:
audit logs can't tell them apart, and you can't cut off one machine without cutting off
all of them.

This mints a **named X.509 user** signed by the cluster CA, so `kubectl auth whoami`
reports `tiktuzki` in group `tiktuzki-admins`.

**Prerequisites:** `kubectl` on the client; the client is a NetBird peer that can reach
node1; `sudo` on node1 (the CA private key is root-only).

:::danger[First check that RBAC is even enforced]

```bash
grep authorization-mode /var/snap/microk8s/current/args/kube-apiserver
```

A fresh MicroK8s runs `--authorization-mode=AlwaysAllow`: **every** authenticated client is
a full admin and the binding below does nothing. The named identity still shows up in audit
logs, but it buys no restriction until you run `microk8s enable rbac`. Apply the binding
*before* enabling the addon, or you lock yourself out.
:::

## Step 1 — Check reachability and the API SANs

The API server on `:16443` is host-terminated, so unlike a NodePort it *is* reachable over
the overlay (gotcha #2 in the publish guide). The address you put in the kubeconfig must
appear in the API cert's SAN list, or TLS fails.

```bash
nc -z -G3 100.66.50.60 16443 && echo "overlay OK"
echo | openssl s_client -connect 100.66.50.60:16443 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName     # expect both 192.168.1.5 and 100.66.50.60
```

If an address is missing, add it to `csr.conf.template` and run
`sudo microk8s refresh-certs --cert server.crt`.

:::warning[Never regenerate the CA to fix this]
`refresh-certs --cert ca.crt` breaks **every** kubeconfig, including the one you're about
to mint. Only `server.crt` is safe.
:::

## Step 2 — Mint the credential on node1

```bash title="mint-kubeconfig.sh — run with sudo on node1"
#!/bin/bash
set -euo pipefail

USER_CN=tiktuzki
USER_ORG=tiktuzki-admins
DAYS=90
CERTS=/var/snap/microk8s/current/certs
OUT=/tmp/kc-${USER_CN}.yaml
OVERLAY_IP=100.66.50.60
LAN_IP=192.168.1.5
OWNER=tik

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

openssl genrsa -out "$WORK/u.key" 2048 2>/dev/null
openssl req -new -key "$WORK/u.key" -out "$WORK/u.csr" -subj "/CN=$USER_CN/O=$USER_ORG"
openssl x509 -req -in "$WORK/u.csr" \
  -CA "$CERTS/ca.crt" -CAkey "$CERTS/ca.key" -CAcreateserial \
  -out "$WORK/u.crt" -days "$DAYS" -sha256 2>/dev/null

microk8s kubectl create clusterrolebinding "$USER_ORG" \
  --clusterrole=cluster-admin --group="$USER_ORG" \
  --dry-run=client -o yaml | microk8s kubectl apply -f -

CA_B64=$(base64 -w0 < "$CERTS/ca.crt")
CRT_B64=$(base64 -w0 < "$WORK/u.crt")
KEY_B64=$(base64 -w0 < "$WORK/u.key")

cat > "$OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: microk8s-overlay
  cluster: {server: "https://${OVERLAY_IP}:16443", certificate-authority-data: ${CA_B64}}
- name: microk8s-lan
  cluster: {server: "https://${LAN_IP}:16443", certificate-authority-data: ${CA_B64}}
users:
- name: ${USER_CN}
  user: {client-certificate-data: ${CRT_B64}, client-key-data: ${KEY_B64}}
contexts:
- name: microk8s
  context: {cluster: microk8s-overlay, user: ${USER_CN}}
- name: microk8s-lan
  context: {cluster: microk8s-lan, user: ${USER_CN}}
current-context: microk8s
EOF

chown "$OWNER:$OWNER" "$OUT"; chmod 600 "$OUT"
openssl x509 -in "$WORK/u.crt" -noout -subject -issuer -dates
echo "==> OK: $OUT"
```

Kubernetes reads `CN` as the username and each `O` as a group — there's no User object to
create. The binding targets the **group**, so another engineer just needs a cert with
`O=tiktuzki-admins` and no new RBAC.

The binding is committed as [`infra/rbac/cluster-admins.yaml`](https://github.com/TikTzuki/tiktuzki-gitops/blob/main/infra/rbac/cluster-admins.yaml) and synced
by the `rbac` Argo app, so Git is its source of truth. The script's imperative
`create clusterrolebinding` exists only for the bootstrap case — you need kubectl access
*before* ArgoCD is running to install ArgoCD. Once it syncs, Argo adopts the same object.

:::note[Don't verify with `microk8s kubectl`]
The wrapper pins its own admin kubeconfig and ignores `KUBECONFIG`, so testing on node1
gives a false pass. Verify from the client.
:::

## Step 3 — Fetch it to the client

Generate the key on node1 and move the finished file; never paste a private key through a
chat window.

```bash
ssh tik@192.168.1.5 'cat > /tmp/mint.sh' < mint-kubeconfig.sh
ssh -t tik@192.168.1.5 'sudo bash /tmp/mint.sh; rm -f /tmp/mint.sh'   # -t so sudo can prompt
scp tik@192.168.1.5:/tmp/kc-tiktuzki.yaml ~/.kube/microk8s-tiktuzki.conf
ssh tik@192.168.1.5 'rm -f /tmp/kc-tiktuzki.yaml'
chmod 600 ~/.kube/microk8s-tiktuzki.conf
```

## Step 4 — Merge into `~/.kube/config`

:::danger[On a merge, the first file wins]
Any duplicated cluster / user / context name keeps the **earlier** entry. A stale
`microk8s` context will shadow the new one, and you'll get timeouts while believing the
new credential is active.
:::

```bash
cp ~/.kube/config ~/.kube/config.bak.$(date +%Y%m%d-%H%M%S)

kubectl config delete-context microk8s         2>/dev/null || true
kubectl config delete-cluster microk8s-cluster 2>/dev/null || true
kubectl config unset users.admin               2>/dev/null || true

KUBECONFIG=~/.kube/microk8s-tiktuzki.conf:~/.kube/config \
  kubectl config view --flatten > /tmp/merged-config
mv /tmp/merged-config ~/.kube/config
chmod 600 ~/.kube/config
```

Or skip the merge entirely: `export KUBECONFIG=~/.kube/microk8s-tiktuzki.conf`.

## Step 5 — Verify

Check *which identity the server sees* — `get nodes` would also succeed with a stale admin
entry.

```bash
kubectl auth whoami        # Username tiktuzki / Groups [tiktuzki-admins system:authenticated]
kubectl get nodes -o wide
kubectl config use-context microk8s-lan && kubectl get nodes    # LAN path
```

Check expiry any time:

```bash
kubectl config view --raw -o jsonpath='{.users[?(@.name=="tiktuzki")].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -subject -dates
```

## Rotation and revocation

:::danger[X.509 client certs cannot be revoked]
Kubernetes has no CRL and no OCSP — a leaked cert is valid until `notAfter`. The only real
revocations are rotating the cluster CA (invalidates everything) or deleting the RBAC
binding.
:::

Keep `DAYS` short (90 is a good default), and give each machine its own `CN`
(`tiktuzki-macbook`, `tiktuzki-desktop`) so an incident's blast radius isn't every device.
Rotating is just Step 2 again. Dropping a whole group is
`kubectl delete clusterrolebinding tiktuzki-admins`.

**If you need real revocation, use a ServiceAccount token** — deleting the SA instantly
invalidates every token it issued, at the cost of a non-human identity:

```bash
microk8s kubectl -n kube-system create serviceaccount tiktuzki
microk8s kubectl create clusterrolebinding tiktuzki-admin \
  --clusterrole=cluster-admin --serviceaccount=kube-system:tiktuzki
microk8s kubectl -n kube-system create token tiktuzki --duration=24h
```

## Troubleshooting

| Symptom                                         | Cause / fix                                                                                                                      |
|-------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------|
| `context deadline exceeded`                     | Stale server address — a peer's NetBird IP changes if it re-registers. Check `netbird status` on node1.                          |
| `x509: certificate signed by unknown authority` | Your `certificate-authority-data` isn't the cluster's current CA. Re-mint; the old kubeconfig is dead.                           |
| `doesn't contain any IP SANs`                   | Connect address missing from the API cert. See Step 1.                                                                           |
| `Unauthorized`                                  | Cert expired or signed by a different CA. Check `notAfter`.                                                                      |
| Every identity is admin, binding ignored        | `--authorization-mode=AlwaysAllow` — run `microk8s enable rbac`.                                                                 |
| Authenticated but everything `Forbidden`        | No RBAC matches. The `O=` in the subject must equal the group in the binding — a typo authenticates fine and authorizes nothing. |
| `auth whoami` still shows `admin`               | The merge kept a shadowing entry. See Step 4.                                                                                    |
| Works on LAN, times out on overlay              | NetBird Access Control doesn't permit the client peer → node1 on `16443`.                                                        |
