# Keycloak SSO + authorization — Argo CD and kafka-ui

Both authenticate against realm `homelab` on `https://keycloak.tiktuzki.com` and authorize from
the **`groups`** claim.

## Why groups here, when Grafana uses client roles

Grafana reads `resource_access.grafana.roles` — client roles, scoped to one client. That is the
tighter model: "admin in Grafana" cannot be granted sideways by a realm-wide role.

Argo CD and kafka-ui both match on a flat claim (`groups`), so client roles would mean a
per-client mapper rewriting roles into `groups` for each app. One realm group set, mapped once,
is less machinery for the same result.

The cost is honest: **a group is realm-wide**. `kafka-admins` means the same thing everywhere,
so a group added for one app is visible to every client that requests the `groups` scope. Keep
group names app-prefixed (`argocd-*`, `kafka-*`) so a future app cannot accidentally inherit
authority meant for this one.

## 1. Realm groups

Create these under Groups in realm `homelab`:

| Group | Grants |
|---|---|
| `argocd-admins` | Argo CD `role:admin` — full control incl. deleting Applications |
| `argocd-operators` | sync + view + logs, **no** mutation of repos/clusters/Applications |
| `argocd-viewers` | Argo CD `role:readonly` |
| `kafka-admins` | kafka-ui full control of `kafka-dev` |
| `kafka-viewers` | kafka-ui read-only (incl. reading message payloads — see below) |

Then Users → *your user* → Groups → Join.

### ⚠️ The leading-slash trap

Keycloak's group mapper emits the **full path** by default, so `kafka-admins` arrives in the
token as `/kafka-admins`. Every policy that matches the bare name then silently matches nothing,
and RBAC looks broken rather than misconfigured.

Both configs here tolerate either form — Argo CD lists both spellings, kafka-ui matches
`/?name` as a regex. Confirm which you actually get, then tighten:

```bash
# after logging in, decode the access token
<jwt> | cut -d. -f2 | base64 -d 2>/dev/null | jq '.groups'
```

To emit bare names instead, set **Full group path → Off** on the groups mapper.

## 2. The `groups` client scope

`groups` is not in a default Keycloak client scope. Create it once and attach it to both
clients, or neither app will ever see a group:

1. Client scopes → **Create client scope** → name `groups`, Type **Default**, Protocol
   `openid-connect`, **Include in token scope → On**
2. Inside it → Mappers → **Configure a new mapper** → **Group Membership**
   - Token Claim Name: `groups`
   - Full group path: **Off** (see the trap above)
   - Add to ID token: **On** · Add to access token: **On** · Add to userinfo: **On**
3. Attach it: Clients → `argocd` → Client scopes → Add client scope → `groups` (Default).
   Repeat for `kafka-ui`.

All three "Add to …" toggles matter: Argo CD reads the ID token, kafka-ui reads the access
token, and userinfo is the fallback both use.

## 3. Clients

| | `argocd` | `kafka-ui` |
|---|---|---|
| Client authentication | On (confidential) | On (confidential) |
| Standard flow | On | On |
| Valid redirect URIs | `https://argocd.tiktuzki.com/auth/callback`<br>`http://localhost:8085/auth/callback` | `https://kafka-ui.tiktuzki.com/login/oauth2/code/keycloak` |
| Web origins | `https://argocd.tiktuzki.com` | `https://kafka-ui.tiktuzki.com` |

The second Argo CD URI is for `argocd login --sso` from the CLI — omit it and the CLI hangs on
a callback that never resolves.

kafka-ui's callback path ends in the **provider name** (`keycloak`), not the client id. Change
`kafkaUi.auth.oauth2.provider` and this URI must change with it.

Note this is **direct OIDC, not Dex**. Argo CD bundles Dex as an optional broker; going straight
to Keycloak removes a hop. It also fixes the callback path — `/auth/callback` here, where a Dex
setup would use `/api/dex/callback`.

## 4. Secrets

**Argo CD** — a new Secret, not a patch to `argocd-secret`:

```bash
kubectl create secret generic argocd-oidc-secret \
  --namespace devops \
  --from-literal=clientSecret='<argocd client secret>' \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace sealed-secrets \
           --controller-name sealed-secrets-controller --format yaml \
> bootstraps/argocd/sso/argocd-oidc-sealedsecret.yaml
```

⚠️ It **must** carry `app.kubernetes.io/part-of: argocd` or the `$argocd-oidc-secret:clientSecret`
reference in `argocd-cm` will not resolve — Argo only reads labelled secrets. Add to the
generated file before sealing, or re-seal from a manifest that includes it.

**kafka-ui** — re-seal the *existing* `kafka-ui-oauth` Secret, which still holds the old Google
client secret:

```bash
kubectl create secret generic kafka-ui-oauth \
  --namespace database \
  --from-literal=client-secret='<kafka-ui client secret>' \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace sealed-secrets \
           --controller-name sealed-secrets-controller --format yaml \
> charts/kafka/templates/ui-oauth-sealedsecret.yaml
```

## 5. Apply

```bash
# Argo CD — PATCH, never apply: argocd-cm holds upstream resource.customizations defaults
# that a full apply would strip.
kubectl patch cm argocd-cm -n devops --type merge \
  --patch-file bootstraps/argocd/sso/argocd-cm-patch.yaml
kubectl apply -f bootstraps/argocd/sso/argocd-rbac-cm.yaml
kubectl apply -f bootstraps/argocd/sso/argocd-oidc-sealedsecret.yaml
kubectl rollout restart deploy/argocd-server -n devops

# kafka-ui — via its Argo app
git add charts/kafka && git commit -m "feat(kafka-ui): keycloak sso + rbac" && git push
```

`argocd-cm` is not managed by this repo — `bootstraps/argocd/install.yaml` holds only a
Namespace, ServiceAccount, Service and Ingress. Argo CD came from upstream's install manifest,
so **re-applying that upstream manifest resets this ConfigMap and un-configures SSO.** Re-run
the patch afterwards.

## Both are deny-by-default

Consistent with the choice already made for Grafana (`role_attribute_strict: true`):

- Argo CD `policy.default: ''` — an authenticated user in no mapped group gets nothing
- kafka-ui: once `rbac.enabled`, a user matching no role sees an empty UI

Which means a wrong group name locks **you** out too. Break-glass for each:

| | Break-glass |
|---|---|
| Argo CD | local `admin` account (`argocd-secret` → `admin.password`), kept at `role:admin` in `policy.csv` |
| kafka-ui | none — set `rbac.enabled: false` and re-sync to recover |

kafka-ui has no local account, so verify the groups claim **before** relying on it.

## One judgement call to review

`kafka-viewers` includes `messages_read` on all topics. Topic payloads can contain PII, so
"viewer" is not automatically a safe tier to hand out. Drop that action in
`charts/kafka/values-dev.yaml` to make the role metadata-only.
