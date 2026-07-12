# Configuring FileMaker Server for a remote OAuth login page

When the login page lives on your **own** web server (`webDNS`) instead of on the
FileMaker Server (`fmsDNS`), the browser treats the calls the page makes to FMS as
**cross-origin** — even when both hosts share a top-level domain (e.g. `web.ets.fm`
calling `fms.ets.fm`). FileMaker Server must be told to allow this. There are two
server-side changes:

1. **CORS policy** in the FMS nginx config, so the browser is allowed to make the
   `oauthproviderinfo` / `getoauthurl` calls cross-origin and read the response headers.
2. **Custom Home URL** in the FMS Admin Console, so FMS will honor a return URL that points
   back at your web server.

> These instructions were originally published (as screenshots) at
> <https://www.soliantconsulting.com/blog/seamless-oauth-login-webdirect-website/>
> and are transcribed here as text.

> **OS note.** This applies to FileMaker Server on **Ubuntu 22**, which uses **nginx**.
> On Ubuntu 18 and macOS, FMS uses **Apache** instead, and these files/steps do not apply.
> Line numbers below are from one specific FMS build and will differ across versions —
> match on the surrounding comments, not the line numbers.

---

## Quick start (recommended, end-to-end)

Do these **in order** on the FileMaker Server host (Ubuntu 22, FMS **26.1.1.15+**). The order
matters: the script's default mode reads the allowed domains *from* FMS, so **FMS must be
configured first**.

1. **Configure the OAuth Allow List in the Admin Console — do this first.**
   Admin Console → **Administration → External Authentication → OAuth Allow List** →
   **Change**. Enable it and add each web origin that will host a login page — the `webDNS`
   host(s), e.g. `wim.ets.fm` (add `site.ets.fm` too if several sites share this server). Save.
   *(This is the list the script reads in step 3. If it is empty or disabled, the script stops
   and tells you to do this first.)*

2. **Set the Custom Home URL** (the WebDirect post-login return).
   Admin Console → **Connectors → Web Publishing** → **Claris FileMaker WebDirect** →
   **Custom Home URL** → **Change** → enter `https://<webDNS>` and save. See [section 2](#2-allow-the-webdirect-home-url).

3. **Patch the nginx CORS policy** — copy [`scripts/patch-fms-nginx-cors.sh`](../scripts/patch-fms-nginx-cors.sh)
   to the box and run it. With no arguments it defaults to `--from-fms`, deriving the CORS
   allowlist from what you set in step 1:
   ```bash
   sudo ./patch-fms-nginx-cors.sh --dry-run     # preview the change first
   sudo ./patch-fms-nginx-cors.sh               # apply (defaults to --from-fms)
   ```

4. **Syntax-check nginx** (the script can do it; see [Check the syntax](#check-the-syntax) for why
   the passphrase handling is fiddly):
   ```bash
   # custom cert whose key has NO passphrase (common): pass an empty string
   sudo ./patch-fms-nginx-cors.sh --nginx-test --passphrase ''
   # key WITH a passphrase: pass it
   sudo ./patch-fms-nginx-cors.sh --nginx-test --passphrase 'YOUR_SSL_PASSPHRASE'
   ```

5. **Restart the web server** to make the config live (needs Admin Console credentials):
   ```bash
   fmsadmin restart httpserver
   ```

6. **Enable WebDirect** if it isn't already (Admin Console → Connectors → Web Publishing) — the
   OAuth endpoints return `502` until it is up. Then load your page on `webDNS` and sign in.

> **When FMS regenerates the config** (on upgrade, and sometimes on restart) the CORS block
> reverts to stock. Just re-run step 3 — the script is idempotent and safe to run any time.
> If you later change the OAuth Allow List (step 1), re-run step 3 so nginx matches.

The rest of this document explains each piece in detail, plus a by-hand alternative and
troubleshooting.

---

## 1. CORS policy in the FMS nginx config

Config file:

```
/opt/FileMaker/FileMaker Server/NginxServer/conf/fms_nginx.conf
```

### Automated: use the script

If you would rather not hand-edit, run
[`scripts/patch-fms-nginx-cors.sh`](../scripts/patch-fms-nginx-cors.sh) **on the FileMaker Server
host**. Copy the script to the box, then:

```bash
# Recommended: derive CORS allowlist from the FMS OAuth Allow List (default)
sudo ./patch-fms-nginx-cors.sh --from-fms
# preview first with:  sudo ./patch-fms-nginx-cors.sh --dry-run --from-fms

# Or specify a single origin:
sudo ./patch-fms-nginx-cors.sh https://<webDNS>      # e.g. https://wim.ets.fm

# Or wildcard (demo only):
sudo ./patch-fms-nginx-cors.sh '*'
```

It applies the CORS edit described below — in **both** `server` blocks, with `always` on every
line — backs up the original, is **idempotent** (re-run any time FMS regenerates the config on
upgrade), and prints the `nginx -t` / `fmsadmin restart httpserver` commands to finish.

To also run the syntax check, add `--nginx-test` and supply the SSL key passphrase (needed because
nginx reads it from a FIFO — see [Check the syntax](#check-the-syntax) below):

```bash
# key WITH a passphrase:
sudo ./patch-fms-nginx-cors.sh --from-fms --nginx-test --passphrase 'YOUR_SSL_PASSPHRASE'
# key with NO passphrase (e.g. a deployed custom cert) — pass an EMPTY string:
sudo ./patch-fms-nginx-cors.sh --from-fms --nginx-test --passphrase ''
# (or export FMS_SSL_PASSPHRASE=... beforehand instead of --passphrase)
```

`--passphrase ''` (empty) is a real value: it feeds an empty line to the FIFO, which is what a
no-passphrase key expects. **Omitting** `--passphrase` entirely is different — the script then
skips the check (so it can't hang) and prints the manual command instead.

It deliberately does **not** touch the SSL certificate/key or the port-80 include (those are
environment-specific to a custom-cert setup, not to this OAuth flow), and it does **not** set the
Custom Home URL — section 2 below is still a manual Admin Console step.

#### Allowing multiple web origins

Starting with FileMaker Server 26.1.1.15, the FMS Admin Console supports an **OAuth Allow List**
(External Authentication → OAuth Allow List) that accepts multiple allowed domains for programmatic
OAuth / `X-FMS-Return-URL` requests. On the box this is stored in
`/fms/Data/Preferences/dbs_config.xml` as `OAuthDomainName` (comma-separated hostnames) and
`OAuthAllowList` (0/1 toggle).

The script's **`--from-fms`** mode (the default when no arguments given) reads this list and
generates an nginx `map` block that echoes the request `Origin` header back only when it exactly
matches an allowlisted value — the standard nginx idiom for multi-origin CORS. Because FMS and nginx
now derive from the same source, they cannot silently drift; changing domains in Admin Console means
re-running `--from-fms` to update the nginx side.

**How it works:**

The `Access-Control-Allow-Origin` (ACAO) header holds exactly one value, or `*` — never a space or
comma list. To allow *several specific origins*, nginx uses a `map` that sets a variable based on
the incoming `Origin` request header:

```nginx
map $http_origin $fms_cors_allow_origin {
    default        "";
    "https://wim.ets.fm"   "https://wim.ets.fm";
    "https://site.ets.fm"  "https://site.ets.fm";
}
```

The server blocks then reference `$fms_cors_allow_origin` instead of a static value:

```nginx
add_header 'Access-Control-Allow-Origin' $fms_cors_allow_origin always;
```

When the browser's `Origin` is `https://wim.ets.fm`, nginx echoes it back; when it's
`https://evil.example.com`, the map's `default ""` means the ACAO header is omitted entirely, and
the browser blocks the response — the correct deny behavior.

The two layers (FMS's OAuth return-URL authorization and nginx's CORS browser gate) are enforced
independently. If you must CORS-allow an origin FMS does not, use `--allow-origin` to union both
sources; if you want them fully separate, skip `--from-fms` and supply origins manually. For the
common case — one web origin or several all known to FMS — `--from-fms` keeps the layers in sync.

For design details see
[`docs/superpowers/specs/2026-07-12-cors-multi-origin-allowlist-design.md`](superpowers/specs/2026-07-12-cors-multi-origin-allowlist-design.md).

The rest of this section documents the same change by hand.

### Stop the web server first

```bash
fmsadmin stop httpserver
```

### Find the CORS block

Open the file and scroll to the `server { ... }` block that listens on port **443**. A few
lines down, under the comment `# Add headers for Cross-Origin Resource Sharing (CORS)
policies`, is the default CORS policy.

**Default (before):**

```nginx
server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;

  index index.html index.htm index.nginx-debian.html;

  add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

  # Prevent Clickjacking attack
  add_header X-Frame-Options "SAMEORIGIN";

  # Prevent cross-site scripting (XSS) attack
  add_header X-XSS-Protection "1; mode=block";

  add_header X-Content-Type-Options nosniff;

  # add_header Content-Security-Policy "script-src 'self' 'unsafe-inline' 'unsafe-eval';" always;

  # Add headers for Cross-Origin Resource Sharing (CORS) policies
  add_header 'Access-Control-Allow-Origin' $hostname;
  add_header 'Access-Control-Allow-Credentials' 'True';
  add_header 'Access-Control-Allow-Headers' 'Content-Type,Authorization';

## below config from httpd mod_proxy conversion
```

Two things make the default too restrictive for a remote page:

- **Line: `Access-Control-Allow-Origin' $hostname`** — restricts access to the FMS host
  itself, so a page served from `webDNS` is refused.
- **`Access-Control-Allow-Headers' 'Content-Type,Authorization'`** — does not list the
  custom `X-FMS-*` headers that the Claris JS utility sends, and there is no
  `Expose-Headers`, so the browser cannot read the `X-FMS-Request-ID` response header the
  login flow needs.

### Change the block to this

**Modified (after):**

```nginx
server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;

  index index.html index.htm index.nginx-debian.html;

  add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

  # Prevent Clickjacking attack
  add_header X-Frame-Options "SAMEORIGIN";

  # Prevent cross-site scripting (XSS) attack
  add_header X-XSS-Protection "1; mode=block";

  add_header X-Content-Type-Options nosniff;

  # add_header Content-Security-Policy "script-src 'self' 'unsafe-inline' 'unsafe-eval';" always;

  # Add headers for Cross-Origin Resource Sharing (CORS) policies
  #add_header 'Access-Control-Allow-Origin' $hostname;
  add_header 'Access-Control-Allow-Origin' '*';
  add_header 'Access-Control-Allow-Credentials' 'True';
  add_header 'Access-Control-Allow-Headers' 'X-FMS-Application-Version,x-fms-application-type,X-FMS-Return-URL,Origin,Content-Type,Authorization';
  #add_header 'Access-Control-Allow-Headers' 'Content-Type,Authorization';
  add_header 'Access-Control-Expose-Headers' 'X-FMS-Request-ID,Content-Type,Authorization,Content-Range' always;

## below config from httpd mod_proxy conversion
```

What changed:

- **`Access-Control-Allow-Origin`** — the original `$hostname` line is commented out and
  replaced with `'*'`. *(For production, make this less permissive than a wildcard — set it
  to your specific `webDNS` origin, or use the script's default `--from-fms` mode to allow the
  exact set of origins from your FMS OAuth Allow List; see [Allowing multiple web
  origins](#allowing-multiple-web-origins).)*
- **`Access-Control-Allow-Headers`** — expanded to include the custom headers the Claris JS
  utility sends: `X-FMS-Application-Version`, `x-fms-application-type`, `X-FMS-Return-URL`,
  and `Origin`. The old two-value line is commented out.
- **`Access-Control-Expose-Headers`** *(new line)* — added so the browser can read the
  `X-FMS-Request-ID` response header (plus `Content-Type`, `Authorization`, `Content-Range`)
  that the login flow depends on.

> **Recommended: add `always` to every CORS line.** In the blog's config only the
> `Expose-Headers` line ends with `always`. Without it, nginx `add_header` applies **only to
> 2xx/3xx responses** — so on a backend error (e.g. a `502` when WebDirect is off) nginx
> strips `Access-Control-Allow-Origin`, and the browser reports a misleading *"No
> 'Access-Control-Allow-Origin' header"* CORS error instead of the real HTTP status. Appending
> `always` to all four lines makes the true error visible in the browser console:
>
> ```nginx
> add_header 'Access-Control-Allow-Origin' '*' always;
> add_header 'Access-Control-Allow-Credentials' 'True' always;
> add_header 'Access-Control-Allow-Headers' 'X-FMS-Application-Version,x-fms-application-type,X-FMS-Return-URL,Origin,Content-Type,Authorization' always;
> add_header 'Access-Control-Expose-Headers' 'X-FMS-Request-ID,Content-Type,Authorization,Content-Range' always;
> ```
>
> See [Troubleshooting](#troubleshooting) for why this matters.

### Check the syntax

FileMaker Server's nginx is separate from any system nginx, so `sudo nginx -t` alone tests
the **wrong** config. Point `-t` at the FMS config explicitly.

You must also feed it the SSL key passphrase, and the way you do that matters. FMS's
`ssl_password_file` is **not a regular file — it is a named pipe (FIFO)**:

```bash
ls -l "/opt/FileMaker/FileMaker Server/CStore/.passphrase"
# prw-rw---- 1 fmserver fmsadmin 0 ... .passphrase   <-- leading 'p' = FIFO
```

`nginx -t` opens that FIFO to read the passphrase and **blocks until something writes to it**.
So a bare `nginx -t` appears to hang forever. The fix is to write the passphrase into the FIFO
from a **backgrounded** command (the trailing `&`) *before* nginx reads it:

```bash
echo "your SSL cert passphrase here" > "/opt/FileMaker/FileMaker Server/CStore/.passphrase" & sudo nginx -t -c "/opt/FileMaker/FileMaker Server/NginxServer/conf/fms_nginx.conf"
```

> **Which passphrase?** Use the passphrase for **whichever certificate FMS is currently
> using** — i.e. the one named by `ssl_certificate` / `ssl_certificate_key` at the top of
> `fms_nginx.conf`. With no custom certificate installed that is FMS's built-in **self-signed**
> cert (`server.pem` / `privateKey.key`); once a custom cert is installed it is
> `serverCustom.pem` / `serverKey.pem`. **If the key has no passphrase** (common for a deployed
> custom cert), there is nothing to type — feed an **empty line** to the FIFO:
>
> ```bash
> ( printf '\n' > "/opt/FileMaker/FileMaker Server/CStore/.passphrase" ) & \
>   sudo nginx -t -c "/opt/FileMaker/FileMaker Server/NginxServer/conf/fms_nginx.conf"
> ```

> The [script](#automated-use-the-script) automates exactly this FIFO-feeding dance when you
> pass `--nginx-test --passphrase '...'` — including `--passphrase ''` for a no-passphrase key.

A successful test prints:

```
nginx: the configuration file /opt/FileMaker/FileMaker Server/NginxServer/conf/fms_nginx.conf syntax is ok
nginx: configuration file /opt/FileMaker/FileMaker Server/NginxServer/conf/fms_nginx.conf test is successful
```

---

## 2. Allow the WebDirect home URL

Set this in the **Admin Console** — there is no longer any need to hand-edit
`jwpc_prefs.xml`:

1. Go to **Connectors → Web Publishing**.
2. Under **Claris FileMaker WebDirect**, find **Custom Home URL** and click **Change**.
3. Enter your web server's origin (`https://webDNS`, e.g. `https://wim.ets.fm`) and save.

This is the return URL FMS will honor after the OAuth handshake — set it to the host
serving your login page.

> **Older FMS versions.** If your Admin Console does not expose **Custom Home URL**, the
> equivalent setting lives in
> `/opt/FileMaker/FileMaker Server/Web Publishing/conf/jwpc_prefs.xml`: set
> `<parameter name="homeurlenabled">yes</parameter>` and list your return URLs
> (comma-separated, including scheme) in `<parameter name="customhomeurl">…</parameter>`.

---

## Restart the web server

After both files are saved and the nginx syntax check passes:

```bash
fmsadmin start httpserver
```

---

## Troubleshooting

### A "CORS error" that is really a `502`

The most common false alarm. The browser console shows something like:

```
Access to XMLHttpRequest at 'https://<fmsDNS>/fmi/webd/oauthapi/oauthproviderinfo'
from origin 'https://<webDNS>' has been blocked by CORS policy:
No 'Access-Control-Allow-Origin' header is present on the requested resource.

GET https://<fmsDNS>/fmi/webd/oauthapi/oauthproviderinfo  net::ERR_FAILED 502 (Bad Gateway)
```

**The `502` is the real error; the CORS message is a side effect.** The `/fmi/webd/oauthapi/*`
endpoints are served by the Web Publishing Engine, which nginx proxies to
`http://127.0.0.1:16021` (the `location /fmi/` block). If that backend is not answering, nginx
returns `502 Bad Gateway` — and because the CORS `add_header` lines lack `always` (see section
1), nginx drops `Access-Control-Allow-Origin` from the error response, so the browser blames
CORS.

Usual cause: **WebDirect is disabled or its machine is unavailable.** Check the Admin Console →
**Connectors → Web Publishing**:

- **FileMaker WebDirect** must be **Enabled**.
- **Primary Machine** must not be **Unavailable**, and connections should be able to open.

Enable WebDirect and wait for the primary machine to come up, then retry.

### Health check from the FMS box

Confirm the endpoint itself before blaming the browser or CORS. On the FileMaker Server host:

```bash
curl -sk -o /dev/null -w "%{http_code}\n" https://<fmsDNS>/fmi/webd/oauthapi/oauthproviderinfo
```

- `200` → the WPE is up; any remaining browser error is genuinely CORS or client-side.
- `502` → the backend is down (WebDirect disabled / machine unavailable) — fix that first.

To see whether the CORS headers are actually being sent (and on error responses too, once you
have added `always`), inspect the headers from a browser on `webDNS`, sending an `Origin`:

```bash
curl -sk -D - -o /dev/null -H "Origin: https://<webDNS>" \
  https://<fmsDNS>/fmi/webd/oauthapi/oauthproviderinfo | grep -i 'access-control'
```

You should see `Access-Control-Allow-Origin` (and the other three lines) in the output.

### If it is a real CORS error

Only after the endpoint returns `200`:

- Make sure you edited **both** `server` blocks (`listen 80` and `listen 443`) — the CORS lines
  must appear in the one actually serving the request.
- Re-run the syntax check and restart `httpserver` (a saved-but-not-reloaded config is a common
  miss).
- Remember `Access-Control-Allow-Credentials: True` combined with `Access-Control-Allow-Origin:
  '*'` is rejected by browsers when the request sends credentials. If you send credentials, set
  a specific origin (`https://<webDNS>`) instead of `*` — which you want for production anyway.

---

## How this relates to this repo

- The client side of the flow — `dbName`, `fmsDNS`, `webDNS`, etc. — is configured in
  [`assets/js/oauth-config.js`](../assets/js/oauth-config.js); see the [README](../README.md).
- The blog notes that changing the **`X-FMS-Return-URL`** header to point at an arbitrary
  host produced an empty `{}` response from FMS in the pre-fix era. That symptom, and what
  actually gates it (`return-URL host == address`), are investigated in detail in
  [`docs/superpowers/findings/2026-06-16-getoauthurl-empty-response-investigation.md`](superpowers/findings/2026-06-16-getoauthurl-empty-response-investigation.md).
