# Podman + nginx Test Container Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a throwaway local container (Ubuntu + nginx, run with Podman) that serves this repo's static files over HTTPS on the configured `webDNS` hostname, so the OAuth flows can be exercised end-to-end.

**Architecture:** Four new files under `container/`. The image is generic (no app files baked in); the repo is volume-mounted into nginx's webroot at run time. TLS uses a self-signed cert generated at container startup from a `WEBDNS` env var, so it matches whatever hostname is configured. Only the browser ever evaluates this cert (the IdP redirects to FMS; FMS returns a 302 to the browser), so a one-time browser warning is the only cost.

**Tech Stack:** Podman 5.x, Ubuntu 24.04 base image, nginx, openssl, bash.

**Reference:** Design spec at [docs/superpowers/specs/2026-06-16-podman-nginx-test-container-design.md](../specs/2026-06-16-podman-nginx-test-container-design.md). Unblocks Task 8 (manual end-to-end verification) of the OAuth port.

---

## Testing approach (read before starting)

No automated test framework applies to a container image. Tasks 1–4 are verified with **static checks** (exact file contents, `bash -n` syntax checks, `grep` guards for the key requirements). Task 5 is a **real build+run smoke test** with `podman` — it is the actual acceptance test and must pass. Task 6 is the README doc update.

Conventions: shell scripts start with `#!/usr/bin/env bash` and `set -euo pipefail` (entrypoint uses `set -e` plus explicit checks since some vars are optional). Indent shell with tabs to match the repo's JS/HTML style. Keep `container/*.sh` executable (`chmod +x`).

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `container/Containerfile` | Create | Ubuntu 24.04 + nginx + openssl; copy template & entrypoint; EXPOSE 443; ENTRYPOINT |
| `container/nginx.conf.template` | Create | One `server` block: 443 ssl, `server_name ${WEBDNS}`, webroot, cert paths, no-store |
| `container/entrypoint.sh` | Create | Generate self-signed cert for `$WEBDNS` if none mounted; render conf; exec nginx |
| `container/run.sh` | Create | Convenience: `podman build` + `podman run` (publish 443, mount repo, pass WEBDNS) |
| `README.txt` | Modify | Add "Local testing with Podman" section (build/run, /etc/hosts, SSL explanation) |

---

## Task 1: Create the nginx config template

**Files:**
- Create: `container/nginx.conf.template`

- [ ] **Step 1: Create `container/nginx.conf.template`** with EXACTLY this content:

```
worker_processes 1;
events { worker_connections 1024; }

http {
	include       /etc/nginx/mime.types;
	default_type  application/octet-stream;
	sendfile      on;

	server {
		listen 443 ssl;
		server_name ${WEBDNS};

		ssl_certificate     /etc/nginx/certs/server.crt;
		ssl_certificate_key /etc/nginx/certs/server.key;

		root /usr/share/nginx/html;
		index index.html;

		# Test container: never cache, so edits to the mounted repo show on refresh.
		add_header Cache-Control "no-store";

		location / {
			try_files $uri $uri/ =404;
		}
	}
}
```

- [ ] **Step 2: Verify the placeholders and key directives are present**

Run:
```bash
grep -nE "server_name \$\{WEBDNS\}|listen 443 ssl|/etc/nginx/certs/server.(crt|key)|/usr/share/nginx/html|no-store" container/nginx.conf.template
```
Expected: matches for `server_name ${WEBDNS}`, `listen 443 ssl`, both cert paths, the webroot, and the no-store header.

- [ ] **Step 3: Commit**

```bash
git add container/nginx.conf.template
git commit -m "Add nginx config template for test container"
```

---

## Task 2: Create the entrypoint script

**Files:**
- Create: `container/entrypoint.sh`

- [ ] **Step 1: Create `container/entrypoint.sh`** with EXACTLY this content:

```bash
#!/usr/bin/env bash
# Test-container entrypoint: ensure a TLS cert exists for $WEBDNS, render the
# nginx config, then run nginx in the foreground.
set -e

WEBDNS="${WEBDNS:-webdlogin.ets.fm}"
CERT_DIR="/etc/nginx/certs"
CERT="${CERT_DIR}/server.crt"
KEY="${CERT_DIR}/server.key"

mkdir -p "${CERT_DIR}"

if [ -f "${CERT}" ] && [ -f "${KEY}" ]; then
	echo "entrypoint: using existing certificate at ${CERT_DIR}"
else
	echo "entrypoint: generating self-signed certificate for ${WEBDNS}"
	openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
		-keyout "${KEY}" -out "${CERT}" \
		-subj "/CN=${WEBDNS}" \
		-addext "subjectAltName=DNS:${WEBDNS}"
fi

export WEBDNS
envsubst '${WEBDNS}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

echo "entrypoint: serving https://${WEBDNS} (server_name ${WEBDNS})"
exec nginx -g 'daemon off;'
```

- [ ] **Step 2: Make it executable and syntax-check it**

Run:
```bash
chmod +x container/entrypoint.sh
bash -n container/entrypoint.sh && echo "syntax OK"
```
Expected: `syntax OK`.

- [ ] **Step 3: Verify the cert-reuse guard and envsubst rendering are present**

Run:
```bash
grep -nE "WEBDNS:-webdlogin.ets.fm|if \[ -f .* \] && \[ -f|openssl req -x509|subjectAltName=DNS:\$\{WEBDNS\}|envsubst|exec nginx" container/entrypoint.sh
```
Expected: default WEBDNS, the existing-cert guard, the openssl line, the SAN, the envsubst render, and `exec nginx`.

- [ ] **Step 4: Commit**

```bash
git add container/entrypoint.sh
git commit -m "Add entrypoint: runtime self-signed cert + nginx config render"
```

---

## Task 3: Create the Containerfile

**Files:**
- Create: `container/Containerfile`

- [ ] **Step 1: Create `container/Containerfile`** with EXACTLY this content:

```dockerfile
FROM docker.io/library/ubuntu:24.04

# nginx serves the files; openssl makes the self-signed cert; gettext-base provides envsubst.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends nginx openssl gettext-base \
	&& rm -rf /var/lib/apt/lists/*

COPY container/nginx.conf.template /etc/nginx/nginx.conf.template
COPY container/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 443

ENTRYPOINT ["/entrypoint.sh"]
```

Note: build context is the repo root (so the `COPY container/...` paths resolve); `run.sh` in Task 4 builds with `-f container/Containerfile .`.

- [ ] **Step 2: Verify base image, packages, copies, and entrypoint**

Run:
```bash
grep -nE "FROM docker.io/library/ubuntu:24.04|nginx openssl gettext-base|COPY container/nginx.conf.template|COPY container/entrypoint.sh|EXPOSE 443|ENTRYPOINT \[\"/entrypoint.sh\"\]" container/Containerfile
```
Expected: all six lines present (the package line confirms `envsubst` via gettext-base).

- [ ] **Step 3: Commit**

```bash
git add container/Containerfile
git commit -m "Add Containerfile: Ubuntu 24.04 + nginx + openssl"
```

---

## Task 4: Create the run.sh convenience wrapper

**Files:**
- Create: `container/run.sh`

- [ ] **Step 1: Create `container/run.sh`** with EXACTLY this content:

```bash
#!/usr/bin/env bash
# Build and run the local HTTPS test container, serving this repo over https://$WEBDNS.
set -euo pipefail

WEBDNS="${WEBDNS:-webdlogin.ets.fm}"
IMAGE="fms-webd-oauth-test"

# Repo root = parent of this script's directory, regardless of where it is called from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "Building ${IMAGE}..."
podman build -t "${IMAGE}" -f "${REPO_ROOT}/container/Containerfile" "${REPO_ROOT}"

echo
echo "Reminder: map ${WEBDNS} to this host, e.g. add to /etc/hosts:"
echo "    127.0.0.1 ${WEBDNS}"
echo "Then open: https://${WEBDNS}  (accept the one-time self-signed cert warning)"
echo

exec podman run --rm -it \
	-p 443:443 \
	-v "${REPO_ROOT}:/usr/share/nginx/html:ro,Z" \
	-e WEBDNS="${WEBDNS}" \
	"${IMAGE}"
```

- [ ] **Step 2: Make it executable and syntax-check it**

Run:
```bash
chmod +x container/run.sh
bash -n container/run.sh && echo "syntax OK"
```
Expected: `syntax OK`.

- [ ] **Step 3: Verify build/run flags and repo-root derivation**

Run:
```bash
grep -nE "podman build -t|podman run|-p 443:443|/usr/share/nginx/html:ro,Z|-e WEBDNS=|BASH_SOURCE" container/run.sh
```
Expected: build line, run line, port publish, the read-only repo mount, the WEBDNS env pass, and the `BASH_SOURCE`-based repo-root derivation.

- [ ] **Step 4: Commit**

```bash
git add container/run.sh
git commit -m "Add run.sh: build + run the test container"
```

---

## Task 5: Build + run smoke test (real podman — this is the acceptance test)

> Requires podman on the host (confirmed: podman 5.7.0). This task actually builds the image and serves a request. If the build or curl check fails, fix the relevant file from Tasks 1–4 and re-run.

**Files:** none (uses the files from Tasks 1–4).

- [ ] **Step 1: Build the image**

Run:
```bash
podman build -t fms-webd-oauth-test -f container/Containerfile .
```
Expected: build completes with no error; final line shows the image was tagged `fms-webd-oauth-test`.

- [ ] **Step 2: Run the container in the background with a test hostname**

Run:
```bash
podman run -d --rm --name fmswebd-test -p 8443:443 \
	-v "$(pwd):/usr/share/nginx/html:ro,Z" \
	-e WEBDNS=webdlogin.ets.fm \
	fms-webd-oauth-test
sleep 2
podman logs fmswebd-test
```
Expected: logs show `generating self-signed certificate for webdlogin.ets.fm` and `serving https://webdlogin.ets.fm`. (Published on host port 8443 to avoid needing root for 443 during the smoke test.)

- [ ] **Step 3: Fetch index.html over HTTPS and confirm it is served**

Run:
```bash
curl -sk https://localhost:8443/index.html | grep -c "initOAuth"
```
Expected: `1` or more (the served `index.html` contains the `initOAuth` onload hook). The `-k` accepts the self-signed cert.

- [ ] **Step 4: Confirm the cert SAN matches WEBDNS**

Run:
```bash
echo | openssl s_client -connect localhost:8443 -servername webdlogin.ets.fm 2>/dev/null \
	| openssl x509 -noout -ext subjectAltName
```
Expected: output contains `DNS:webdlogin.ets.fm`.

- [ ] **Step 5: Stop the container**

Run:
```bash
podman stop fmswebd-test
```
Expected: container stops (and is auto-removed via `--rm`).

- [ ] **Step 6: Record the smoke-test result**

No commit (no files changed). Note pass/fail in the session. If anything failed, return to the relevant task file, fix, recommit, and re-run this task.

---

## Task 6: Document local testing in README.txt

**Files:**
- Modify: `README.txt`

- [ ] **Step 1: Add a "Local testing with Podman" section to `README.txt`** immediately AFTER the "Full-page mode flow" diagram block (which ends with the `WebDirect session opens (homeurl on webDNS)` line) and BEFORE the `Enjoy!` line. Insert exactly this block:

```text
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
```

- [ ] **Step 2: Verify the section landed in the right place with the required content**

Run:
```bash
grep -nE "Local testing with Podman|container/run.sh|127.0.0.1 webdlogin.ets.fm|self-signed certificate|/etc/nginx/certs" README.txt
```
Expected: the heading, the run command, the /etc/hosts line, the self-signed explanation, and the mount-your-own-cert path all present.

Run:
```bash
awk '/Full-page mode flow/{f=1} /Local testing with Podman/{p=1} /^Enjoy!/{e=NR} END{print "podman_section_found="p}' README.txt
grep -n "Enjoy!" README.txt
```
Expected: `podman_section_found=1`, and the `Enjoy!` line number is AFTER the "Local testing with Podman" heading's line number (section inserted before Enjoy!).

- [ ] **Step 3: Commit**

```bash
git add README.txt
git commit -m "Document local Podman test container in README"
```

---

## Self-Review notes (for the implementer)

- **Spec coverage:** nginx template (Task 1), entrypoint with runtime cert + cert-reuse guard (Task 2), Ubuntu 24.04 Containerfile with envsubst dep (Task 3), run.sh with repo mount + WEBDNS pass + /etc/hosts reminder (Task 4), real build+serve+SAN smoke test (Task 5), README section with build/run + /etc/hosts + SSL explanation + bring-your-own-cert (Task 6). All success criteria from the spec are covered. Production hardening, CA auto-trust, and CI are intentionally out of scope.
- **Consistency:** the image tag `fms-webd-oauth-test`, the cert paths `/etc/nginx/certs/server.{crt,key}`, the template path `/etc/nginx/nginx.conf.template`, the webroot `/usr/share/nginx/html`, and the `WEBDNS` default `webdlogin.ets.fm` are identical across the Containerfile, entrypoint, nginx template, and run.sh. The Containerfile installs `gettext-base` so the entrypoint's `envsubst` exists. Build context is the repo root in both the Containerfile note and run.sh.
- **Smoke test note:** Task 5 publishes host port 8443 (not 443) to avoid needing elevated privileges; `run.sh` uses 443 for real use. This is intentional and called out.
