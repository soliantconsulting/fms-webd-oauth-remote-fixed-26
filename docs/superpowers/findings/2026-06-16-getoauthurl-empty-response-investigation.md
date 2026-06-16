# Investigation: `getoauthurl` returns `{}` for the remote scenario (FMS 26.0.1)

**Date:** 2026-06-16
**Status:** Open — paused pending Claris guidance/docs
**Server:** FileMaker Server **26.0.1** (build 68, 2026-04-30), host `mbp2013.ets.fm`
**Symptom:** Clicking **Member Login** on the remote demo (`wim.ets.fm`) navigates the browser
to `https://wim.ets.fm/%7B%7D` → nginx 404.

## TL;DR

The repo's premise is that FMS 26.0.1's *"custom OAuth return URL may point to an external
website"* lets a **static** site on `webDNS` host the OAuth round-trip. Black-box testing of
this exact server shows a hard coupling that a purely static remote site cannot satisfy:

1. **`X-FMS-Return-URL` host must equal the `address` query parameter** of `getoauthurl`.
2. **`address` also sets the OAuth `redirect_uri`** = `https://{address}/oauth/redirect`,
   which is where the **IdP POSTs the authorization code**.
3. **`/oauth/redirect` is an FMS-only application endpoint** (token exchange — needs the
   client secret + PKCE `code_verifier`; a static server cannot perform it).

Chained: to keep the code-exchange on FMS, `address` must be `fmsDNS` → then the return URL
must also be `fmsDNS` → the browser cannot be returned cross-origin to `webDNS`. Setting
`address=webDNS` to allow the external return forces the IdP to POST the code to
`https://webDNS/oauth/redirect` — the static nginx container, which has no exchange handler.

We could not find any channel (with `address=fmsDNS` fixed) to supply an external return URL.
**Paused for Claris** rather than guess further or change repo code.

## How the symptom is produced (client side, confirmed)

- [`assets/js/oauth-utility-edit.js`](../../../assets/js/oauth-utility-edit.js) `getOAuthURL`
  sends `address=fmsDNS` and `X-FMS-Return-URL` on `webDNS`.
- FMS returns **HTTP 200, body `{}`** (content-length 2), and **no `X-FMS-Request-ID`**.
- `getOAuthURL` passes `oauthUrl = "{}"` (truthy), the `if (!oauthUrl)` guard in
  [`assets/js/oauth-flow.js`](../../../assets/js/oauth-flow.js) does not fire, and full-page
  mode runs `window.location.replace("{}")` → browser resolves `{}` as a relative path →
  `https://wim.ets.fm/%7B%7D` → 404.

## Evidence (controlled black-box tests against `mbp2013.ets.fm`)

All requests: `GET /fmi/webd/oauthapi/getoauthurl`, headers
`X-FMS-Application-Type: 8`, `X-FMS-Application-Version: 17`, an authenticated WebDirect
session cookie, provider `Microsoft`, `X-FMS-OAuth-AuthType=2`. "OK" = real
`https://login.microsoftonline.com/...` URL (~553–561 bytes); "`{}`" = empty 2-byte body.

### A. The return-URL host must match the `address` param

| `address=` | `X-FMS-Return-URL` host | Result |
|---|---|---|
| `mbp2013.ets.fm` | `mbp2013.ets.fm` | OK |
| `mbp2013.ets.fm` | `wim.ets.fm` | `{}` |
| `wim.ets.fm` | `wim.ets.fm` | **OK** |
| `wim.ets.fm` | `mbp2013.ets.fm` | `{}` |

The third row is the key: a non-FMS host works **as long as `address` matches it**. So the
gate is `return-URL host == address`, not "must be the FMS host".

### B. Ruled out (each disproved by test, not assumption)

- **Not DNS resolvability.** Adding `wim.ets.fm` to the FMS box's `/etc/hosts` did not change
  the result. Also `https://www.google.com/` and `https://example.com/` (fully resolvable,
  reachable) returned `{}` when `address=fmsDNS`.
- **Not reachability/validation of the return host.** Same google/example.com test.
- **Not nginx CORS.** Varying the `Origin` request header (absent / `wim` / `mbp2013`) had no
  effect; the FMS-host return URL works regardless of `Origin`. The `{}` body comes from the
  FMS web engine (jwpc), not nginx (nginx errors are HTML).
- **Not an `fmsadmin` setting.** `fmsadmin get serverconfig|cwpconfig` exposes no OAuth /
  return-URL / allowed-host configuration.
- **Not a per-host allowlist.** Consistent with the maintainer's point that an arbitrary
  return URL is the whole purpose; row 3 of table A confirms non-FMS hosts are accepted when
  `address` matches.

### C. `address` sets the OAuth `redirect_uri`

`getoauthurl` with `address=wim.ets.fm` returned a Microsoft URL containing
`redirect_uri=https://wim.ets.fm/oauth/redirect`, and the decoded `state` contained
`X-FMS-Redirect-URL=https://wim.ets.fm/oauth/redirect`. With `address=mbp2013.ets.fm` the
`redirect_uri` is `https://mbp2013.ets.fm/oauth/redirect`. So `address` controls where the
IdP sends the authorization code.

### D. `/oauth/redirect` is an FMS application endpoint

On `mbp2013.ets.fm`:

| Request | Status | Note |
|---|---|---|
| `GET /oauth/redirect` | 200 | header `x-fms-result: 25024` |
| `GET /oauth/redirect?code=x&state=y` | 200 | header `x-fms-result: 25025` (parses params) |
| `GET /oauth/bogus` | 400 | not a handled route |

The `x-fms-result` codes show FMS itself handles `/oauth/redirect` — it is the server-side
OAuth callback that exchanges the code (using the confidential client secret + PKCE verifier).
A static web server on `webDNS` cannot implement this.

### E. With `address=fmsDNS` fixed, no external-return channel found

| Attempt (`address=fmsDNS`) | Result |
|---|---|
| `X-FMS-Return-URL` = FMS host (control) | OK |
| `X-FMS-Return-URL` = `wim` (documented header) | `{}` |
| `&homeurl=https://wim...` query param (+ return-url=FMS) | OK, but return stays FMS (homeurl is the post-login WebDirect home, unrelated) |
| `X-FMS-Home-URL: wim` header (+ return-url=FMS) | OK, header ignored, return stays FMS |
| invented `X-FMS-External-Return-URL: wim` header | `{}` |

## Reference: the launch center (`home.js`) is same-origin

The 26.0.1 launch center
(`/opt/FileMaker/FileMaker Server/Web Publishing/publishing-engine/jwpc-tomcat/fmi/VAADIN/launchcenter/home.js`)
issues a request **structurally identical** to this repo's: same endpoint, same headers,
a `guid()` tracking ID, the `storage`-event popup flow, `oauth-landing.html`. Crucially, in
`openOAuthWindow()` its `address` (`master_addr`, defaulting to `window.location.hostname`)
**and** its `X-FMS-Return-URL` (`window.location.origin + "/fmi/webd/oauth-landing.html"`)
are **the same host**, because the launch center runs *on* FMS. It therefore never exercises
a cross-origin return and cannot reveal the intended remote mechanism.

## The contradiction (why this is paused, not patched)

FMS 26.0.1 release notes: *"Custom OAuth authentication now supports specifying a return URL
that points to an external website rather than FileMaker Server."* That capability is real
(the feature shipped; this server does PKCE, also new in 26.0.1). But on this server the
only way to make the return URL external (`address=webDNS`) also moves `redirect_uri`
(the IdP code-exchange) to `webDNS/oauth/redirect`, which only FMS can service. The two
requirements appear mutually exclusive for a **static** remote site.

Unresolved — needs Claris docs or a working remote example:

1. In the intended remote flow, what is `address` set to, and **how is the external return
   URL supplied** so that `redirect_uri` stays on FMS?
2. Does the external-return feature expect the browser to be returned to `webDNS` **after**
   FMS completes the exchange (i.e. a separate "final redirect" distinct from `redirect_uri`),
   and if so via which parameter/header?
3. Or does the remote scenario still require a server-side relay at `webDNS/oauth/redirect`
   (which would reopen this repo's "no companion on a server" premise — cf. the older-FMS
   `fms-webd-oauth-remote-companion`)?

## Not changed

No application code was modified during this investigation. The known client-side
robustness bug (the `if (!oauthUrl)` guard treats the string `"{}"` as valid and redirects
to it) is **not yet fixed** — it should be hardened regardless of the FMS-side resolution,
but is deferred with the rest pending the Claris answer so the fix matches the final flow.

## Housekeeping

Investigation reused a live WebDirect session cookie and admin context from the FMS box;
those credentials (and the FMS license key shared in passing) should be rotated/expired.
