#!/usr/bin/env bash
# Prepares this folder to run the feeds. Run it again after rotating a CA or
# reissuing the feed certificates.
#   - Copies each feed's certificate and key, and the root CA, out of TAK Server.
#   - Creates .env with the key password and the feed settings.
set -euo pipefail
cd "$(dirname "$0")"

FEEDS=(feed-adsb feed-ais feed-tracker)
TAKSERVER=../../compose/takserver
takserver=(docker compose --project-directory "$TAKSERVER")

if ! "${takserver[@]}" exec -T takserver true 2>/dev/null; then
  echo "TAK Server isn't running. Start it in compose/takserver, then run ./setup.sh again." >&2
  exit 1
fi

# 1. Certificates: made in advance by TAK Server, one per feed.
missing=()
for feed in "${FEEDS[@]}"; do
  "${takserver[@]}" exec -T takserver test -f "/opt/tak/certs/files/$feed.pem" || missing+=("$feed")
done
if (( ${#missing[@]} )); then
  echo "TAK Server has no certificate for: ${missing[*]}" >&2
  echo "Add them to CLIENT_CERTS in compose/takserver/config/takserver.env:" >&2
  echo "  CLIENT_CERTS=${FEEDS[*]}" >&2
  echo "then run 'docker compose up -d' there, and ./setup.sh here again." >&2
  exit 1
fi

umask 077
mkdir -p certs
for feed in "${FEEDS[@]}"; do
  for ext in pem key; do
    "${takserver[@]}" exec -T takserver cat "/opt/tak/certs/files/$feed.$ext" > "certs/$feed.$ext"
  done
done
# The feeds check TAK Server's certificate against our root CAs.
"${takserver[@]}" exec -T takserver bash -c \
  'cd /opt/tak/certs/files && for ca in root-ca root-ca-old; do if [[ -f $ca.pem ]]; then openssl x509 -in $ca.pem; fi; done' \
  > certs/tak-ca.pem
echo "Certificates: copied ${FEEDS[*]} and the root CA into certs/"

# 2. Settings: the key password comes from TAK Server's secrets.
pass=$(grep -E '^CLIENT_CERT_PASS=' "$TAKSERVER/config/secrets.env" | cut -d= -f2-)
if [[ -f .env ]]; then
  sed -i.bak "s/^FEED_CERT_PASS=.*/FEED_CERT_PASS=$pass/" .env && rm -f .env.bak
  echo "Settings:     kept .env, and updated the key password"
else
  cat > .env <<EOF
# The password for the feed certificates' keys: CLIENT_CERT_PASS from TAK Server.
FEED_CERT_PASS=$pass

# Aircraft within ADSB_RADIUS_NM nautical miles (up to 250) of this point.
ADSB_LAT=51.13
ADSB_LON=-114.01
ADSB_RADIUS_NM=40

# Vessels in Finland's waters. Set all three to limit them to a circle, for
# example around Helsinki: AIS_LAT=60.15 AIS_LON=24.95 AIS_RADIUS_KM=50
AIS_LAT=
AIS_LON=
AIS_RADIUS_KM=

# Where the pretend tractor works: the south-west corner of its field.
FIELD_LAT=51.0300
FIELD_LON=-113.7500
EOF
  echo "Settings:     created .env"
fi

echo
echo "Ready. Start the feeds with:"
echo "  docker compose up -d --build"
