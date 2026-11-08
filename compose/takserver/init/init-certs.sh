#!/usr/bin/env bash
# Creates TAK Server certificates on first start, and anything added since.
# Idempotent: existing certificates are never replaced, so it's safe on every
# start. Also refreshes the revocation lists and the truststore every time.
set -euo pipefail

: "${CA_NAME:?}" "${CA_PASS:?}" "${STATE:?}" "${CITY:?}" "${ORGANIZATIONAL_UNIT:?}"
: "${TAKSERVER_CERT_PASS:?}" "${ADMIN_CERT_NAME:?}" "${ADMIN_CERT_PASS:?}"

source /init/ca-common.sh

if [[ ! -f "$FILES/root-ca.pem" ]]; then
  echo "Creating root CA: $CA_NAME"
  bash makeRootCa.sh --ca-name "$CA_NAME"
else
  echo "Root CA exists: $(cert_cn "$FILES/root-ca.pem")"
fi

if [[ ! -f "$FILES/intermediate-signing.jks" ]]; then
  echo "Creating intermediate signing CA"
  make_intermediate
else
  echo "Intermediate CA exists: $(cert_cn "$FILES/intermediate.pem")"
fi

# New certificates must be signed by the current intermediate CA. This also
# repairs a run that stopped between creating the intermediate and switching.
use_intermediate_for_signing

make_cert() {
  local type=$1 name=$2 pass=$3
  if [[ ! -f "$FILES/$name.pem" ]]; then
    echo "Creating $type certificate: $name"
    PASS="$pass" bash makeCert.sh "$type" "$name"
  else
    echo "Certificate exists: $name"
  fi
}

# The server certificate names every address in SERVER_ADDRESSES. If the list
# changes, recreate just this certificate. Client certificates stay valid,
# because they're signed by the same CA.
names="takserver ${SERVER_ADDRESSES:-}"
names=$(echo $names | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/ $//')
stamp="$FILES/takserver.names"
if [[ -f "$FILES/takserver.pem" && "$(cat "$stamp" 2>/dev/null)" != "$names" ]]; then
  echo "Server addresses changed, recreating the server certificate"
  rm -f "$FILES"/takserver.{pem,key,csr,p12,jks} "$FILES/takserver-trusted.pem"
fi
if [[ ! -f "$FILES/takserver.pem" ]]; then
  # Upstream's script names one address. Give it the full list instead.
  alt="" ; i=1 ; j=1
  for n in $names; do
    if [[ $n =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then alt+="IP.$i = $n"$'\n'; i=$((i+1))
    else alt+="DNS.$j = $n"$'\n'; j=$((j+1)); fi
  done
  awk -v alt="$alt" '
    /^\$ALTNAMEFIELD = \$SNAME$/ { printf "%s", alt; next }
    { print }' makeCert.sh > makeServerCert.sh
  echo "Creating server certificate for: $names"
  PASS="$TAKSERVER_CERT_PASS" bash makeServerCert.sh server takserver
  echo "$names" > "$stamp"
else
  echo "Certificate exists: takserver ($names)"
fi

make_cert client "$ADMIN_CERT_NAME" "$ADMIN_CERT_PASS"
for name in ${CLIENT_CERTS:-}; do
  if is_revoked_name "$name"; then
    echo "Skipping $name: it's listed in REVOKE"
    continue
  fi
  make_cert client "$name" "${CLIENT_CERT_PASS:?CLIENT_CERT_PASS is required for client certificates}"
done

# Revoke certificates made in advance for each name in REVOKE. Enrolled
# certificates live in the server's database, so start-takserver.sh revokes
# those once the server is running.
for name in ${REVOKE:-}; do
  if [[ "$name" == "$ADMIN_CERT_NAME" ]]; then
    echo "Not revoking $name: it's the admin certificate."
    continue
  fi
  if [[ -f "$FILES/$name.pem" ]]; then
    revoke_file_cert "$name"
  fi
done

# Every start: fresh revocation lists, so they never go out of date, and a
# truststore holding every CA the server currently trusts.
refresh_crls
build_truststore
build_fed_truststore

# TAK Server runs as user 1001.
chown -R 1001:0 "$FILES"
echo "Certificates ready"
