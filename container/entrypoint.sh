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
