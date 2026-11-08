#!/usr/bin/env bash
# Starts Federation Hub with settings from configuration. Safe on every start.
#   - Copies the programs from the release, so upgrading is replacing release/.
#   - Creates the hub's own CA, server certificate and admin certificate once.
#   - Trusts the TAK Servers whose CAs are in config/federation/.
#   - Lets the admin certificate into the web interface.
set -euo pipefail
: "${CA_NAME:?}" "${CA_PASS:?}" "${HUB_CERT_PASS:?}" "${ADMIN_CERT_PASS:?}"

RELEASE=/opt/tak-release/federation-hub
HUB=/opt/tak/federation-hub          # a Docker volume: certificates and policies persist
FILES=$HUB/certs/files

# 1. Programs and scripts, fresh from the release on every start. The volume
# keeps certs/files, the policy files and the list of admins.
mkdir -p "$HUB/certs" "$HUB/policies" "$HUB/logs" "$HUB/jetty-temp"
cp -rT "$RELEASE/jars" "$HUB/jars"
cp -rT "$RELEASE/scripts" "$HUB/scripts"
cp -rT "$RELEASE/configs" "$HUB/configs"
cp "$RELEASE"/certs/*.sh "$RELEASE"/certs/config.cfg "$HUB/certs/"

# 2. The hub's own certificate authority, made once. It signs the hub's server
# certificate, which TAK Servers check when they connect, and the admin
# certificate for the web interface.
cd "$HUB/certs"
sed -i 's/^COUNTRY=US$/COUNTRY=${COUNTRY:-US}/' cert-metadata.sh
export CAPASS="$CA_PASS"
if [[ ! -f "$FILES/ca.pem" ]]; then
  echo "Creating the hub's CA: $CA_NAME"
  bash makeRootCa.sh --ca-name "$CA_NAME"
fi
if [[ ! -f "$FILES/fedhub.jks" ]]; then
  echo "Creating the hub's server certificate"
  PASS="$HUB_CERT_PASS" bash makeCert.sh server fedhub
fi
if [[ ! -f "$FILES/admin.pem" ]]; then
  echo "Creating the admin certificate"
  PASS="$ADMIN_CERT_PASS" bash makeCert.sh client admin
fi

# 3. Who may connect: our own CA, plus the CA of each TAK Server in
# config/federation/. Each CA becomes a "CA group" in the policy editor.
rm -f "$FILES/fed-truststore.jks"
keytool -importcert -noprompt -alias hub-ca -file "$FILES/ca.pem" \
  -keystore "$FILES/fed-truststore.jks" -storepass "$CA_PASS" >/dev/null
partners=()
for f in /federation/*.pem; do
  [[ -f "$f" ]] || continue
  i=0
  while IFS= read -r -d '' cert; do
    i=$((i + 1))
    printf '%s' "$cert" > /tmp/partner.crt
    keytool -importcert -noprompt -alias "$(basename "$f" .pem)-$i" -file /tmp/partner.crt \
      -keystore "$FILES/fed-truststore.jks" -storepass "$CA_PASS" >/dev/null
    partners+=("$(openssl x509 -noout -subject -nameopt multiline -in /tmp/partner.crt | awk -F' = ' '/commonName/ {print $2}')")
  done < <(awk '/-----BEGIN CERTIFICATE-----/ { c = "" } { c = c $0 "\n" } /-----END CERTIFICATE-----/ { printf "%s%c", c, 0 }' "$f")
done
echo "Trusted TAK Server CAs: ${partners[*]:-none}"

# 4. Point the configuration at our certificates and passwords. Mission
# federation disruption tolerance is off, so the hub doesn't need its database.
sed -i -e "s|takserver.jks|fedhub.jks|" \
       -e "s|^keystorePassword:.*|keystorePassword: ${HUB_CERT_PASS}|" \
       -e "s|^truststorePassword:.*|truststorePassword: ${CA_PASS}|" \
       -e "s|^keyAlias:.*|keyAlias: fedhub|" \
       -e "s|^v1Enabled:.*|v1Enabled: false|" \
       "$HUB/configs/federation-hub-broker.yml" "$HUB/configs/federation-hub-ui.yml"

# 5. Let the admin certificate into the web interface.
java -jar "$HUB/jars/federation-hub-manager.jar" "$FILES/admin.pem" "$HUB/authorized_users.yml" >/dev/null
echo "Admin certificate authorized: admin"

echo "Starting Federation Hub"
exec bash "$HUB/scripts/configureInDocker.sh" init
