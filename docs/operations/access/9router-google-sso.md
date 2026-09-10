---
title: "9Router SSO with Google"
tags: [ security, kubernetes ]
sidebar_position: 4
---

# 9Router SSO with Google

Replaces 9Router's local password with Google OIDC, the same issuer Argo CD uses. Read the
next section before doing anything else — the safety argument here is **not** the same as
Argo CD's.

## The one thing that shapes everything

Argo CD's Google SSO is safe because authentication and authorization are separate. A
stranger's Gmail account can complete the OIDC flow and still be useless, because
`argocd-rbac-cm-google.yaml` sets:

```yaml
policy.default: ''
```

**9Router has no equivalent.** There is no RBAC, no role, no admin list, and no allowlist.
Its OIDC callback reads `oidcEmail`, `oidcName` and `oidcSub` from the token and signs a
session — with no comparison against anything. Verified against `decolua/9router:0.5.69`:
the configurable OIDC fields are exactly `oidcIssuerUrl`, `oidcClientId`,
`oidcClientSecret`, `oidcScopes`, `oidcLoginLabel`. No `allowedDomains`, no
`emailWhitelist`, no `hostedDomain`.

So for 9Router, **authentication is administration**. Whoever the IdP admits gets the
dashboard, and the dashboard holds every provider API key you have entered.

:::danger[The consent screen is the only gate]
Because 9Router cannot restrict who logs in, the restriction has to happen at Google. The
OAuth client's consent screen **must** be `User type: Internal`, which limits login to
`newera.inc` Workspace accounts.

Set it to **External** — or move the client to a project without the Workspace attached —
and every Google account on earth can sign in as gateway admin. There is no second line of
defence. This is a stricter requirement than Argo CD's, where `policy.default: ''` would
still catch a stranger.
:::

If you would rather have a gate inside the cluster, point `oidcIssuerUrl` at
`https://keycloak.tiktuzki.com/realms/homelab` instead and federate Google into Keycloak as
an identity provider. Realm membership then becomes the allowlist, and the rest of this
runbook applies unchanged apart from the issuer URL. See
[Keycloak SSO](keycloak-sso).

## What cannot be done from Git

9Router's OIDC settings live in its own database under `/app/data`, entered through the
dashboard. It reads **no** OIDC environment variables, so the Helm chart cannot configure
this — `charts/9router` only sets `AUTH_COOKIE_SECURE`. Everything below is a one-time
manual setup, and it is lost if the data volume is lost.

## 1. Create the Google OAuth client

[console.cloud.google.com](https://console.cloud.google.com) → *APIs & Services* →
*Credentials* → **Create Credentials → OAuth client ID**.

- Application type: **Web application**
- **OAuth consent screen → User type: Internal** (see the danger note above — this is the
  whole security model)
- Authorised redirect URI — exactly this, no trailing slash:

  ```
  https://9router.tiktuzki.com/api/auth/oidc/callback
  ```

  Note the path: `/api/auth/oidc/callback`, not `/auth/callback` (Argo CD) and not
  `/login/oauth2/code/...` (Spring). 9Router builds this URI from the `X-Forwarded-Host` and
  `X-Forwarded-Proto` headers it receives, so it must match what the browser sees through
  Nginx Proxy Manager.

Keep the **Client ID** and **Client secret**.

## 2. Configure 9Router

Reach the dashboard and sign in with the local password first — you need an authenticated
session to change auth settings, and locking yourself out is the failure mode here.

```bash
kubectl -n demo port-forward svc/nine-router 20128:20128
```

In *Settings → Authentication*:

| Field | Value |
|---|---|
| Auth mode | OIDC |
| Issuer URL | `https://accounts.google.com` |
| Client ID | from step 1 |
| Client secret | from step 1 |
| Scopes | `openid email profile` |
| Login label | `Sign in with Google` |

Google's discovery document advertises only `openid`, `email` and `profile` — there is **no
`groups` claim**. Requesting one does not error; you simply get a token without it. Since
9Router does not read groups anyway, this costs nothing here, but it is the same trap
documented for [Argo CD](argocd-google-sso).

Use the **Test** button (`/api/auth/oidc/test`) before saving. It validates the issuer and
client credentials without changing your session, which is the difference between a typo and
an hour of recovery.

## 3. Keep the local password working

Do not delete the password after enabling OIDC. It is the way back in when Google is
unreachable, the client secret is rotated, or the consent screen is misconfigured. 9Router
supports both simultaneously; the login page offers whichever are configured.

If you do lock yourself out, the reset path is a CLI action against the data volume, per the
message the login endpoint returns after five failed attempts:

```
Too many failed attempts. Try again in 30s. Forgot password? Reset to default via 9Router CLI → Settings
```

## 4. Verify

```bash
# unauthenticated status endpoint reports what is configured
curl -s https://9router.tiktuzki.com/api/auth/status | jq
```

Expect `"oidcConfigured": true` and `"authMode"` reflecting your choice. Then, in a private
window, confirm two things:

1. A `newera.inc` account signs in.
2. A personal Gmail account is **rejected by Google**, before it ever reaches 9Router. If it
   reaches 9Router and gets a session, the consent screen is not Internal — fix that before
   leaving the ingress enabled.

## Cookies behind the proxy

`AUTH_COOKIE_SECURE=true` is set by the chart in `values-dev.yaml`. 9Router marks its session
cookie `Secure` when either that variable is `true` or the request carries
`X-Forwarded-Proto: https`. TLS terminates at Nginx Proxy Manager on the public VPS, so the
pod sees plain HTTP; setting the variable explicitly means the cookie does not silently lose
its `Secure` flag if a proxy hop drops the header.

## What a cluster rebuild costs

This configuration is in the data volume, not in Git. After a rebuild that restores
`9router-data`, OIDC keeps working. After one that does not, you are back to step 2 with a
fresh unclaimed instance — see the first-run note in
[the chart README](https://github.com/TikTzuki/tiktuzki-gitops/blob/main/charts/9router/README.md).
The Google client and its secret survive either way, so keep the secret in your password
manager.
