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

Local testing with Podman
--------------------------
A throwaway container (Ubuntu + nginx) serves these files over HTTPS on the webDNS
hostname so the OAuth flow can be tested end to end. It serves files only; it changes
nothing on FileMaker Server.

Build and run:
    ./container/run.sh
This builds the image and runs nginx with the repo mounted read-only, published on port
443, with WEBDNS defaulting to webdlogin.ets.fm. Override the hostname with:
    WEBDNS=my-web-host.example.com ./container/run.sh

Make the hostname resolve to your machine. Add to /etc/hosts (or use real DNS):
    127.0.0.1 webdlogin.ets.fm
Keep webDNS in assets/js/oauth-config.js matching this hostname. Then open:
    https://webdlogin.ets.fm
Edits to the repo files show on a browser refresh (the files are mounted, not baked in).

About the SSL certificate:
    The container generates a self-signed certificate at startup for whatever WEBDNS you
    pass, so the certificate always matches the hostname. Your browser will show a one-time
    "not trusted" warning; accepting it is safe here. Only the browser ever sees this
    certificate: the identity provider redirects to FileMaker Server (fmsDNS), and FileMaker
    Server sends the browser a redirect (302) to the return URL on webDNS — neither the IdP
    nor FileMaker Server validates the webDNS certificate. To avoid the warning entirely,
    mount your own certificate into the container at /etc/nginx/certs (server.crt and
    server.key) and it will be used instead of generating one.

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
