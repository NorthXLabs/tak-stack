#!/usr/bin/env bash
# Creates TAK Server certificates on first start, and anything added since.
# Idempotent: existing files are never touched, so it's safe on every start.
set -euo pipefail

: "${CA_NAME:?}" "${CA_PASS:?}" "${STATE:?}" "${CITY:?}" "${ORGANIZATIONAL_UNIT:?}"
: "${TAKSERVER_CERT_PASS:?}" "${ADMIN_CERT_NAME:?}" "${ADMIN_CERT_PASS:?}"

SCRIPTS=/tak/certs        # certificate scripts, from the image
FILES=$SCRIPTS/files      # certificates, on a persistent volume

cd "$SCRIPTS"
# Upstream hard-codes the country. Let configuration set it instead.
sed -i 's/^COUNTRY=US$/COUNTRY=${COUNTRY:-US}/' cert-metadata.sh
export CAPASS="$CA_PASS"

if [[ ! -f "$FILES/root-ca.pem" ]]; then
  echo "Creating root CA: $CA_NAME"
  bash makeRootCa.sh --ca-name "$CA_NAME"
else
  echo "Root CA exists"
fi

if [[ ! -f "$FILES/intermediate-signing.jks" ]]; then
  echo "Creating intermediate signing CA"
  MOVE_CA=true bash makeCert.sh ca intermediate
else
  echo "Intermediate CA exists"
fi

# New certificates must be signed by the intermediate CA. This also repairs
# a run that stopped between creating the intermediate and switching to it.
if [[ "$(cat "$FILES/ca.pem")" != "$(cat "$FILES/intermediate.pem")" ]]; then
  echo "Switching signing to the intermediate CA"
  cp "$FILES/intermediate.pem" "$FILES/ca.pem"
  cp "$FILES/intermediate.key" "$FILES/ca-do-not-share.key"
  cp "$FILES/intermediate-trusted.pem" "$FILES/ca-trusted.pem"
fi

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
  make_cert client "$name" "${CLIENT_CERT_PASS:?CLIENT_CERT_PASS is required for client certificates}"
done

# TAK Server runs as user 1001.
chown -R 1001:0 "$FILES"
echo "Certificates ready"
