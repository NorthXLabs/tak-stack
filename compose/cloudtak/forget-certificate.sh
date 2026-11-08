#!/usr/bin/env bash
# Makes CloudTAK forget the certificate it holds for a user, so it enrolls a
# new one the next time they sign in.
#
#   ./forget-certificate.sh <user>
#
# Use it after lifting a lockout (REVOKE) on TAK Server. CloudTAK keeps each
# user's certificate in its database, and keeps using it after it's revoked,
# so the user can't sign in again until it's gone.
set -euo pipefail
cd "$(dirname "$0")"

user=${1:-}
if [[ -z "$user" || ! "$user" =~ ^[A-Za-z0-9._@-]+$ ]]; then
  echo "Usage: ./forget-certificate.sh <user>" >&2
  exit 1
fi

result=$(docker compose exec -T postgis psql -U docker -d gis -Atq \
  -c "update profile set auth = null where username = '$user' returning username")
if [[ -n "$result" ]]; then
  echo "CloudTAK has forgotten $user's certificate. They'll get a new one when they next sign in."
else
  echo "CloudTAK has no user called $user." >&2
  exit 1
fi
