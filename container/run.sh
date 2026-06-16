#!/usr/bin/env bash
# Build and run the local HTTPS test container, serving this repo over https://$WEBDNS.
set -euo pipefail

WEBDNS="${WEBDNS:-webdlogin.ets.fm}"
IMAGE="fms-webd-oauth-test"

# Optional: point CERT_DIR at a host directory holding server.crt + server.key to use your
# own certificate (no browser warning). If unset, the container generates a self-signed one.
CERT_DIR="${CERT_DIR:-}"

# Repo root = parent of this script's directory, regardless of where it is called from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CERT_ARGS=()
if [ -n "${CERT_DIR}" ]; then
	CERT_ABS="$(cd "${CERT_DIR}" && pwd)"
	echo "Using your certificate from ${CERT_ABS} (server.crt + server.key)"
	CERT_ARGS=(-v "${CERT_ABS}:/etc/nginx/certs:ro,Z")
fi

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
	${CERT_ARGS[@]+"${CERT_ARGS[@]}"} \
	-e WEBDNS="${WEBDNS}" \
	"${IMAGE}"
