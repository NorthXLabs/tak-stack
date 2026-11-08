#!/usr/bin/env bash
# Rotates the certificate authorities that sign every TAK certificate.
#
#   ./rotate-ca.sh status         show each CA and when it expires
#   ./rotate-ca.sh intermediate   replace the intermediate CA
#   ./rotate-ca.sh root           replace the root and intermediate CAs
#   ./rotate-ca.sh retire         stop trusting the old CAs
#
# Old and new CAs are trusted side by side until you retire the old ones, so
# devices keep working while they move over. Restarts the server afterwards.
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
  status|intermediate|root|retire) ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

docker compose run --rm --no-deps -T --entrypoint /bin/bash tak-certs /init/rotate-ca.sh "$1"
[[ "$1" == status ]] && exit 0

echo
echo "Restarting TAK Server with the new certificates"
docker compose up -d --force-recreate --wait tak-certs takserver
