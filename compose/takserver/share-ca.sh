#!/usr/bin/env bash
# Writes this server's CA certificates to a file, to give to a TAK Server you
# federate with. They're public certificates, never keys.
#
#   ./share-ca.sh                  for the server in config/
#   ./share-ca.sh --instance b     for a second server, set up with ./setup.sh --instance b
set -euo pipefail
cd "$(dirname "$0")"

compose=(docker compose)
if [[ "${1:-}" == "--instance" && -n "${2:-}" ]]; then
  compose+=(--env-file "config-$2/compose.env")
fi

name=$("${compose[@]}" exec -T takserver bash -c \
  "openssl x509 -noout -subject -nameopt multiline -in /opt/tak/certs/files/root-ca.pem | awk -F' = ' '/commonName/ {print \$2}'")
"${compose[@]}" exec -T takserver bash -c \
  'cd /opt/tak/certs/files && for ca in root-ca intermediate root-ca-old intermediate-old; do if [[ -f $ca.pem ]]; then openssl x509 -in $ca.pem; fi; done' \
  > "$name.pem"
echo "Wrote $name.pem: $(grep -c 'BEGIN CERTIFICATE' "$name.pem") certificates. Give it to your partner to put in their config/federation/."
