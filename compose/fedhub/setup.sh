#!/usr/bin/env bash
# Prepares this folder to run Federation Hub. Safe to run as often as you like.
#   - Creates config/secrets.env with random passwords, if it doesn't exist.
#   - Sets FEDHUB_VERSION in .env to match your release.
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f release/tak/version.txt ]]; then
  echo "No release found. Copy the tak.gov takserver-fedhub-docker zip's contents into release/." >&2
  exit 1
fi

secrets=config/secrets.env
if [[ -f "$secrets" ]]; then
  echo "Passwords:   keeping existing $secrets"
else
  umask 077
  {
    echo "CA_PASS=$(openssl rand -hex 16)"
    echo "HUB_CERT_PASS=$(openssl rand -hex 16)"
    echo "ADMIN_CERT_PASS=$(openssl rand -hex 16)"
  } > "$secrets"
  umask 022
  echo "Passwords:   created $secrets"
fi

version=$(tr -d '[:space:]' < release/tak/version.txt)
echo "FEDHUB_VERSION=$version" > .env
echo "Release:     found Federation Hub $version in release/"

echo
echo "Ready. Start Federation Hub with:"
echo "  docker compose up -d --build"
