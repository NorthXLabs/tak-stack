#!/usr/bin/env bash
# Starts TAK Server with settings from configuration, then registers the
# admin certificate. Safe on every start.
set -euo pipefail
: "${POSTGRES_PASSWORD:?}" "${TAKSERVER_CERT_PASS:?}" "${CA_PASS:?}" "${ADMIN_CERT_NAME:?}"

cd /opt/tak

# Build CoreConfig.xml from the example, using our passwords.
sed -e "s|password=\"\"|password=\"${POSTGRES_PASSWORD}\"|" \
    -e "s|keystorePass=\"atakatak\"|keystorePass=\"${TAKSERVER_CERT_PASS}\"|g" \
    -e "s|truststorePass=\"atakatak\"|truststorePass=\"${CA_PASS}\"|g" \
    -e "s|truststoreFile=\"/opt/tak/certs/files/truststore-root.jks\"|truststoreFile=\"/opt/tak/certs/files/truststore-intermediate.jks\"|" \
    CoreConfig.example.xml > CoreConfig.xml
# Client certificates are signed by the intermediate CA, so the server trusts
# both it and the root. Clients don't always send the intermediate themselves.

# Let the server sign certificates for enrolling users, using the intermediate CA.
signing="    <certificateSigning CA=\"TAKServer\">
        <certificateConfig>
            <nameEntries>
                <nameEntry name=\"O\" value=\"${ORGANIZATION:-TAK}\"/>
                <nameEntry name=\"OU\" value=\"${ORGANIZATIONAL_UNIT:-TAK}\"/>
            </nameEntries>
        </certificateConfig>
        <TAKServerCAConfig keystore=\"JKS\" keystoreFile=\"/opt/tak/certs/files/intermediate-signing.jks\"
            keystorePass=\"${CA_PASS}\" validityDays=\"365\" signatureAlg=\"SHA256WithRSA\"/>
    </certificateSigning>"
awk -v block="$signing" '/^    <security>/ && !done { print block; done=1 } { print }' CoreConfig.xml > CoreConfig.tmp
mv CoreConfig.tmp CoreConfig.xml

/opt/tak/configureInDocker.sh init &
server=$!

echo "Waiting for TAK Server to start before registering the admin certificate"
for attempt in $(seq 1 60); do
  if java -jar utils/UserManager.jar certmod -A "certs/files/${ADMIN_CERT_NAME}.pem" >/dev/null 2>&1; then
    echo "Admin certificate registered: ${ADMIN_CERT_NAME}"
    break
  fi
  sleep 10
done

# Create or update each enrolling user. Safe on every start.
for user in ${USERS:-}; do
  key="USER_PASS_$(echo "$user" | tr '[:lower:]-' '[:upper:]_')"
  if [[ -z "${!key:-}" ]]; then
    echo "No password for $user. Run ./setup.sh, then start again."
    continue
  fi
  if java -jar utils/UserManager.jar usermod -p "${!key}" "$user" >/dev/null 2>&1; then
    echo "User ready: $user"
  else
    echo "Couldn't create user: $user"
  fi
done

wait "$server"
