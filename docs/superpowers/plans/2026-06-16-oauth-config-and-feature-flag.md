# OAuth Config Separation + Full-Page-Redirect Flag Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the sibling repo's `OAUTH_CONFIG` object and `useFullPageRedirect` feature flag into this remote-scenario repo, adapting all URLs to be absolute (built from `fmsDNS`) and renaming the web-server host to `webDNS`.

**Architecture:** Static HTML/JS demo (no build step, no package manager, no test runner). Configuration moves out of inline `<script>` blocks into a global `OAUTH_CONFIG` object in `assets/js/oauth-config.js`. OAuth logic splits into three files: `oauth-utility-edit.js` (the three Claris API primitives, adapted to absolute URLs + a `getOAuthReturnUrl()` helper), `oauth-flow.js` (mode-aware flow: popup vs full-page redirect, resume logic, storage/session helpers), and `oauth-index.js` (page glue: init, button, completion). `index.html` becomes markup + script tags only.

**Tech Stack:** Plain HTML, vanilla JS (ES5-style `var`, matching the existing/sibling code), [loglevel](https://github.com/pimterry/loglevel) from CDN, FileMaker Server WebDirect OAuth API.

**Reference:** Design spec at [docs/superpowers/specs/2026-06-16-oauth-config-and-feature-flag-design.md](../specs/2026-06-16-oauth-config-and-feature-flag-design.md). Sibling repo (FMS-hosted variant): https://github.com/wimdecorte/fms-webd-oauth-local

---

## Testing approach (read before starting)

This repo has **no automated test framework** and the OAuth flow needs a live FileMaker Server + identity provider, so tasks cannot use `pytest`-style red/green TDD. Each task is verified one of two ways:

- **Static checks** (most tasks): exact-content assertions plus `grep` guards that catch the two highest-risk regressions — (a) any FMS API call or login POST that is *not* an absolute `https://<fmsDNS>` URL, and (b) any lingering `thisDNS` after the rename. These run with no server.
- **Manual flow checks** (Task 8 only): documented browser steps to run once a real `webDNS`/`fmsDNS`/IdP are available. They are explicitly marked and are not a blocker for committing the code tasks.

Match the **existing code style**: `var` (not `let`/`const`) in the OAuth JS files, tabs for indentation, single quotes — consistent with the current `assets/js/oauth-utility-edit.js` and the sibling repo.

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `assets/js/oauth-config.js` | Create | Global `OAUTH_CONFIG` with the demo's working values |
| `assets/js/oauth-config.example.js` | Create | Placeholder template + doc comments to copy from |
| `assets/js/oauth-utility-edit.js` | Rewrite | 3 Claris primitives, absolute URLs from `fmsDNS`, `getOAuthReturnUrl()` |
| `assets/js/oauth-flow.js` | Create | Mode-aware flow, resume logic, storage/session helpers, ported fixes |
| `assets/js/oauth-index.js` | Create | `initOAuth`, `showOAuthLogin`, `completeIndexOAuth` |
| `index.html` | Rewrite | Markup + script tags only (no inline OAuth logic) |
| `oauth-landing.html` | Keep | Popup return page on `webDNS` (already writes localStorage) |
| `custom.html` | Delete | Legacy inlined Google example with buggy `=` compare |
| `README.txt` | Rewrite | Config docs, two modes, ASCII flow diagrams, older-FMS sibling refs |

---

## Task 1: Create the config files

**Files:**
- Create: `assets/js/oauth-config.js`
- Create: `assets/js/oauth-config.example.js`

- [ ] **Step 1: Create `assets/js/oauth-config.js`** with the demo's working values

```js
/**
 * Feature flags + deployment settings for the OAuth demo.
 * Remote scenario: the web server (webDNS) and FileMaker Server (fmsDNS) are different boxes.
 * Copy oauth-config.example.js to this file and edit for your deployment.
 */
var OAUTH_CONFIG = {
	/** Published WebDirect file name to open after OAuth (no .fmp12 extension). */
	dbName: 'OAuth_tester',
	/** FileMaker Server box: target of all API calls and the login form POST. */
	fmsDNS: 'mbp2013.ets.fm',
	/** This web server box: X-FMS-Return-URL (popup mode) + post-login homeUrl. */
	webDNS: 'webdlogin.ets.fm',
	/** Provider name passed to getOAuthURL (must match the FMS OAuth config). */
	identityProvider: 'Microsoft',
	/** Start OAuth as soon as provider info loads (button remains for manual retry). */
	autoStartOAuth: false,
	/** Use a full-page redirect to the IdP instead of a popup (see README.txt). */
	useFullPageRedirect: false,
	/** loglevel verbosity: trace | debug | info | warn | error | silent. */
	logLevel: 'debug'
};
```

- [ ] **Step 2: Create `assets/js/oauth-config.example.js`** — same structure, placeholder hostnames

```js
/**
 * Copy this file to oauth-config.js and edit the values for your deployment.
 * Remote scenario: the web server (webDNS) and FileMaker Server (fmsDNS) are different boxes.
 * This site is static HTML/JS — the browser cannot read a .env file; edit this object instead.
 */
var OAUTH_CONFIG = {
	/** Published WebDirect file name to open after OAuth (no .fmp12 extension). */
	dbName: 'OAuth_tester',
	/** FileMaker Server box: target of all API calls and the login form POST. */
	fmsDNS: 'your-filemaker-server.example.com',
	/** This web server box: X-FMS-Return-URL (popup mode) + post-login homeUrl. */
	webDNS: 'your-web-server.example.com',
	/** Provider name passed to getOAuthURL (must match the FMS OAuth config). */
	identityProvider: 'Microsoft',
	/** Start OAuth as soon as provider info loads (button remains for manual retry). */
	autoStartOAuth: false,
	/** Use a full-page redirect to the IdP instead of a popup (see README.txt). */
	useFullPageRedirect: false,
	/** loglevel verbosity: trace | debug | info | warn | error | silent. */
	logLevel: 'debug'
};
```

- [ ] **Step 3: Verify both files define the same keys**

Run:
```bash
for f in oauth-config oauth-config.example; do
  echo "== $f =="
  grep -oE '^\s+(dbName|fmsDNS|webDNS|identityProvider|autoStartOAuth|useFullPageRedirect|logLevel):' "assets/js/$f.js" | sed -E 's/[: ]//g' | sort
done
```
Expected: both lists identical — `autoStartOAuth dbName fmsDNS identityProvider logLevel useFullPageRedirect webDNS`.

- [ ] **Step 4: Commit**

```bash
git add assets/js/oauth-config.js assets/js/oauth-config.example.js
git commit -m "Add OAUTH_CONFIG object (config + example template)"
```

---

## Task 2: Rewrite oauth-utility-edit.js with absolute URLs + return-URL helper

**Files:**
- Modify (full rewrite): `assets/js/oauth-utility-edit.js`

This file currently has working absolute-URL versions of `getProviderInfo`/`getOAuthURL`/`doOAuthLogin` but hardcodes the return URL to the FMS box. Replace the hardcoded return URL with a mode-aware `getOAuthReturnUrl()` that targets `webDNS`.

- [ ] **Step 1: Replace the entire file contents** with:

```js
/**
 * The three Claris WebDirect OAuth API primitives, adapted for the remote scenario:
 * every FMS-directed URL is absolute (https://<fmsDNS>...), and the OAuth return URL
 * points at this web server (webDNS) so the Claris X-FMS-Return-URL cross-origin fix
 * brings the user/popup back to our pages. See README.txt and oauth-flow.js.
 */

function getProviderInfo(fmsDNS, callback) {
	var xhr = new XMLHttpRequest();
	var server = 'https://' + fmsDNS;
	xhr.onreadystatechange = function () {
		if (xhr.readyState == 4) {
			var providerInfo = null;
			if (xhr.status == 200 && xhr.responseText != null && xhr.responseText != '') {
				providerInfo = xhr.responseText;
			}
			if (callback) {
				callback(providerInfo);
			}
		}
	};
	xhr.open('GET', server + '/fmi/webd/oauthapi/oauthproviderinfo', true);
	xhr.send();
}

/**
 * Where FMS should send the user/popup once the IdP handshake is done.
 * Popup mode: our landing page on webDNS (writes localStorage; parent hears storage event).
 * Full-page mode: this page's own URL on webDNS (result arrives in the query string).
 */
function getOAuthReturnUrl() {
	if (OAUTH_CONFIG.useFullPageRedirect) {
		return window.location.href.split('#')[0];
	}
	return 'https://' + OAUTH_CONFIG.webDNS + '/oauth-landing.html';
}

function getOAuthURL(trackingId, fmsDNS, provider, callback) {
	var xhr, queryStr;
	var fmsUrl = 'https://' + fmsDNS;
	xhr = new XMLHttpRequest();
	xhr.onreadystatechange = function () {
		if (xhr.readyState == 4) {
			if (callback) {
				if (xhr.status == 200 && xhr.responseText != null && xhr.responseText != '') {
					callback(xhr.responseText, xhr.getResponseHeader('X-FMS-Request-ID'));
				} else {
					callback(null, null);
				}
			}
		}
	};
	queryStr = 'trackingID=' + trackingId + '&provider=' + provider + '&address=' + fmsDNS + '&X-FMS-OAuth-AuthType=2';
	xhr.open('GET', fmsUrl + '/fmi/webd/oauthapi/getoauthurl?' + queryStr, true);
	xhr.setRequestHeader('X-FMS-Application-Type', '8');
	xhr.setRequestHeader('X-FMS-Return-URL', getOAuthReturnUrl());
	xhr.send();
}

function doOAuthLogin(dbName, requestId, identifier, homeurl, autherr, fmsDNS) {
	var form, node, queryStr;
	var server = 'https://' + fmsDNS;

	form = document.createElement('form');
	form.style.display = 'none';
	form.action = server + '/fmi/webd/' + encodeURIComponent(dbName);
	form.method = 'POST';
	form.target = '_self';

	node = document.createElement('input');
	node.type = 'text';
	node.name = 'user';
	node.value = requestId;
	form.appendChild(node.cloneNode());

	node = document.createElement('input');
	node.type = 'text';
	node.name = 'pwd';
	node.value = identifier;
	form.appendChild(node.cloneNode());

	queryStr = 'lgcnt=1&oauth=1';
	if (homeurl != '') {
		queryStr += ('&homeurl=' + homeurl);
	}
	if (autherr != '') {
		queryStr += ('&autherr=' + autherr);
	}

	if (queryStr != '') {
		form.action += ('?' + queryStr);
	}

	document.body.appendChild(form);
	form.submit();
	document.body.removeChild(form);
}
```

- [ ] **Step 2: Verify every FMS endpoint is absolute and the return URL targets webDNS**

Run:
```bash
grep -nE "oauthapi|/fmi/webd/'|X-FMS-Return-URL|getOAuthReturnUrl|oauth-landing" assets/js/oauth-utility-edit.js
```
Expected: the two `oauthapi` calls and the login form action are all prefixed with `https://` (via `server`/`fmsUrl`); `X-FMS-Return-URL` is set from `getOAuthReturnUrl()`; the popup branch returns `'https://' + OAUTH_CONFIG.webDNS + '/oauth-landing.html'`.

- [ ] **Step 3: Verify no relative FMS path leaks** (the sibling's `'/fmi/webd/oauthapi'` with a leading slash would be wrong here)

Run:
```bash
grep -nE "open\('GET', '/fmi|action = '/fmi" assets/js/oauth-utility-edit.js || echo "OK: no relative FMS URLs"
```
Expected: `OK: no relative FMS URLs`.

- [ ] **Step 4: Commit**

```bash
git add assets/js/oauth-utility-edit.js
git commit -m "Rewrite oauth-utility-edit.js: absolute URLs + webDNS return-URL helper"
```

---

## Task 3: Create oauth-flow.js (mode-aware flow + helpers)

**Files:**
- Create: `assets/js/oauth-flow.js`

Ports the sibling's flow logic, with one adaptation: `runOAuthLogin` uses `OAUTH_CONFIG.fmsDNS` as the API host (the sibling used `window.location.hostname` because it was served by FMS).

- [ ] **Step 1: Create `assets/js/oauth-flow.js`**

```js
/**
 * Mode-aware OAuth flow shared by the page glue (oauth-index.js).
 * Popup mode: open a popup, let oauth-landing.html (on webDNS) write localStorage,
 *   hear the storage event in this window.
 * Full-page mode: redirect this tab to the IdP, save the request id in sessionStorage,
 *   resume from the query string when FMS returns the tab to this page.
 */

var OAUTH_DEMO_TRACKING_ID = '123432';
var OAUTH_STORAGE_KEY = 'oauth-response';
var OAUTH_SESSION_PENDING = 'oauth-pending';
var OAUTH_SESSION_TRACKING = 'oauth-tracking-id';
var OAUTH_SESSION_REQUEST = 'oauth-request-id';

function getOAuthResponseParameter(input, parameter) {
	if (input != null) {
		var params, pair, i;

		params = input.split('&');
		for (i = 0; i < params.length; i++) {
			pair = params[i].split('=');
			if (pair != null && pair.length == 2) {
				if (pair[0] == parameter) {
					return pair[1];
				}
			}
		}
	}
	return '';
}

function useFullPageRedirect() {
	return typeof OAUTH_CONFIG !== 'undefined' && OAUTH_CONFIG.useFullPageRedirect;
}

function clearOAuthSessionState() {
	sessionStorage.removeItem(OAUTH_SESSION_PENDING);
	sessionStorage.removeItem(OAUTH_SESSION_TRACKING);
	sessionStorage.removeItem(OAUTH_SESSION_REQUEST);
}

function getOAuthResponseFromLocation() {
	var search, params;

	if (!useFullPageRedirect()) {
		return null;
	}

	search = window.location.search;
	if (!search || search.length < 2) {
		return null;
	}

	params = search.substring(1);
	if (getOAuthResponseParameter(params, 'trackingID') && getOAuthResponseParameter(params, 'identifier')) {
		return params;
	}

	return null;
}

function stripOAuthParamsFromUrl() {
	if (!window.history || !window.history.replaceState) {
		return;
	}
	window.history.replaceState(null, '', window.location.pathname + window.location.hash);
}

function saveOAuthSessionState(trackingId, requestId) {
	sessionStorage.setItem(OAUTH_SESSION_PENDING, '1');
	sessionStorage.setItem(OAUTH_SESSION_TRACKING, trackingId);
	sessionStorage.setItem(OAUTH_SESSION_REQUEST, requestId);
}

function tryCompleteOAuthResponse(response, trackingId, requestId, onComplete) {
	if (!response || !onComplete) {
		return false;
	}

	var retTrackingId = getOAuthResponseParameter(response, 'trackingID');
	if (trackingId !== retTrackingId) {
		return false;
	}

	localStorage.removeItem(OAUTH_STORAGE_KEY);
	clearOAuthSessionState();
	onComplete(
		getOAuthResponseParameter(response, 'identifier'),
		getOAuthResponseParameter(response, 'error'),
		requestId
	);
	return true;
}

function resumeOAuthAfterRedirect(onComplete) {
	var trackingId, requestId, response;

	if (!useFullPageRedirect() || !onComplete) {
		return false;
	}

	response = localStorage.getItem(OAUTH_STORAGE_KEY) || getOAuthResponseFromLocation();
	if (!response) {
		return false;
	}

	requestId = sessionStorage.getItem(OAUTH_SESSION_REQUEST);
	if (!requestId) {
		return false;
	}

	trackingId = sessionStorage.getItem(OAUTH_SESSION_TRACKING);
	if (!trackingId) {
		trackingId = getOAuthResponseParameter(response, 'trackingID');
	}

	if (tryCompleteOAuthResponse(response, trackingId, requestId, onComplete)) {
		stripOAuthParamsFromUrl();
		return true;
	}

	return false;
}

function listenForOAuthPopupResponse(trackingId, requestId, onComplete) {
	function processOAuthResponse(event) {
		if (event.key && event.key !== OAUTH_STORAGE_KEY) {
			return;
		}
		tryCompleteOAuthResponse(event.newValue, trackingId, requestId, onComplete);
	}

	window.addEventListener('storage', processOAuthResponse);
}

function runOAuthLogin(providerName, onComplete) {
	var trackingId = OAUTH_DEMO_TRACKING_ID;
	var fmsDNS = OAUTH_CONFIG.fmsDNS;
	var child = null;

	if (!useFullPageRedirect()) {
		child = window.open('', 'OAuth', 'width=800, height=600');
	}

	getOAuthURL(trackingId, fmsDNS, providerName, function (oauthUrl, requestId) {
		if (!oauthUrl) {
			alert('Could not start OAuth login. Check FileMaker Server OAuth configuration and try again.');
			if (child && !child.closed) {
				child.close();
			}
			return;
		}

		if (useFullPageRedirect()) {
			saveOAuthSessionState(trackingId, requestId);
			window.location.replace(oauthUrl);
			return;
		}

		child.location.replace(oauthUrl);
		listenForOAuthPopupResponse(trackingId, requestId, onComplete);
	});
}

function getIdentityProviderName() {
	if (typeof OAUTH_CONFIG !== 'undefined' && OAUTH_CONFIG.identityProvider) {
		return OAUTH_CONFIG.identityProvider;
	}
	return 'Microsoft';
}

function shouldAutoStartOAuth() {
	return typeof OAUTH_CONFIG !== 'undefined' && OAUTH_CONFIG.autoStartOAuth;
}
```

- [ ] **Step 2: Verify the API host comes from config, not the page hostname**

Run:
```bash
grep -nE "OAUTH_CONFIG.fmsDNS|window.location.hostname" assets/js/oauth-flow.js
```
Expected: `runOAuthLogin` sets `fmsDNS = OAUTH_CONFIG.fmsDNS`; there is **no** `window.location.hostname` (that was the FMS-hosted sibling's assumption).

- [ ] **Step 3: Verify the popup is opened before the async getOAuthURL call**

Run:
```bash
grep -nE "window.open|getOAuthURL\(" assets/js/oauth-flow.js
```
Expected: the `window.open(...)` line appears **before** the `getOAuthURL(` line. (Opening the popup synchronously on the click avoids browser popup-blockers; opening it inside the XHR callback would be blocked.)

- [ ] **Step 4: Commit**

```bash
git add assets/js/oauth-flow.js
git commit -m "Add oauth-flow.js: popup + full-page redirect modes, resume logic"
```

---

## Task 4: Create oauth-index.js (page glue)

**Files:**
- Create: `assets/js/oauth-index.js`

- [ ] **Step 1: Create `assets/js/oauth-index.js`**

```js
/**
 * Page glue for index.html: set logging, resume a full-page redirect if we are
 * returning from the IdP, otherwise render the Member Login button. Completes the
 * login by POSTing to FileMaker Server (fmsDNS) and sending the user home on webDNS.
 */

function completeIndexOAuth(identifier, autherr, requestId) {
	doOAuthLogin(
		OAUTH_CONFIG.dbName,
		requestId,
		identifier,
		'https://' + OAUTH_CONFIG.webDNS + '/index.html',
		autherr,
		OAUTH_CONFIG.fmsDNS
	);
}

function showOAuthLogin(providerName) {
	runOAuthLogin(providerName, completeIndexOAuth);
}

function initOAuth() {
	log.setLevel(OAUTH_CONFIG.logLevel);
	log.debug('config:', OAUTH_CONFIG);

	if (resumeOAuthAfterRedirect(completeIndexOAuth)) {
		return;
	}

	getProviderInfo(OAUTH_CONFIG.fmsDNS, function (providerInfo) {
		if (providerInfo != null && providerInfo != '') {
			var button = document.createElement('button');
			var oauthWrapper = document.getElementById('inner');
			var providerName = getIdentityProviderName();

			button.innerHTML = 'Member Login';
			button.style.width = '350px';
			button.style.height = '60px';
			button.style.textAlign = 'center';
			button.dataset.provider = providerInfo;
			button.onclick = function () {
				showOAuthLogin(providerName);
			};

			oauthWrapper.appendChild(button);

			if (shouldAutoStartOAuth()) {
				showOAuthLogin(providerName);
			}
		}
	});
}
```

- [ ] **Step 2: Verify completeIndexOAuth passes both webDNS (homeurl) and fmsDNS (POST host)**

Run:
```bash
grep -nE "OAUTH_CONFIG.webDNS|OAUTH_CONFIG.fmsDNS|OAUTH_CONFIG.dbName" assets/js/oauth-index.js
```
Expected: `completeIndexOAuth` references `OAUTH_CONFIG.dbName`, `OAUTH_CONFIG.webDNS` (in the homeurl), and `OAUTH_CONFIG.fmsDNS` (last arg to `doOAuthLogin`); `initOAuth` passes `OAUTH_CONFIG.fmsDNS` to `getProviderInfo`.

- [ ] **Step 3: Verify the doOAuthLogin call's argument order matches its definition**

The signature is `doOAuthLogin(dbName, requestId, identifier, homeurl, autherr, fmsDNS)`. Confirm the call passes them in that order: `dbName`, `requestId`, `identifier`, `'https://'+webDNS+'/index.html'`, `autherr`, `fmsDNS`.

Run:
```bash
grep -nA7 "doOAuthLogin(" assets/js/oauth-index.js
```
Expected: arguments in the order above (homeurl before autherr, fmsDNS last).

- [ ] **Step 4: Commit**

```bash
git add assets/js/oauth-index.js
git commit -m "Add oauth-index.js: init, button, and login completion glue"
```

---

## Task 5: Rewrite index.html to load the JS files (remove inline logic)

**Files:**
- Modify (rewrite `<head>` script + script tags): `index.html`

- [ ] **Step 1: Replace the entire `index.html`** with markup-only + script tags

```html
<!DOCTYPE HTML>
<!--
	Photon by HTML5 UP
	html5up.net | @ajlkn
	Free for personal and commercial use under the CCA 3.0 license (html5up.net/license)
-->
<html>

<head>
	<title>Photon by HTML5 UP</title>
	<meta charset="utf-8" />
	<meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no" />
	<link rel="stylesheet" href="assets/css/main.css" />
	<noscript>
		<link rel="stylesheet" href="assets/css/noscript.css" />
	</noscript>
	<script src="https://unpkg.com/loglevel/dist/loglevel.min.js"></script>
</head>

<body class="is-preload" onload="initOAuth()">

	<!-- Header -->
	<section id="header">
		<div id="inner" class="inner">
			<span class="icon solid major fa-cloud"></span>
			<h1>Soliant Consulting's Cool Demo</h1>
			<br>The button below uses the Claris JS utility to start the OAuth login process into WebDirect.</br></p>
		</div>
	</section>

	<!-- One -->
	<section id="one" class="main style1">
		<div class="container">
			<div class="row gtr-150">
				<div class="col-6 col-12-medium">
					<header class="major">
						<h2>Lorem ipsum dolor adipiscing<br />
							amet dolor consequat</h2>
					</header>
					<p>Adipiscing a commodo ante nunc accumsan et interdum mi ante adipiscing. A nunc lobortis non nisl amet vis
						sed volutpat aclacus nascetur ac non. Lorem curae et ante amet sapien sed tempus adipiscing id accumsan.</p>
				</div>
			</div>
		</div>
	</section>

	<!-- Footer -->
	<section id="footer">
		<ul class="icons">
			<li><a href="#" class="icon brands alt fa-twitter"><span class="label">Twitter</span></a></li>
			<li><a href="#" class="icon brands alt fa-facebook-f"><span class="label">Facebook</span></a></li>
			<li><a href="#" class="icon brands alt fa-instagram"><span class="label">Instagram</span></a></li>
			<li><a href="#" class="icon brands alt fa-github"><span class="label">GitHub</span></a></li>
			<li><a href="#" class="icon solid alt fa-envelope"><span class="label">Email</span></a></li>
		</ul>
		<ul class="copyright">
			<li>&copy; Untitled</li>
			<li>Design: <a href="http://html5up.net">HTML5 UP</a></li>
		</ul>
	</section>

	<!-- Scripts -->
	<script src="assets/js/jquery.min.js"></script>
	<script src="assets/js/jquery.scrolly.min.js"></script>
	<script src="assets/js/browser.min.js"></script>
	<script src="assets/js/breakpoints.min.js"></script>
	<script src="assets/js/util.js"></script>
	<script src="assets/js/main.js"></script>
	<script src="assets/js/oauth-config.js"></script>
	<script src="assets/js/oauth-utility-edit.js"></script>
	<script src="assets/js/oauth-flow.js"></script>
	<script src="assets/js/oauth-index.js"></script>

</body>

</html>
```

- [ ] **Step 2: Verify no inline OAuth logic remains and load order is correct**

Run:
```bash
grep -nE "var dbName|var fmsDNS|var thisDNS|function initOAuth|function showOAuthLogin|OauthProvider" index.html || echo "OK: no inline OAuth logic"
```
Expected: `OK: no inline OAuth logic`.

Run:
```bash
grep -nE "oauth-config.js|oauth-utility-edit.js|oauth-flow.js|oauth-index.js" index.html
```
Expected: four `<script>` tags in this order — `oauth-config.js`, then `oauth-utility-edit.js`, then `oauth-flow.js`, then `oauth-index.js` (config must load first; index glue last). loglevel must load in `<head>` before any of them.

- [ ] **Step 3: Commit**

```bash
git add index.html
git commit -m "Rewrite index.html: load OAuth JS files, remove inline logic"
```

---

## Task 6: Delete legacy custom.html

**Files:**
- Delete: `custom.html`

- [ ] **Step 1: Confirm custom.html is tracked, then remove it**

Run:
```bash
git rm custom.html
```
Expected: `rm 'custom.html'`.

- [ ] **Step 2: Verify nothing references it**

Run:
```bash
grep -rn "custom.html" --include=*.html --include=*.js --include=*.txt . || echo "OK: no references to custom.html"
```
Expected: `OK: no references to custom.html`.

- [ ] **Step 3: Commit**

```bash
git commit -m "Delete legacy custom.html (divergent inlined example)"
```

---

## Task 7: Rewrite README.txt (config docs, modes, ASCII diagrams, version refs)

**Files:**
- Modify (rewrite): `README.txt`

- [ ] **Step 1: Replace `README.txt`** with the following (keep the HTML5 UP / Photon credits block at the bottom unchanged from the original)

```text
This sample website shows how you can start the OAuth login flow into a WebDirect file,
right from your own web site, without taking the user to the WebDirect launch center or
the WebDirect file's login screen.

This version is for a web site that does NOT run on FileMaker Server. The web server
(webDNS) and the FileMaker Server (fmsDNS) are two different boxes. It requires no HTML or
JS files to be installed on FileMaker Server.

It targets the FileMaker Server release where Claris fixed X-FMS-Return-URL so that FMS can
return the OAuth result to a cross-origin URL on your own web server. That fix is what makes
the popup flow below work when the files are hosted off-server.

Which repo do I use?
--------------------
- This repo: web site on a separate server, modern FileMaker Server (X-FMS-Return-URL fix).
- Web site hosted ON FileMaker Server: https://github.com/wimdecorte/fms-webd-oauth-local
- Older FileMaker Server (2025 / FMS22 or earlier), web site on a separate server:
    https://github.com/wimdecorte/fms-webd-oauth-remote
  That older setup also needs a companion that MUST run on the FileMaker Server box:
    https://github.com/wimdecorte/fms-webd-oauth-remote-companion
  The companion is required because pre-fix FMS could not return cross-origin, so a helper
  on the FMS origin was needed to relay the OAuth result back to the remote web site.

This functionality already exists for logging in with regular FileMaker accounts, see:
https://github.com/bharlow/fm-webdirect-custom

Configuration (assets/js/oauth-config.js)
------------------------------------------
This demo is static HTML and JavaScript; the browser cannot read a .env file. Copy
assets/js/oauth-config.example.js to assets/js/oauth-config.js and edit the values:

  dbName              Published WebDirect file name to open after OAuth (no .fmp12).
  fmsDNS              FileMaker Server box. Target of all API calls and the login POST.
  webDNS              This web server box. Used for X-FMS-Return-URL and the home URL.
  identityProvider    Provider name passed to getOAuthURL (must match the FMS OAuth config).
  autoStartOAuth      When true, OAuth starts as soon as provider info loads. The Member
                      Login button still shows for manual retry.
  useFullPageRedirect Switch between popup (false, default) and full-page redirect (true).
  logLevel            loglevel verbosity: trace | debug | info | warn | error | silent.

The two modes (useFullPageRedirect)
-----------------------------------
Both modes run the same OAuth: getOAuthURL on FileMaker Server, the user signs in at the
identity provider, and FileMaker Server completes the handshake. They differ only in WHERE
FMS sends the result, set via X-FMS-Return-URL on the getOAuthURL call (see
assets/js/oauth-utility-edit.js, getOAuthReturnUrl).

  false (default) - POPUP MODE
    X-FMS-Return-URL = https://<webDNS>/oauth-landing.html
    The index page stays open and opens a popup for the IdP login. When FMS returns the
    popup to oauth-landing.html (same origin as the index page, on webDNS), that page writes
    the result to localStorage and the index page hears the "storage" event.

  true - FULL-PAGE MODE
    X-FMS-Return-URL = the index page's own URL on webDNS
    The index tab itself navigates to the IdP (no popup). The request id is saved in
    sessionStorage first. FMS returns the tab to the index URL with the result in the query
    string; resumeOAuthAfterRedirect reads it and completes the login, then the query string
    is stripped from the address bar.

Popup mode flow
---------------
  Browser (webDNS)                 FileMaker Server (fmsDNS)        Identity Provider
  ----------------                 -------------------------        -----------------
  index.html onload
    |
    | getProviderInfo ------------------> /oauthapi/oauthproviderinfo
    | (Member Login button)
    |
    | click -> open popup
    | getOAuthURL ----------------------> /oauthapi/getoauthurl
    |   X-FMS-Return-URL =                  (returns oauthUrl + X-FMS-Request-ID)
    |   https://<webDNS>/oauth-landing.html
    |
    | popup -> oauthUrl ------------------------------------------------> IdP login
    |                                                                        |
    |                                     <-- FMS finishes handshake <-------+
    |                                       redirects popup to
    |   popup lands on  <---------------- https://<webDNS>/oauth-landing.html
    |   oauth-landing.html (webDNS)
    |     writes localStorage 'oauth-response', closes popup
    |
    | index hears "storage" event (same origin)
    | doOAuthLogin --------------------> POST /fmi/webd/<dbName>  (user=requestId, pwd=identifier)
    |                                      -> WebDirect session opens (homeurl on webDNS)

Full-page mode flow
-------------------
  Browser (webDNS)                 FileMaker Server (fmsDNS)        Identity Provider
  ----------------                 -------------------------        -----------------
  index.html onload
    |
    | getProviderInfo ------------------> /oauthapi/oauthproviderinfo
    | (Member Login button)
    |
    | click
    | getOAuthURL ----------------------> /oauthapi/getoauthurl
    |   X-FMS-Return-URL =                  (returns oauthUrl + X-FMS-Request-ID)
    |   https://<webDNS>/index.html
    | save requestId -> sessionStorage
    |
    | this TAB -> oauthUrl ---------------------------------------------> IdP login
    |                                                                        |
    |                                     <-- FMS finishes handshake <-------+
    |                                       redirects tab to
    | tab returns to  <----------------- https://<webDNS>/index.html?trackingID=...&identifier=...
    |   index.html (webDNS)
    |   initOAuth -> resumeOAuthAfterRedirect reads query string + sessionStorage requestId
    | doOAuthLogin --------------------> POST /fmi/webd/<dbName>  (user=requestId, pwd=identifier)
    | strip query string from URL          -> WebDirect session opens (homeurl on webDNS)

Enjoy!

Wim Decorte
Soliant Consulting Inc.


--- website provided by Photon by HTML5 UP
html5up.net | @ajlkn
Free for personal and commercial use under the CCA 3.0 license (html5up.net/license)


A simple (gradient-heavy) single pager that revisits a style I messed with on two
previous designs (Tessellate and Telephasic). Fully responsive, built on Sass,
and, as usual, loaded with an assortment of pre-styled elements. Have fun! :)

Demo images* courtesy of Unsplash, a radtastic collection of CC0 (public domain) images
you can use for pretty much whatever.

(* = Not included)

Feedback, bug reports, and comments are not only welcome, but strongly encouraged :)

AJ
aj@lkn.io | @ajlkn


Credits:

	Demo Images:
		Unsplash (unsplash.com)

	Icons:
		Font Awesome (fontawesome.io)

	Other:
		jQuery (jquery.com)
		Responsive Tools (github.com/ajlkn/responsive-tools)
```

- [ ] **Step 2: Verify all required references and both diagrams are present**

Run:
```bash
grep -cE "fms-webd-oauth-remote-companion|fms-webd-oauth-remote\b|fms-webd-oauth-local" README.txt
grep -nE "Popup mode flow|Full-page mode flow" README.txt
```
Expected: first command finds all three repo references; second finds both diagram headers.

- [ ] **Step 3: Commit**

```bash
git add README.txt
git commit -m "Rewrite README.txt: config, two modes, ASCII flow diagrams, version refs"
```

---

## Task 8: Manual end-to-end verification (requires live servers)

> Not a code task — run when a real `webDNS` host, `fmsDNS` (FileMaker Server with OAuth + a published `OAuth_tester` file), and IdP are available. These cannot be automated here. If servers are not available now, record this task as deferred.

**Files:** none (configuration + browser).

- [ ] **Step 1:** In `assets/js/oauth-config.js`, set `fmsDNS`, `webDNS`, `identityProvider`, `dbName` to the live values. Serve the repo over HTTPS from `webDNS` (the podman/nginx container in the next phase will do this).

- [ ] **Step 2: Popup mode.** With `useFullPageRedirect: false`, open `https://<webDNS>/index.html`. Click Member Login. Expected: a popup opens, you authenticate at the IdP, the popup lands on `oauth-landing.html` and closes, and the main tab logs into WebDirect. In DevTools, confirm the `getoauthurl` request carried `X-FMS-Return-URL: https://<webDNS>/oauth-landing.html`.

- [ ] **Step 3: Full-page mode.** Set `useFullPageRedirect: true`, reload. Click Member Login. Expected: the same tab navigates to the IdP (no popup), returns to `index.html` with `?trackingID=...&identifier=...`, logs into WebDirect, and the query string is stripped from the address bar.

- [ ] **Step 4: autoStartOAuth.** Set `autoStartOAuth: true`, reload. Expected: OAuth begins automatically once provider info loads, without clicking the button.

- [ ] **Step 5:** Record results (pass/fail per mode + any FMS/IdP config notes) in the PR or a follow-up note.

---

## Self-Review notes (for the implementer)

- **Spec coverage:** config object (Task 1), absolute URLs + return-URL helper (Task 2), feature-flag flow + ported fixes null-guard/`===` (Task 3), page glue with `webDNS` homeurl + `fmsDNS` POST (Task 4), inline-logic removal (Task 5), `custom.html` deletion (Task 6), README cleanup + both ASCII diagrams + older-FMS sibling refs (Task 7), manual flow check (Task 8). The `postMessage`/`identifier.html` path and the podman/nginx container are intentionally out of scope per the spec.
- **Type/name consistency:** `doOAuthLogin(dbName, requestId, identifier, homeurl, autherr, fmsDNS)` is defined in Task 2 and called with that exact arg order in Task 4. `getOAuthReturnUrl()` (Task 2) reads `OAUTH_CONFIG.useFullPageRedirect`; `useFullPageRedirect()` (Task 3) is the flow-side accessor of the same flag — distinct names, intentional. `OAUTH_CONFIG` keys used across tasks match Task 1 exactly.
