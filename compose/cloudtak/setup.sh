#!/usr/bin/env bash
# Prepares this folder to run CloudTAK. Safe to run as often as you like.
#   - Downloads CloudTAK's source into src/, at the version below.
#   - Creates .env with random secrets, if it doesn't exist.
set -euo pipefail
cd "$(dirname "$0")"

# The CloudTAK release this folder is tested with.
CLOUDTAK_VERSION=v13.113.0

# 1. Source: CloudTAK has no published images for Compose, so we build from source.
if [[ -d src/.git ]]; then
  current=$(git -C src describe --tags 2>/dev/null || echo unknown)
  if [[ "$current" != "$CLOUDTAK_VERSION" ]]; then
    git -C src fetch --depth 1 origin tag "$CLOUDTAK_VERSION"
    git -C src -c advice.detachedHead=false checkout -q "$CLOUDTAK_VERSION"
    echo "Source:      moved src/ from $current to $CLOUDTAK_VERSION"
  else
    echo "Source:      keeping src/ at $CLOUDTAK_VERSION"
  fi
else
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$CLOUDTAK_VERSION" \
    https://github.com/dfpc-coe/CloudTAK.git src
  echo "Source:      downloaded CloudTAK $CLOUDTAK_VERSION into src/"
fi

# 2. Secrets: created once, never changed. The defaults in upstream's example
# are public, so replace every one of them.
if [[ -f .env ]]; then
  echo "Secrets:     keeping existing .env"
else
  umask 077
  store_key=$(openssl rand -hex 12)
  sed -e "s/^SigningSecret=.*/SigningSecret=$(openssl rand -hex 32)/" \
      -e "s/^GARAGE_RPC_SECRET=.*/GARAGE_RPC_SECRET=$(openssl rand -hex 32)/" \
      -e "s/^AWS_S3_AccessKeyId=.*/AWS_S3_AccessKeyId=GK$store_key/" \
      -e "s/^AWS_S3_SecretAccessKey=.*/AWS_S3_SecretAccessKey=$(openssl rand -hex 32)/" \
      -e "s|^API_URL=.*|API_URL=http://localhost:5080|" \
      src/.env.example > .env
  echo "CLOUDTAK_Hub_URL=" >> .env
  umask 022
  echo "Secrets:     created .env"
fi

# 3. Trust: CloudTAK checks TAK Server's certificate, so it needs our root CAs.
# Only the public certificates are copied, never the keys. Run this again after
# rotating a CA.
takserver=(docker compose --project-directory ../takserver)
if ! "${takserver[@]}" exec -T takserver true 2>/dev/null; then
  echo "Trust:       TAK Server isn't running. Start it, then run ./setup.sh again." >&2
  exit 1
fi
"${takserver[@]}" exec -T takserver bash -c \
  'cd /opt/tak/certs/files && for ca in root-ca root-ca-old; do if [[ -f $ca.pem ]]; then openssl x509 -in $ca.pem; fi; done' \
  > tak-ca.pem
echo "Trust:       saved TAK Server's root CAs in tak-ca.pem:"
grep -c "BEGIN CERTIFICATE" tak-ca.pem | sed 's/^/             /; s/$/ certificate(s)/'

echo
echo "Ready. Start CloudTAK with:"
echo "  docker compose up -d --build"
