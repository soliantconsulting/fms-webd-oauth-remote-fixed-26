# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A static demo website showing how to start the OAuth login flow into a FileMaker **WebDirect** database directly from your own web page — bypassing the WebDirect launch center and login screen. This is the "remote" variant: it is meant to be hosted on a web site that does **not** run on FileMaker Server (FMS).

Based on the Claris utility documented at https://support.claris.com/s/answerview?anum=000035915. The page chrome is the Photon template by HTML5 UP (the `assets/`, `images/`, and most of `main.js`/`util.js` are template code, not application logic).

There is **no build system, package manager, or test suite** — it is plain HTML/JS served statically over HTTPS.

## Running / developing

- Serve the files over **HTTPS** from the host configured as `thisDNS` in [index.html](index.html) (the OAuth/`localStorage` flow will not work over `file://` or plain HTTP, and origin must match — see Architecture).
- [.vscode/launch.json](.vscode/launch.json) has a Chrome launch config pointing at a deployment URL. Update its `url` to your environment before using it.
- Configuration lives in the inline `<script>` config area near the top of [index.html](index.html): `dbName`, `fmsDNS` (the FileMaker Server host), `thisDNS` (the host serving this site), `OauthProvider`, and `homeUrl`. Logging verbosity is controlled by `log.setLevel(...)` (loglevel is loaded from a CDN); set to `"silent"` to disable.

## Architecture — the OAuth handshake

The login is a multi-step, multi-window dance between three origins: this web site (`thisDNS`), the FileMaker Server (`fmsDNS`), and the OAuth provider. The three core functions live in [assets/js/oauth-utility-edit.js](assets/js/oauth-utility-edit.js) and are orchestrated by [index.html](index.html):

1. **`getProviderInfo(fmsDNS, cb)`** — `GET https://<fmsDNS>/fmi/webd/oauthapi/oauthproviderinfo` to discover supported providers. `index.html` uses the result only to decide whether to render the login button.
2. **`getOAuthURL(trackingId, fmsDNS, provider, cb)`** — `GET .../oauthapi/getoauthurl`. Returns the provider's OAuth URL plus an `X-FMS-Request-ID` response header (the `requestId`, half of what's needed to log in). Sends `X-FMS-Application-Type: 8` and an **`X-FMS-Return-URL`** header telling FMS where to redirect after auth.
3. **Child window + provider auth** — `showOAuthLogin()` opens a child window, navigates it to the OAuth URL, and the user authenticates with the provider.
4. **Landing page → `localStorage`** — after auth, FMS redirects the child window to [oauth-landing.html](oauth-landing.html), whose `saveMessage()` writes the URL query string into `localStorage['oauth-response']` and closes the window.
5. **`storage` event → login** — the parent window (`index.html`) listens for the `storage` event, parses `trackingID`/`identifier`/`error`, verifies the tracking ID matches, then calls **`doOAuthLogin(...)`**, which builds a hidden `<form>` POST to `https://<fmsDNS>/fmi/webd/<dbName>` with `user=requestId` and `pwd=identifier` (plus `lgcnt=1&oauth=1` and optional `homeurl`/`autherr`) to complete the WebDirect login.

### The critical cross-origin constraint (where bugs live)

The browser only fires a `storage` event in the parent window when the landing page writes to `localStorage` **on the same origin as the parent**. So step 4's landing page must be served from `thisDNS` (the parent's origin) for step 5 to ever fire.

In [oauth-utility-edit.js](assets/js/oauth-utility-edit.js) `getOAuthURL` sets `X-FMS-Return-URL`, and there are two mutually exclusive options in the code — one pointing at the FMS box (`<fmsDNS>/fmi/webd/oauth-landing.html`) and a commented-out one pointing at the caller (`window.location.origin/oauth-landing.html`). Using the FMS-hosted landing page puts it on a **different** origin than the parent, so the `storage` listener never receives the response and login silently stalls (this is the "we don't seem to get past this point" symptom noted in `index.html` and the focus of recent commits). When debugging "login doesn't happen," check this return-URL origin against the parent's origin first.

## Files of note vs. legacy

- [index.html](index.html) — the active, maintained page (Microsoft provider, `loglevel` debug logging, `homeUrl` handling).
- [custom.html](custom.html) — an older standalone example (Google provider) with **inlined, divergent** copies of the OAuth functions and different argument signatures (e.g. `doOAuthLogin` without `homeurl`/`fmsDNS`). It is gitignored in some setups; treat it as reference only and do not assume it stays in sync with `oauth-utility-edit.js`.
- [oauth-landing.html](oauth-landing.html) — the OAuth callback page; whichever origin `X-FMS-Return-URL` targets must serve this file.
- `assets/js/oauth-utility.js` is gitignored — it is the original unmodified Claris utility; `oauth-utility-edit.js` is the edited version this project actually uses.
