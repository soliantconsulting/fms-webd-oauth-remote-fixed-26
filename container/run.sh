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
