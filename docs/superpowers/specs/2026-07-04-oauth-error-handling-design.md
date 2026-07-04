# OAuth failure handling — return-URL parsing fix + graceful in-browser error

**Date:** 2026-07-04
**Status:** Approved design, pending implementation plan
**Scope:** Client-side JS only (`assets/js/oauth-flow.js`, `assets/js/oauth-index.js`, `assets/js/oauth-utility-edit.js`) + a Node parser test. No FMS-side or server changes.

## Problem

When a WebDirect OAuth login fails on the FileMaker Server side, the browser lands back on
`index.html` with no explanation, and the returned URL is malformed. Observed landing URL
(from the captured HAR, full-page-redirect mode):

```
https://wim.ets.fm/index.html
  ?lgcnt=1&oauth=1&homeurl=https://wim.ets.fm/index.html&autherr=-1
   &db=OAuth_tester&loginerr=1627&guesten=0&hidelocalaccountentry=0
  ?trackingID=123432&identifier=-1&hiddenemail=false&error=-1
  ?trackingID=123432&identifier=-1&hiddenemail=false&error=-1
```

FileMaker Server signalled failure at the code-exchange boundary (`x-fms-result: -1` response
header on `POST /oauth/redirect`), which surfaces here as `identifier=-1`, `error=-1`, and
`loginerr=1627` (FileMaker "Authentication failed"). The Microsoft handshake itself succeeded;
FMS refused to authorize the user.

Two distinct client-side defects follow from this:

1. **Unparseable response.** The return URL contains multiple `?` characters. FMS builds it in
   two independent layers that each append `?...` without checking for an existing query
   (WebDirect's login-failure redirect, then the OAuth result), and a retry from an
   already-dirty URL adds a third. `getOAuthResponseParameter` splits on `&` then `=`, so
   segments like `hidelocalaccountentry=0?trackingID=123432` and `?trackingID=123432` never
   yield a clean `trackingID` key. `resumeOAuthAfterRedirect` therefore fails to parse the
   response and silently bails — the user sees the bare index page.

2. **No error surfaced.** Even once parsing is fixed, nothing tells the user what happened.

### Critical coupling (fix them together)

Today the broken parser is *accidentally* protective: because `trackingID` can't be parsed,
`resumeOAuthAfterRedirect` returns early and never calls `doOAuthLogin`. If parsing is fixed
**alone**, the resume path would parse `identifier=-1` and hand it to `doOAuthLogin`, which
POSTs `pwd=-1` to WebDirect → fails → FMS redirects back → parse again → **redirect loop**.
Therefore the parsing fix must ship together with error detection that short-circuits before
`doOAuthLogin`.

## Goals

- Reliably parse the OAuth response regardless of how many `?` characters the return URL contains.
- Detect a failed OAuth response and stop before attempting the WebDirect login (no redirect loop).
- Show the user a clear, styled, in-page message on failure, with technical detail for support.
- Leave the Member Login button in place so the user can retry.
- Preserve the exact FMS request/response contract.

## Non-goals (YAGNI)

- No internationalization / multi-language support (English-only, per decision).
- No changes to popup-mode behavior beyond the shared parser (config is full-page today).
- No auto-retry, countdown, or dedicated error page — inline message, button stays.
- No changes to what is sent to FMS or how FMS's response is read.

## Design

### 1. Robust response parsing — `assets/js/oauth-flow.js`

Normalize the input before splitting so stray `?` characters act as parameter delimiters:

- In `getOAuthResponseParameter(input, parameter)`, replace every `?` with `&` before
  `split('&')`. First match wins (the OAuth result params appear before their duplicates, and
  duplicates carry identical values). No other behavior change.
- Add `parseOAuthResponse(raw)` → `{ trackingID, identifier, error, loginerr }`, built on
  `getOAuthResponseParameter`, giving one place that knows the response shape.
- Add `isOAuthErrorResponse(result)` → `true` when the response represents a failed login:
  - `identifier` is empty or `'-1'`, **or**
  - `error` is present and not `''` and not `'0'`.

`loginerr` is included in the parsed result because it carries the actionable FileMaker error
code (e.g. `1627`); it is present in full-page-redirect responses and simply absent (empty) in
popup-mode responses.

### 2. Stop the compounding — `assets/js/oauth-utility-edit.js` (`getOAuthReturnUrl`)

Change the full-page branch from `window.location.href.split('#')[0]` to
`window.location.origin + window.location.pathname`. The return URL sent to FMS is then always
free of a leftover query string, so retries can't accumulate `?` chains. FMS still emits its
own double-`?`, so item 1 remains required; this is defense in depth against retry compounding.

### 3. Error detection & short-circuit — completion contract

Change the completion callback from `onComplete(identifier, error, requestId)` to
`onComplete(result)`, where `result` is the `parseOAuthResponse` object with `requestId`
attached. This is an **internal** change between `oauth-flow.js` and `oauth-index.js` only —
it does not alter any FMS request or response parsing.

- `tryCompleteOAuthResponse` builds `result = parseOAuthResponse(response)`, sets
  `result.requestId = requestId`, and calls `onComplete(result)`. It continues to clear session
  state and (via `resumeOAuthAfterRedirect`) strip the OAuth params from the URL on this path,
  so a subsequent retry starts clean.
- `completeIndexOAuth(result)` in `oauth-index.js`:
  - If `isOAuthErrorResponse(result)` → `showOAuthError(result)` and **return** (no login POST).
  - Otherwise → `doOAuthLogin(dbName, result.requestId, result.identifier, homeUrl,
    result.error, fmsDNS)` exactly as today (same values, same order).

### 4. Inline error UI — `assets/js/oauth-index.js`

`showOAuthError(result)` renders a styled `<div id="oauth-message">` inside `#inner`
(removing any prior instance first):

- **Friendly line**, chosen from a message map keyed by FileMaker error code:
  - `1627` → "You signed in with Microsoft, but this account isn't authorized to open this
    database. Contact your administrator to confirm your access."
  - `default` → "Sign-in didn't complete. Please try again, or contact your administrator if
    the problem continues."
- **Secondary muted line** for support: the FileMaker error code (`loginerr`, falling back to
  `error` when `loginerr` is absent) and the tracking ID — e.g. `FileMaker error 1627 ·
  Tracking ID 123432`. Omit a field when its value is empty.
- Styling is self-contained (inline styles / a small scoped block), not dependent on the Photon
  template CSS: a left accent border, padding, subtle background, readable on the light page.

The Member Login button must remain available for retry. Because `initOAuth` returns early on
the resume path, extract a shared `renderLoginButton()` (from the existing `getProviderInfo`
callback) and have `showOAuthError` call it so the button is present on the error-landing page.
`renderLoginButton()` guards against creating a duplicate button.

`initOAuth` becomes:

```
log.setLevel(...) ; log.debug('config:', OAUTH_CONFIG)
if (resumeOAuthAfterRedirect(completeIndexOAuth)) return;   // success POST in flight, or error UI shown (which rendered the button)
getProviderInfo(fmsDNS, providerInfo => { if (providerInfo) renderLoginButton(); })
```

On the error path, `resumeOAuthAfterRedirect` → `completeIndexOAuth` → `showOAuthError` renders
both the message and the button, then returns `true`, so `initOAuth` exits without a redundant
`getProviderInfo` call.

### 5. Testing — `test/oauth-parse.test.js`

No test framework exists, so add one standalone Node script (run with `node
test/oauth-parse.test.js`, exits non-zero on failure). It loads `oauth-flow.js` via `vm` (top
level is only `var`/`function` declarations, so evaluation is side-effect-free and needs no DOM
stubs) and asserts against the **actual malformed URLs from the HAR**:

- Triple-`?` and double-`?` landing query strings → `trackingID='123432'`, `identifier='-1'`,
  `error='-1'`, `loginerr='1627'`, `isOAuthErrorResponse(result) === true`.
- Clean success-shaped string (`trackingID=123432&identifier=<token>&error=`) →
  `isOAuthErrorResponse(result) === false`, `identifier` equals the token.
- Clean single-`?` error string → `isOAuthErrorResponse(result) === true`.

Written first (fails against current code), then the implementation makes it pass.

## Files touched

- `assets/js/oauth-flow.js` — normalize parsing, add `parseOAuthResponse` / `isOAuthErrorResponse`, pass result object to `onComplete`.
- `assets/js/oauth-utility-edit.js` — clean return URL in `getOAuthReturnUrl` (`origin + pathname`).
- `assets/js/oauth-index.js` — `completeIndexOAuth` branches on error, `showOAuthError`, shared `renderLoginButton`, `initOAuth` restructure.
- `test/oauth-parse.test.js` — new Node parser test.

## FMS contract — unchanged

The same request headers and query are sent to FMS; the same response header (`X-FMS-Request-ID`)
and returned params (`trackingID` / `identifier` / `error` / `loginerr`) are read. Only the
internal hand-off between our two JS files and the client's own return-URL string change.
