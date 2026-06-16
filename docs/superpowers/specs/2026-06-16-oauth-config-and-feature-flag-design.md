# Port config separation + full-page-redirect feature flag into the remote repo

**Date:** 2026-06-16
**Status:** Approved (design)

## Background

This repo demonstrates starting the FileMaker **WebDirect** OAuth login flow from a web
site that is hosted on a **separate web server** — *not* on FileMaker Server (FMS). It is
the "remote" counterpart to the sibling repo
[fms-webd-oauth-local](https://github.com/wimdecorte/fms-webd-oauth-local), which covers the
case where the static files are served by FMS itself.

The sibling repo recently (last ~3 weeks) gained two things we want here:

1. **Configuration separated out** of the HTML into a single JS config object
   (`OAUTH_CONFIG`), and inline `<script>` logic pulled into dedicated JS files.
2. A **`useFullPageRedirect` feature flag** that switches the IdP login between a **popup**
   window and a **single-page (full-tab) redirect**.

The point of revisiting this *now* is that **Claris fixed the `X-FMS-Return-URL` behavior**:
FMS will now return the OAuth result to an arbitrary **cross-origin** URL on your own web
server. Previously the return page had to live on the FMS box, which broke the popup flow in
the remote scenario (the `storage` event only fires same-origin, so the parent page never
heard the result and login silently stalled).

## The core distinction this repo must preserve

The sibling repo is served *by* FMS, so it uses **relative URLs** (`/fmi/webd/...`) and
treats `window.location.hostname` as the FMS host. In our remote scenario the web server and
the FileMaker Server are **two different boxes**, so everything reduces to two configured
hostnames:

- **`fmsDNS`** — the FileMaker Server box. Target of all API calls (`oauthproviderinfo`,
  `getoauthurl`), the `address=` query parameter, and the final login form POST.
- **`webDNS`** — the web server box hosting these static files. Used for `X-FMS-Return-URL`
  (popup mode) and the post-login `homeUrl`.

> Naming note: the current `index.html` calls the web-server host `thisDNS`. We rename it to
> `webDNS` so it reads as a clear parallel to `fmsDNS` (FMS box vs web box) instead of the
> ambiguous "this". Since the config object is introduced fresh, there is no migration cost.

## File structure

Mirrors the sibling, **minus** the `postMessage`/`identifier.html` path (see "Out of scope").

| File | Role | Change |
|------|------|--------|
| `assets/js/oauth-config.js` | Global `OAUTH_CONFIG` — all DNS names, IdP, flags, log level | **new** (committed) |
| `assets/js/oauth-config.example.js` | Documented template to copy to `oauth-config.js` | **new** |
| `assets/js/oauth-utility-edit.js` | The 3 Claris primitives, adapted to **absolute** URLs built from `fmsDNS`, plus `getOAuthReturnUrl()` | **rewritten** |
| `assets/js/oauth-flow.js` | Shared flow: popup vs full-page redirect, resume logic, session/storage helpers | **new** |
| `assets/js/oauth-index.js` | `initOAuth` / `showOAuthLogin` / `completeIndexOAuth` (was inline in index.html) | **new** |
| `index.html` | Inline scripts removed; loads loglevel CDN + the 4 JS files | **rewritten** |
| `oauth-landing.html` | Popup return page, served from `webDNS`; writes `localStorage` | **kept as-is** |
| `custom.html` | Legacy inlined Google example with buggy `=` tracking-ID compare | **deleted** |
| `blank.html` | Unused template stub | left as-is (out of scope) |

## Configuration object

`assets/js/oauth-config.js` (committed with the demo's working values):

```js
/**
 * Feature flags + deployment settings for the OAuth demo.
 * Remote scenario: the web server (webDNS) and FileMaker Server (fmsDNS) are different boxes.
 * See oauth-config.example.js and README.txt.
 */
var OAUTH_CONFIG = {
  /** Published WebDirect file name to open after OAuth (no .fmp12 extension). */
  dbName: 'OAuth_tester',
  /** FileMaker Server box: API calls + login form POST target. */
  fmsDNS: 'mbp2013.ets.fm',
  /** This web server box: X-FMS-Return-URL (popup mode) + post-login homeUrl. */
  webDNS: 'webdlogin.ets.fm',
  /** Provider name passed to getOAuthURL (must match the FMS OAuth config). */
  identityProvider: 'Microsoft',
  /** Start OAuth as soon as provider info loads (button remains for manual retry). */
  autoStartOAuth: false,
  /** Use a full-page redirect to the IdP instead of a popup (see modes below). */
  useFullPageRedirect: false,
  /** loglevel verbosity: trace | debug | info | warn | error | silent. */
  logLevel: 'debug'
};
```

`oauth-config.example.js` is the same object with placeholder hostnames and the same doc
comments, so a deployer copies it to `oauth-config.js` and edits values.

The recently-added **loglevel** logging is folded into the `logLevel` config key (it is
itself a configuration setting). `oauth-index.js` calls `log.setLevel(OAUTH_CONFIG.logLevel)`
during init.

## The two modes (`useFullPageRedirect`), adapted for the remote case

The only behavioral branch that differs from the sibling is `getOAuthReturnUrl()` in
`oauth-utility-edit.js`, because the return URL must point at `webDNS`, not at FMS:

- **Popup mode (`false`, default):**
  `X-FMS-Return-URL = https://<webDNS>/oauth-landing.html`.
  Flow: `index.html` (on `webDNS`) opens a popup → popup goes to IdP → FMS returns the popup
  to our `oauth-landing.html` → it writes the result to `localStorage` → the parent page
  (same origin, `webDNS`) hears the `storage` event and completes login.
  **This is the path the Claris `X-FMS-Return-URL` fix enables** (return page is now allowed
  to be cross-origin to FMS, i.e. on our web server).

- **Full-page mode (`true`):**
  `X-FMS-Return-URL = <the index page's own URL on webDNS>`.
  Flow: the `index.html` tab itself navigates to the IdP (no popup) → FMS returns the tab to
  the index URL with the result in the query string → `resumeOAuthAfterRedirect()` reads
  `trackingID`/`identifier`/`error` from the query string and the request id from
  `sessionStorage` (saved before redirect via `saveOAuthSessionState`) → completes login →
  `stripOAuthParamsFromUrl()` cleans the address bar.

### Adapted primitives (`oauth-utility-edit.js`)

All three Claris functions take/derive an absolute base from `fmsDNS` (`'https://' + fmsDNS`):

- `getProviderInfo(fmsDNS, cb)` → `GET https://<fmsDNS>/fmi/webd/oauthapi/oauthproviderinfo`
- `getOAuthURL(trackingId, fmsDNS, provider, cb)` →
  `GET https://<fmsDNS>/fmi/webd/oauthapi/getoauthurl?...`, sets
  `X-FMS-Application-Type: 8` and `X-FMS-Return-URL: getOAuthReturnUrl()`.
- `doOAuthLogin(dbName, requestId, identifier, homeurl, autherr, fmsDNS)` → builds the hidden
  form POST to `https://<fmsDNS>/fmi/webd/<dbName>?lgcnt=1&oauth=1[&homeurl=][&autherr=]`.

### Flow + index glue

- `oauth-flow.js`: ports the sibling's `runOAuthLogin`, `resumeOAuthAfterRedirect`,
  `listenForOAuthPopupResponse`, `tryCompleteOAuthResponse`, session/storage helpers, plus
  the **ported fixes** — null-`oauthUrl` guard (alert + abort) and strict `===` tracking-ID
  comparison. `runOAuthLogin` passes `OAUTH_CONFIG.fmsDNS` as the API host instead of
  `window.location.hostname`.
- `oauth-index.js`: `initOAuth` sets the log level, calls `resumeOAuthAfterRedirect` first
  (full-page return), otherwise fetches provider info and renders the Member Login button
  (and auto-starts if `autoStartOAuth`). `completeIndexOAuth(identifier, autherr, requestId)`
  calls `doOAuthLogin(dbName, requestId, identifier, 'https://'+webDNS+'/index.html', autherr,
  fmsDNS)`.

## README

Clean up and rewrite `README.txt` for the **remote** scenario. It should cover:

- **What this is / which version to use.** State that this setup targets the FMS release
  where Claris fixed `X-FMS-Return-URL` to allow a cross-origin return to your own web
  server. Add a **"Older FileMaker Server (2025 / FMS22 or earlier)"** section pointing to
  the sibling repos that handle that case:
  - https://github.com/wimdecorte/fms-webd-oauth-remote — the remote site files for older
    FMS.
  - https://github.com/wimdecorte/fms-webd-oauth-remote-companion — a **companion that must
    run on the FMS box**, required by the older-FMS remote setup (because pre-fix FMS could
    not return cross-origin, so a helper on the FMS origin was needed).

  Also keep the existing pointer to the local (FMS-hosted) sibling
  https://github.com/wimdecorte/fms-webd-oauth-local and the
  [bharlow/fm-webdirect-custom](https://github.com/bharlow/fm-webdirect-custom) reference.

- **Configuration.** Document the `OAUTH_CONFIG` keys (`dbName`, `fmsDNS`, `webDNS`,
  `identityProvider`, `autoStartOAuth`, `useFullPageRedirect`, `logLevel`) and the
  copy-`oauth-config.example.js`-to-`oauth-config.js` workflow. Emphasize the `fmsDNS`
  (FileMaker Server box) vs `webDNS` (this web server box) distinction.

- **The two modes**, including how `X-FMS-Return-URL` differs between them, and a note that
  popup mode now works because Claris allows a cross-origin return URL on `webDNS`.

### Flow diagrams (one per mode)

Include an ASCII flow diagram for **each** mode so a reader can follow which window each step
runs in and where `X-FMS-Return-URL` points. ASCII (not an image) keeps it readable in a
plain-text `README.txt`. The diagrams must make these points clear:

- **Popup mode** — parent page on `webDNS` stays open; a popup carries the IdP login; FMS
  returns the **popup** to `https://<webDNS>/oauth-landing.html`; that page writes
  `localStorage`; the parent (same origin) hears the `storage` event and calls
  `doOAuthLogin` → POST to `fmsDNS`.
- **Full-page mode** — the single `index.html` tab navigates to the IdP; request id saved to
  `sessionStorage` first; FMS returns the **tab** to the index URL on `webDNS` with the
  result in the query string; `resumeOAuthAfterRedirect` reads it and calls `doOAuthLogin` →
  POST to `fmsDNS`; URL is then cleaned.

Each diagram should show the three actors (Browser on `webDNS`, FileMaker Server `fmsDNS`,
Identity Provider) and the `X-FMS-Return-URL` value used.

## Out of scope

- **`identifier.html` / `oauth-identifier.js` (`postMessage` path).** In the sibling these
  let a remote marketing site pop open the *FMS-hosted* helper and receive the identifier via
  `postMessage`. In *this* repo the site itself runs the flow and completes login directly via
  `doOAuthLogin`, so that indirection is unnecessary. Not ported.
- **Podman / Ubuntu / nginx container** for serving the static files over HTTPS. Sequenced as
  the next phase after this port lands (user: "But first … port"). Needed to exercise popup
  mode across the two real origins.
- `blank.html` cleanup.

## Success criteria

- Configuration (all DNS names, IdP, flags, log level) lives in `OAUTH_CONFIG`; no
  deployment values remain hardcoded in HTML or the flow JS.
- `useFullPageRedirect` cleanly switches between popup and full-tab redirect, with
  `X-FMS-Return-URL` correctly targeting `webDNS` in both modes.
- All FMS-directed requests/POST use absolute URLs built from `fmsDNS`.
- `custom.html` is removed; `index.html` contains no inline OAuth logic.
- The structure parallels the sibling repo except for the intentionally-omitted
  `postMessage` path and the relative-vs-absolute URL adaptation.
- `README.txt` is cleaned up, documents `OAUTH_CONFIG` and both modes, includes an ASCII
  flow diagram per mode, and references the older-FMS sibling repos
  (`fms-webd-oauth-remote` + its FMS-box `fms-webd-oauth-remote-companion`) alongside the
  local sibling.
