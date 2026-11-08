#!/usr/bin/env bash
# Writes the hub's CA certificate to a file, for each TAK Server that connects
# to the hub to put in its config/federation/. A public certificate, never a key.
set -euo pipefail
cd "$(dirname "$0")"
name=$(docker compose exec -T fedhub bash -c \
  "openssl x509 -noout -subject -nameopt multiline -in /opt/tak/federation-hub/certs/files/ca.pem | awk -F' = ' '/commonName/ {print \$2}'")
docker compose exec -T fedhub openssl x509 -in /opt/tak/federation-hub/certs/files/ca.pem > "$name.pem"
echo "Wrote $name.pem. Put it in each TAK Server's config/federation/."
