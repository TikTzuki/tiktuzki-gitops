# Argo CD SSO with Google

Replaces the Keycloak setup in `README.md` for Argo CD only. Apply **one** IdP, never both —
each fully replaces `oidc.config` in `argocd-cm`.

|                      | Keycloak (`argocd-cm-patch.yaml`)              | Google (`argocd-cm-google-patch.yaml`) |
|----------------------|------------------------------------------------|----------------------------------------|
| Issuer               | `https://keycloak.tiktuzki.com/realms/homelab` | `https://accounts.google.com`          |
| Authorizes on        | `groups` claim                                 | **`email` claim**                      |
| Who can authenticate | only realm `homelab` users                     | **any Google account on earth**        |
| Extra component      | Keycloak must be up                            | none                                   |

## The one thing that shapes everything

Google's own discovery document says:

```
scopes_supported: ["openid", "email", "profile"]
claims_supported: [aud, email, email_verified, exp, family_name, given_name, iat, iss, name, picture, sub]
```

**There is no `groups` claim.** Requesting one does not error — you just get a token without
it, every `g, <group>, role:x` line matches nothing, and RBAC appears broken rather than
misconfigured. Google Groups need Dex's google connector plus a service account with
domain-wide delegation; until then, authorization is per-email.

Consequence: `policy.default: ''` is load-bearing here in a way it was not with Keycloak.
Keycloak only issued tokens to realm members. Google authenticates anyone; the *only* thing
between a stranger's account and this cluster is that they match no policy line.

## 1. Create the Google OAuth client

[console.cloud.google.com](https://console.cloud.google.com) → *APIs & Services* →
*Credentials* → **Create Credentials → OAuth client ID**.

- Application type: **Web application**
- Authorised redirect URI — exactly this, no trailing slash:

  ```
  https://argocd.tiktuzki.com/auth/callback
  ```

  `/auth/callback` is for direct OIDC. It would be `/api/dex/callback` only if Dex were in
  the middle, which it is not here.

You may also need *OAuth consent screen* configured once. Set **User type: Internal** if
`newera.inc` is a Workspace domain — that restricts login to your domain at Google's end,
which is stronger than anything Argo can enforce. Choose **External** and any Google account
can reach the login step.

Keep the **Client ID** and **Client secret**.

## 2. Create the client secret

Two options. **Out-of-band is the current choice** — it decouples Argo CD SSO from the
sealed-secrets master key.

### 2a. Out-of-band (current)

```bash
./bootstraps/argocd/sso/create-oidc-secret.sh
```

Prompts with echo off, so the value never reaches shell history, a file, or a terminal
transcript. It applies the required label for you and refuses to finish if the label is
missing.

> ⚠️ **This Secret lives only in the cluster.**
> It is invisible to Git and is destroyed by a rebuild. After any rebuild you must re-run
> the script, which means the Google client secret has to be retrievable from your password
> manager. `infra/sealed-secrets/README.md` names exactly this class of credential as the
> fragile one — the choice is deliberate, but do not forget it exists.

### 2b. SealedSecret (once the master key is settled)

Seal it against the live controller:

```bash
kubectl create secret generic argocd-oidc-secret \
  --namespace devops \
  --from-literal=clientSecret='<GOOGLE_CLIENT_SECRET>' \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace sealed-secrets \
           --controller-name sealed-secrets-controller \
           --format yaml \
> bootstraps/argocd/sso/argocd-oidc-sealedsecret.yaml
```

> ⚠️ **The label is required, not decoration.**
> Argo resolves `$argocd-oidc-secret:clientSecret` only against Secrets labelled
> `app.kubernetes.io/part-of: argocd`, and it must sit in `spec.template.metadata.labels` so
> the controller stamps it onto the generated Secret. Without it the server logs a *missing
> key* error — misleading, because the whole object is unreadable. See the comments in
> `argocd-oidc-sealedsecret.yaml`.

Re-add the template block after re-sealing, then:

```bash
kubectl apply -f bootstraps/argocd/sso/argocd-oidc-sealedsecret.yaml
kubectl -n devops get secret argocd-oidc-secret     # exists = controller decrypted it
```

## 3. Apply the config

```bash
# put your Client ID in first
$EDITOR bootstraps/argocd/sso/argocd-cm-google-patch.yaml   # REPLACE_WITH_GOOGLE_CLIENT_ID

# PATCH, never apply — argocd-cm holds upstream resource.customizations defaults
kubectl patch cm argocd-cm -n devops --type merge \
  --patch-file bootstraps/argocd/sso/argocd-cm-google-patch.yaml

# this one is safe to apply; the file owns the whole ConfigMap
kubectl apply -f bootstraps/argocd/sso/argocd-rbac-cm-google.yaml

kubectl -n devops rollout restart deploy/argocd-server
```

## 4. Prove SSO works BEFORE disabling admin

```bash
open https://argocd.tiktuzki.com          # "LOG IN VIA GOOGLE"
```

After logging in, confirm you are actually admin — not merely authenticated:

```bash
argocd login argocd.tiktuzki.com --sso
argocd account get-user-info
#   Logged In: true
#   Username: long.tpt@newera.inc
#   Groups:                          <- empty is CORRECT for Google
```

Authenticated-but-no-permissions looks like a working login with an empty Applications list.
If that happens, the email in `policy.csv` does not match the claim. Decode the token:

```bash
kubectl -n devops logs deploy/argocd-server | grep -i "claim\|rbac" | tail
```

## 5. Only now, disable the local admin

Uncomment `admin.enabled: "false"` in `argocd-cm-google-patch.yaml`, then:

```bash
kubectl patch cm argocd-cm -n devops --type merge \
  --patch-file bootstraps/argocd/sso/argocd-cm-google-patch.yaml
kubectl -n devops rollout restart deploy/argocd-server
kubectl -n devops delete secret argocd-initial-admin-secret   # optional: remove the bootstrap password
```

> ⚠️ **Do not do this before step 4 passes.**
>
> Disabling admin with broken SSO removes every way into the UI. It is recoverable only from
> kubectl:
>
> ```bash
> kubectl patch cm argocd-cm -n devops --type json \
>   -p '[{"op":"remove","path":"/data/admin.enabled"}]'
> kubectl -n devops rollout restart deploy/argocd-server
> ```
>
> Which works because you hold a cluster-admin certificate — so keep that credential valid
> and backed up. It is now the only break-glass path into Argo CD.

## Notes

- **Upstream re-installs reset this.** `argocd-cm` is not managed by this repo; re-applying
  upstream's `install.yaml` wipes the patch and un-configures SSO. Re-run step 3 afterwards.
- **Cloudflare is orange-clouded on this host** (`argocd.tiktuzki.com` resolves to 104.21.x).
  Fine for OIDC — unlike NetBird's gRPC, this is ordinary HTTPS.
- Adding a teammate is one line in `policy.csv`: `g, someone@example.com, role:operator`.
