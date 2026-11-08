#!/usr/bin/env bash
# Shared certificate authority helpers for init-certs.sh and rotate-ca.sh.
#
# The CA files use upstream's names for whatever is current:
#   root-ca.*        the root CA
#   intermediate.*   the intermediate CA that signs every certificate
# During a rotation, the CA being replaced keeps working under an -old name
# (root-ca-old.*, intermediate-old.*) until you retire it.

SCRIPTS=/tak/certs        # certificate scripts, from the image
FILES=$SCRIPTS/files      # certificates, on a persistent volume

cd "$SCRIPTS"
# Upstream hard-codes the country. Let configuration set it instead.
sed -i 's/^COUNTRY=US$/COUNTRY=${COUNTRY:-US}/' cert-metadata.sh
export CAPASS="$CA_PASS"

# Every CA that may be trusted, current first.
CA_NAMES=(root-ca intermediate root-ca-old intermediate-old)

ca_key() {
  case $1 in
    root-ca*) echo "$FILES/$1-do-not-share.key" ;;
    *)        echo "$FILES/$1.key" ;;
  esac
}

cert_cn() {
  openssl x509 -noout -subject -nameopt multiline -in "$1" | awk -F' = ' '/commonName/ {print $2}'
}

is_revoked_name() {
  [[ " ${REVOKE:-} " == *" $1 "* ]]
}

# The common name for the next intermediate CA: intermediate, intermediate-2,
# intermediate-3 and so on. Distinct names keep old and new apart in truststores.
next_intermediate_name() {
  local gen
  gen=$(cat "$FILES/intermediate.generation" 2>/dev/null || echo 0)
  # Set up before this counter existed: the first intermediate is already made.
  if [[ $gen -eq 0 && ( -f "$FILES/intermediate.pem" || -f "$FILES/intermediate-old.pem" ) ]]; then
    gen=1
  fi
  gen=$((gen + 1))
  echo "$gen" > "$FILES/intermediate.generation"
  if [[ $gen -eq 1 ]]; then echo intermediate; else echo "intermediate-$gen"; fi
}

# Creates a new intermediate CA, signed by the current root, and makes it the
# one that signs new certificates.
make_intermediate() {
  local name
  name=$(next_intermediate_name)
  cp "$FILES/root-ca.pem" "$FILES/ca.pem"
  cp "$FILES/root-ca-do-not-share.key" "$FILES/ca-do-not-share.key"
  cp "$FILES/root-ca-trusted.pem" "$FILES/ca-trusted.pem"
  MOVE_CA=true bash makeCert.sh ca "$name"
  if [[ "$name" != intermediate ]]; then
    # Give it upstream's names, so CoreConfig.xml never has to change.
    cp "$FILES/$name.pem" "$FILES/intermediate.pem"
    cp "$FILES/$name.key" "$FILES/intermediate.key"
    cp "$FILES/$name-trusted.pem" "$FILES/intermediate-trusted.pem"
    cp "$FILES/$name-signing.jks" "$FILES/intermediate-signing.jks"
    cp "$FILES/$name-signing.p12" "$FILES/intermediate-signing.p12"
  fi
}

use_intermediate_for_signing() {
  if [[ "$(cat "$FILES/ca.pem")" != "$(cat "$FILES/intermediate.pem")" ]]; then
    echo "Switching signing to the intermediate CA"
    cp "$FILES/intermediate.pem" "$FILES/ca.pem"
    cp "$FILES/intermediate.key" "$FILES/ca-do-not-share.key"
    cp "$FILES/intermediate-trusted.pem" "$FILES/ca-trusted.pem"
  fi
}

# Which of our CAs issued this certificate.
issuing_ca() {
  local issuer ca
  issuer=$(openssl x509 -noout -issuer -nameopt RFC2253 -in "$1" | sed 's/^issuer=//')
  for ca in "${CA_NAMES[@]}"; do
    [[ -f "$FILES/$ca.pem" ]] || continue
    if [[ "$(openssl x509 -noout -subject -nameopt RFC2253 -in "$FILES/$ca.pem" | sed 's/^subject=//')" == "$issuer" ]]; then
      echo "$ca"
      return
    fi
  done
}

# Adds a certificate made on the server to the revocation list, then moves its
# files to revoked/, so the name can have a new certificate later.
revoke_file_cert() {
  local name=$1 ca serial
  ca=$(issuing_ca "$FILES/$name.pem")
  serial=$(openssl x509 -noout -serial -in "$FILES/$name.pem" | cut -d= -f2)
  if [[ -z "$ca" ]]; then
    echo "Can't revoke $name: its CA is no longer trusted, so it can't connect anyway"
  elif grep -q "^R.*	$serial	" "$FILES/crl_index.txt" 2>/dev/null; then
    echo "Already revoked: $name"
  else
    echo "Revoking $name (serial $serial)"
    (cd "$FILES" && openssl ca -config ../config.cfg -revoke "$name.pem" \
      -keyfile "$(ca_key "$ca")" -key "$CAPASS" -cert "$ca.pem")
  fi
  mkdir -p "$FILES/revoked"
  for f in "$FILES/$name".{pem,key,csr,p12,jks} "$FILES/$name-trusted.pem"; do
    [[ -f "$f" ]] && mv "$f" "$FILES/revoked/$(basename "$f" | sed "s/^$name/$name-$serial/")"
  done
}

# Each CA publishes a revocation list. Regenerating them on every start keeps
# them current: TAK Server refuses every client if a list expires.
refresh_crls() {
  local ca
  for ca in "${CA_NAMES[@]}"; do
    [[ -f "$FILES/$ca.pem" ]] || continue
    (cd "$FILES" && openssl ca -config ../config.cfg -gencrl -keyfile "$(ca_key "$ca")" \
      -key "$CAPASS" -cert "$ca.pem" -out "$ca.crl" 2>/dev/null)
  done
  # The admin console's port reads only one file, so it gets all the lists in one.
  : > "$FILES/all-cas.crl"
  for ca in "${CA_NAMES[@]}"; do
    [[ -f "$FILES/$ca.pem" ]] && cat "$FILES/$ca.crl" >> "$FILES/all-cas.crl"
  done
  echo "Revocation lists updated: $(grep -c '^R' "$FILES/crl_index.txt" 2>/dev/null || true) revoked"
}

# truststore-active holds every CA currently trusted: roots and intermediates,
# old and new during a rotation. The server and client packages both use it.
build_truststore() {
  local ca names=()
  rm -f "$FILES/truststore-active.jks" "$FILES/truststore-active.p12"
  for ca in "${CA_NAMES[@]}"; do
    [[ -f "$FILES/$ca.pem" ]] || continue
    openssl x509 -in "$FILES/$ca.pem" -out "/tmp/$ca.crt"
    keytool -importcert -noprompt -trustcacerts -alias "$(cert_cn "$FILES/$ca.pem")" \
      -file "/tmp/$ca.crt" -keystore "$FILES/truststore-active.jks" -storepass "$CAPASS" >/dev/null
    names+=("$(cert_cn "$FILES/$ca.pem")")
  done
  keytool -importkeystore -noprompt -srckeystore "$FILES/truststore-active.jks" -srcstoretype JKS \
    -srcstorepass "$CAPASS" -destkeystore "$FILES/truststore-active.p12" -deststoretype PKCS12 \
    -deststorepass "$CAPASS" >/dev/null 2>&1
  echo "Trusted CAs: ${names[*]}"
}

# Splits the certificates in each /federation/*.pem into /tmp/federation/, one
# file each, and prints their paths.
federation_certs() {
  local f base
  rm -rf /tmp/federation && mkdir -p /tmp/federation
  for f in /federation/*.pem; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f" .pem)
    awk -v out="/tmp/federation/$base" '
      /-----BEGIN CERTIFICATE-----/ { n++; file = out "-" n ".crt" }
      file { print > file }
      /-----END CERTIFICATE-----/ { file = "" }' "$f"
  done
  ls /tmp/federation/*.crt 2>/dev/null || true
}

# The federation truststore holds the CAs of the TAK Servers we federate with,
# from config/federation/. It's separate from truststore-active, so their users
# can't connect to this server directly. Our own root is always in it.
build_fed_truststore() {
  local crt names=()
  rm -f "$FILES/fed-truststore.jks"
  openssl x509 -in "$FILES/root-ca.pem" -out /tmp/own-root.crt
  keytool -importcert -noprompt -alias own-root -file /tmp/own-root.crt \
    -keystore "$FILES/fed-truststore.jks" -storepass "$CAPASS" >/dev/null
  for crt in $(federation_certs); do
    keytool -importcert -noprompt -alias "$(basename "$crt" .crt)" -file "$crt" \
      -keystore "$FILES/fed-truststore.jks" -storepass "$CAPASS" >/dev/null
    names+=("$(cert_cn "$crt")")
  done
  echo "Federation partner CAs: ${names[*]:-none}"
}
