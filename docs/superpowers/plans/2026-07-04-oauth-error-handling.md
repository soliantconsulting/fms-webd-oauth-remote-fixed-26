# OAuth Failure Handling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Parse the OAuth return URL reliably despite multiple `?` characters, and show a clear in-page error (instead of a silent bounce to index) when FileMaker Server rejects the login — without triggering a redirect loop.

**Architecture:** Three plain browser scripts already split the work: `oauth-flow.js` (mode-aware flow + response parsing), `oauth-utility-edit.js` (Claris API primitives), `oauth-index.js` (page glue). We harden the parser and add two pure helpers in `oauth-flow.js`, clean the return URL in `oauth-utility-edit.js`, and add error detection + an inline error UI in `oauth-index.js`. A standalone Node script tests the pure parser against the real malformed URLs from the captured HAR.

**Tech Stack:** Plain ES5 browser JavaScript (no build system, no package manager, no framework). Node.js `vm` module for the one test script.

## Global Constraints

- Browser JS matches the existing files: ES5 style — `var`, `function` declarations, no `const`/`let`/arrow functions. No new runtime dependencies. No build step.
- English-only copy. Friendly messages live in a map keyed by FileMaker error code with a `'default'` key.
- Any value taken from the FMS response (identifier, error, tracking id) is rendered with `textContent`, never `innerHTML`.
- The FMS request/response contract is unchanged: same headers, same query, same response fields read. Only internal hand-offs between our own files and our own return-URL string change.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## File Structure

- `assets/js/oauth-flow.js` (modify) — normalize `?` in `getOAuthResponseParameter`; add `parseOAuthResponse` and `isOAuthErrorResponse`; in Task 3, pass a result object to `onComplete`.
- `assets/js/oauth-utility-edit.js` (modify, Task 3) — `getOAuthReturnUrl` returns `origin + pathname` in full-page mode.
- `assets/js/oauth-index.js` (modify) — error message map + `showOAuthError`; shared `renderLoginButton`; in Task 3, `completeIndexOAuth` branches on error and `initOAuth` uses `renderLoginButton`.
- `test/oauth-parse.test.js` (create) — Node script testing the pure parser/detector against real HAR URLs.

---

## Task 1: Robust response parsing + detector (with test)

**Files:**
- Modify: `assets/js/oauth-flow.js:15-30` (normalize parsing) and add helpers after line 30
- Test: `test/oauth-parse.test.js` (create)

**Interfaces:**
- Produces: `getOAuthResponseParameter(input, parameter) -> string` (existing, now `?`-tolerant); `parseOAuthResponse(raw) -> { trackingID, identifier, error, loginerr }` (all strings, `''` when absent); `isOAuthErrorResponse(result) -> boolean`.

- [ ] **Step 1: Write the failing test**

Create `test/oauth-parse.test.js`:

```javascript
'use strict';

var fs = require('fs');
var vm = require('vm');
var path = require('path');

// Load the browser script into an isolated context. Its top level is only
// var/function declarations, so evaluating it runs no DOM-touching code.
var code = fs.readFileSync(path.join(__dirname, '..', 'assets', 'js', 'oauth-flow.js'), 'utf8');
var ctx = {};
vm.createContext(ctx);
vm.runInContext(code, ctx);

var failures = 0;
function check(label, actual, expected) {
	var ok = actual === expected;
	if (!ok) { failures++; }
	console.log((ok ? 'PASS ' : 'FAIL ') + label + (ok ? '' : ' (got ' + JSON.stringify(actual) + ', expected ' + JSON.stringify(expected) + ')'));
}

// Real landing query strings captured in the HAR (query part only, no leading '?').
var tripleQ = 'lgcnt=1&oauth=1&homeurl=https://wim.ets.fm/index.html&autherr=-1&db=OAuth_tester&loginerr=1627&guesten=0&hidelocalaccountentry=0?trackingID=123432&identifier=-1&hiddenemail=false&error=-1?trackingID=123432&identifier=-1&hiddenemail=false&error=-1';
var doubleQ = 'lgcnt=1&oauth=1&homeurl=https://wim.ets.fm/index.html&autherr=-1&db=OAuth_tester&loginerr=1627&guesten=0&hidelocalaccountentry=0?trackingID=123432&identifier=-1&hiddenemail=false&error=-1';
var success = 'trackingID=123432&identifier=ABCDEF0123456789TOKEN&error=';
var cleanError = 'trackingID=123432&identifier=-1&error=-1';

var t = ctx.parseOAuthResponse(tripleQ);
check('triple ? trackingID', t.trackingID, '123432');
check('triple ? identifier', t.identifier, '-1');
check('triple ? error', t.error, '-1');
check('triple ? loginerr', t.loginerr, '1627');
check('triple ? isError', ctx.isOAuthErrorResponse(t), true);

var d = ctx.parseOAuthResponse(doubleQ);
check('double ? trackingID', d.trackingID, '123432');
check('double ? loginerr', d.loginerr, '1627');
check('double ? isError', ctx.isOAuthErrorResponse(d), true);

var s = ctx.parseOAuthResponse(success);
check('success identifier', s.identifier, 'ABCDEF0123456789TOKEN');
check('success error', s.error, '');
check('success isError', ctx.isOAuthErrorResponse(s), false);

check('cleanError isError', ctx.isOAuthErrorResponse(ctx.parseOAuthResponse(cleanError)), true);

if (failures > 0) {
	console.log('\n' + failures + ' failure(s)');
	process.exit(1);
}
console.log('\nAll parser tests passed');
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node test/oauth-parse.test.js`
Expected: FAIL — throws `TypeError: ctx.parseOAuthResponse is not a function` (helpers don't exist yet).

- [ ] **Step 3: Normalize `?` in the parser**

In `assets/js/oauth-flow.js`, change line 19 from:

```javascript
		params = input.split('&');
```

to:

```javascript
		params = input.replace(/\?/g, '&').split('&');
```

- [ ] **Step 4: Add the parse + detect helpers**

In `assets/js/oauth-flow.js`, immediately after the closing `}` of `getOAuthResponseParameter` (line 30) and before `function useFullPageRedirect()`, insert:

```javascript
function parseOAuthResponse(raw) {
	return {
		trackingID: getOAuthResponseParameter(raw, 'trackingID'),
		identifier: getOAuthResponseParameter(raw, 'identifier'),
		error: getOAuthResponseParameter(raw, 'error'),
		loginerr: getOAuthResponseParameter(raw, 'loginerr')
	};
}

function isOAuthErrorResponse(result) {
	if (!result) {
		return true;
	}
	if (!result.identifier || result.identifier === '-1') {
		return true;
	}
	if (result.error && result.error !== '0') {
		return true;
	}
	return false;
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `node test/oauth-parse.test.js`
Expected: PASS — prints `All parser tests passed`, exits 0.

- [ ] **Step 6: Commit**

```bash
git add test/oauth-parse.test.js assets/js/oauth-flow.js
git commit -m "$(cat <<'EOF'
Make OAuth response parser tolerant of multiple ? separators

Normalize '?' to '&' before splitting so trackingID/identifier/error/loginerr
parse out of FMS's malformed multi-'?' return URL. Add parseOAuthResponse and
isOAuthErrorResponse helpers, covered by a standalone Node test using the real
HAR URLs.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Inline error UI + shared login button

**Files:**
- Modify: `assets/js/oauth-index.js` (add message map, `oauthErrorMessage`, `showOAuthError`, `renderLoginButton`)

**Interfaces:**
- Consumes: `getIdentityProviderName()` and `showOAuthLogin(providerName)` (existing in `oauth-flow.js` / `oauth-index.js`).
- Produces: `renderLoginButton(providerInfo)` (providerInfo optional; idempotent — will not create a second `#oauth-login-btn`); `showOAuthError(result)` where `result` is a `parseOAuthResponse` object optionally carrying `requestId`.

- [ ] **Step 1: Add the message map and helpers**

In `assets/js/oauth-index.js`, insert after the top comment block (before `function completeIndexOAuth`):

```javascript
var OAUTH_ERROR_MESSAGES = {
	'1627': 'You signed in with Microsoft, but this account isn’t authorized to open this database. Contact your administrator to confirm your access.',
	'default': 'Sign-in didn’t complete. Please try again, or contact your administrator if the problem continues.'
};

function oauthErrorMessage(result) {
	var code = result.loginerr || result.error;
	if (code && OAUTH_ERROR_MESSAGES[code]) {
		return OAUTH_ERROR_MESSAGES[code];
	}
	return OAUTH_ERROR_MESSAGES['default'];
}

function renderLoginButton(providerInfo) {
	if (document.getElementById('oauth-login-btn')) {
		return;
	}

	var oauthWrapper = document.getElementById('inner');
	var providerName = getIdentityProviderName();
	var button = document.createElement('button');

	button.id = 'oauth-login-btn';
	button.innerHTML = 'Member Login';
	button.style.width = '350px';
	button.style.height = '60px';
	button.style.textAlign = 'center';
	if (providerInfo) {
		button.dataset.provider = providerInfo;
	}
	button.onclick = function () {
		showOAuthLogin(providerName);
	};

	oauthWrapper.appendChild(button);
}

function showOAuthError(result) {
	var wrapper = document.getElementById('inner');
	var existing = document.getElementById('oauth-message');
	if (existing) {
		existing.parentNode.removeChild(existing);
	}

	var box = document.createElement('div');
	box.id = 'oauth-message';
	box.style.margin = '1.5em auto';
	box.style.maxWidth = '600px';
	box.style.padding = '1em 1.25em';
	box.style.borderLeft = '4px solid #e8505b';
	box.style.background = 'rgba(232, 80, 91, 0.12)';
	box.style.textAlign = 'left';
	box.style.borderRadius = '4px';

	var msg = document.createElement('p');
	msg.style.margin = '0 0 0.5em 0';
	msg.textContent = oauthErrorMessage(result);
	box.appendChild(msg);

	var detailBits = [];
	if (result.loginerr) {
		detailBits.push('FileMaker error ' + result.loginerr);
	} else if (result.error) {
		detailBits.push('Error ' + result.error);
	}
	if (result.trackingID) {
		detailBits.push('Tracking ID ' + result.trackingID);
	}
	if (detailBits.length) {
		var detail = document.createElement('small');
		detail.style.opacity = '0.7';
		detail.textContent = detailBits.join(' · ');
		box.appendChild(detail);
	}

	wrapper.appendChild(box);
	renderLoginButton();
}
```

- [ ] **Step 2: Manually verify in the browser (no wiring yet)**

Serve the site over HTTPS from `wim.ets.fm` as usual and load `index.html`. In DevTools Console run:

```javascript
showOAuthError({ trackingID: '123432', identifier: '-1', error: '-1', loginerr: '1627' });
```

Expected: a red-accented message box appears in the header reading "You signed in with Microsoft, but this account isn't authorized…", with a muted line `FileMaker error 1627 · Tracking ID 123432`, and a `Member Login` button below it. Run the same call again — expected: the box is replaced (not duplicated) and no second button appears.

- [ ] **Step 3: Commit**

```bash
git add assets/js/oauth-index.js
git commit -m "$(cat <<'EOF'
Add inline OAuth error UI and shared login-button renderer

showOAuthError renders a styled, idempotent message block (friendly text from
a code-keyed map + support detail) and keeps a Member Login button for retry.
renderLoginButton is extracted for reuse. Not yet wired into the flow.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire error detection into the flow + stop URL compounding

**Files:**
- Modify: `assets/js/oauth-flow.js:75-93` (`tryCompleteOAuthResponse` passes a result object)
- Modify: `assets/js/oauth-index.js:7-16` (`completeIndexOAuth`) and `:22-52` (`initOAuth`)
- Modify: `assets/js/oauth-utility-edit.js:31-36` (`getOAuthReturnUrl`)

**Interfaces:**
- Consumes: `parseOAuthResponse`, `isOAuthErrorResponse`, `showOAuthError`, `renderLoginButton`.
- Produces: `onComplete(result)` contract — `result` is `{ trackingID, identifier, error, loginerr, requestId }`.

- [ ] **Step 1: Pass a result object from `tryCompleteOAuthResponse`**

In `assets/js/oauth-flow.js`, replace the body of `tryCompleteOAuthResponse` (lines 75-93) with:

```javascript
function tryCompleteOAuthResponse(response, trackingId, requestId, onComplete) {
	if (!response || !onComplete) {
		return false;
	}

	var result = parseOAuthResponse(response);
	if (trackingId !== result.trackingID) {
		return false;
	}

	localStorage.removeItem(OAUTH_STORAGE_KEY);
	clearOAuthSessionState();
	result.requestId = requestId;
	onComplete(result);
	return true;
}
```

- [ ] **Step 2: Branch on error in `completeIndexOAuth`**

In `assets/js/oauth-index.js`, replace `completeIndexOAuth` (lines 7-16) with:

```javascript
function completeIndexOAuth(result) {
	if (isOAuthErrorResponse(result)) {
		showOAuthError(result);
		return;
	}
	doOAuthLogin(
		OAUTH_CONFIG.dbName,
		result.requestId,
		result.identifier,
		'https://' + OAUTH_CONFIG.webDNS + '/index.html',
		result.error,
		OAUTH_CONFIG.fmsDNS
	);
}
```

- [ ] **Step 3: Use `renderLoginButton` in `initOAuth`**

In `assets/js/oauth-index.js`, replace `initOAuth` (lines 22-52) with:

```javascript
function initOAuth() {
	log.setLevel(OAUTH_CONFIG.logLevel);
	log.debug('config:', OAUTH_CONFIG);

	if (resumeOAuthAfterRedirect(completeIndexOAuth)) {
		return;
	}

	getProviderInfo(OAUTH_CONFIG.fmsDNS, function (providerInfo) {
		if (providerInfo != null && providerInfo != '') {
			renderLoginButton(providerInfo);

			if (shouldAutoStartOAuth()) {
				showOAuthLogin(getIdentityProviderName());
			}
		}
	});
}
```

- [ ] **Step 4: Clean the return URL**

In `assets/js/oauth-utility-edit.js`, change the full-page branch of `getOAuthReturnUrl` (line 33) from:

```javascript
		return window.location.href.split('#')[0];
```

to:

```javascript
		return window.location.origin + window.location.pathname;
```

- [ ] **Step 5: Re-run the parser test (guard against regressions)**

Run: `node test/oauth-parse.test.js`
Expected: PASS — `All parser tests passed` (the contract change must not break parsing).

- [ ] **Step 6: Manual end-to-end verification in the browser**

Serve over HTTPS from `wim.ets.fm`. With DevTools open (Console + Network, **Preserve log** on):

1. Load `index.html` → expected: single `Member Login` button, no error box, no console errors.
2. Click `Member Login`, complete Microsoft sign-in. Because FMS currently returns `1627`, you land back on `index.html`.
3. Expected on landing: the red-accented error box with the "not authorized" message, a muted `FileMaker error 1627 · Tracking ID 123432` line, and the `Member Login` button present beneath it.
4. Expected: the address bar query string is stripped (no `?trackingID…`), and the Network panel shows the landing load **once** — no repeating `index.html?lgcnt=1&oauth=1…` requests (no redirect loop).
5. Click `Member Login` again → expected: a fresh OAuth attempt starts (redirect to Microsoft), confirming retry works from a clean URL.

Note: the success path (`identifier` = real token → `doOAuthLogin`) cannot be exercised until the FMS-side `1627` is resolved. It is preserved by construction — `completeIndexOAuth` passes the same `dbName`, `requestId`, `identifier`, `homeurl`, `error`, `fmsDNS` values, in the same order, to the unchanged `doOAuthLogin`.

- [ ] **Step 7: Commit**

```bash
git add assets/js/oauth-flow.js assets/js/oauth-index.js assets/js/oauth-utility-edit.js
git commit -m "$(cat <<'EOF'
Surface OAuth login failures in-page and stop return-URL compounding

Pass a parsed result object to the completion callback; completeIndexOAuth now
short-circuits to showOAuthError on a failed response instead of POSTing an
invalid credential (which had looped). getOAuthReturnUrl returns origin+pathname
so retries no longer accumulate '?' chains. initOAuth reuses renderLoginButton.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- Robust parsing (spec §1) → Task 1 Steps 3-4. ✓
- Stop compounding / clean return URL (spec §2) → Task 3 Step 4. ✓
- Error detection & short-circuit / callback contract (spec §3) → Task 3 Steps 1-2. ✓
- Inline error UI, message map, keep button, shared renderLoginButton (spec §4) → Task 2 + Task 3 Step 3. ✓
- Testing with real HAR URLs (spec §5) → Task 1 Step 1. ✓
- FMS contract unchanged → no request/response code altered; verified by construction note in Task 3 Step 6. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows complete code. ✓

**Type consistency:** `parseOAuthResponse` returns `{ trackingID, identifier, error, loginerr }` in Task 1 and is consumed with those exact keys in Tasks 2-3; `result.requestId` added in Task 3 Step 1 and read in Task 3 Step 2; `renderLoginButton`, `showOAuthError`, `isOAuthErrorResponse`, `oauthErrorMessage` names match across tasks. ✓
