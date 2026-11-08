#!/usr/bin/env bash
# Starts TAK Server with settings from configuration, registers the admin
# certificate, then applies users, groups and revocations. Safe on every start.
set -euo pipefail
: "${POSTGRES_PASSWORD:?}" "${TAKSERVER_CERT_PASS:?}" "${CA_PASS:?}" "${ADMIN_CERT_NAME:?}"

cd /opt/tak
FILES=/opt/tak/certs/files

# Build CoreConfig.xml from the example, using our passwords.
#  - truststore-active holds every CA we trust: the root and the intermediate,
#    plus the old ones while a rotation is under way. init-certs.sh builds it.
#  - x509checkRevocation makes the server refuse enrolled certificates that
#    have been revoked in the admin console, from the moment you revoke them.
sed -e "s|password=\"\"|password=\"${POSTGRES_PASSWORD}\"|" \
    -e "s|keystorePass=\"atakatak\"|keystorePass=\"${TAKSERVER_CERT_PASS}\"|g" \
    -e "s|truststorePass=\"atakatak\"|truststorePass=\"${CA_PASS}\"|g" \
    -e "s|truststoreFile=\"/opt/tak/certs/files/truststore-root.jks\"|truststoreFile=\"$FILES/truststore-active.jks\"|" \
    -e "s|^    <auth>$|    <auth x509checkRevocation=\"true\">|" \
    CoreConfig.example.xml > CoreConfig.xml

# Revocation lists, one per CA. The server reads them when it starts, and
# refuses any certificate they list. init-certs.sh refreshes them. The web
# ports (8443 and 8446) only read the first entry, so it holds every list.
crls="            <crl _name=\"all-cas\" crlFile=\"$FILES/all-cas.crl\"/>"$'\n'
for ca in root-ca intermediate root-ca-old intermediate-old; do
  [[ -f "$FILES/$ca.crl" ]] && crls+="            <crl _name=\"$ca\" crlFile=\"$FILES/$ca.crl\"/>"$'\n'
done
awk -v crls="$crls" '/<!-- <crl _name=/ { printf "%s", crls; next } { print }' CoreConfig.xml > CoreConfig.tmp
mv CoreConfig.tmp CoreConfig.xml

# Let the server sign certificates for enrolling users, using the intermediate
# CA. CAkey and CAcertificate let the admin console's Revoke button add the
# certificate to the intermediate's revocation list as well.
signing="    <certificateSigning CA=\"TAKServer\">
        <certificateConfig>
            <nameEntries>
                <nameEntry name=\"O\" value=\"${ORGANIZATION:-TAK}\"/>
                <nameEntry name=\"OU\" value=\"${ORGANIZATIONAL_UNIT:-TAK}\"/>
            </nameEntries>
        </certificateConfig>
        <TAKServerCAConfig keystore=\"JKS\" keystoreFile=\"$FILES/intermediate-signing.jks\"
            keystorePass=\"${CA_PASS}\" validityDays=\"365\" signatureAlg=\"SHA256WithRSA\"
            CAkey=\"$FILES/intermediate\" CAcertificate=\"$FILES/intermediate\"/>
    </certificateSigning>"
awk -v block="$signing" '/^    <security>/ && !done { print block; done=1 } { print }' CoreConfig.xml > CoreConfig.tmp
mv CoreConfig.tmp CoreConfig.xml

# Federation: share with other TAK Servers. Their CAs are in config/federation/,
# and init-certs.sh puts them in the federation truststore. The example config
# has no federation section, so write a whole one.
if [[ "${FEDERATION:-false}" == true ]]; then
  # Connect out to each server in FEDERATE_WITH. One side connecting is enough.
  outgoing=""
  for peer in ${FEDERATE_WITH:-}; do
    host=${peer%:*}; port=${peer##*:}
    outgoing+="        <federation-outgoing displayName=\"$host:$port\" address=\"$host\" port=\"$port\" protocolVersion=\"2\" reconnectInterval=\"30\" enabled=\"true\"/>"$'\n'
  done

  # A federate whose certificate comes from one of these CAs gets these groups
  # when it first connects: where its data goes here, and what we share with it.
  groups=""
  for g in ${FEDERATION_RECEIVE:-__ANON__}; do groups+="            <inboundGroup>$g</inboundGroup>"$'\n'; done
  for g in ${FEDERATION_SHARE:-__ANON__}; do groups+="            <outboundGroup>$g</outboundGroup>"$'\n'; done
  cas=""
  for f in /federation/*.pem; do
    [[ -f "$f" ]] || continue
    while read -r fingerprint; do
      cas+="        <federateCA fingerprint=\"$fingerprint\">"$'\n'"$groups        </federateCA>"$'\n'
    done < <(awk '/-----BEGIN CERTIFICATE-----/ { cert = "" } { cert = cert $0 "\n" }
                  /-----END CERTIFICATE-----/ { printf "%s", cert | "openssl x509 -noout -fingerprint -sha256"; close("openssl x509 -noout -fingerprint -sha256") }' "$f" |
             cut -d= -f2)
  done

  # Protocol version 2 only, on port 9001.
  federation="    <federation enableFederation=\"true\">
        <federation-server v1enabled=\"false\" v2enabled=\"true\" v2port=\"9001\">
            <tls context=\"TLSv1.2\" keymanager=\"SunX509\"
                keystore=\"JKS\" keystoreFile=\"$FILES/takserver.jks\" keystorePass=\"${TAKSERVER_CERT_PASS}\"
                truststore=\"JKS\" truststoreFile=\"$FILES/fed-truststore.jks\" truststorePass=\"${CA_PASS}\"/>
        </federation-server>
$outgoing        <fileFilter>
            <fileExtension>pref</fileExtension>
        </fileFilter>
$cas    </federation>"
  awk -v block="$federation" '{ print } /^    <\/security>/ && !done { print block; done=1 }' CoreConfig.xml > CoreConfig.tmp
  mv CoreConfig.tmp CoreConfig.xml
  echo "Federation on: port 9001, connecting to ${FEDERATE_WITH:-nobody (waiting for others)}, sharing ${FEDERATION_SHARE:-__ANON__}, receiving into ${FEDERATION_RECEIVE:-__ANON__}"
fi

# The console's Revoke button runs upstream's revokeCert.sh, which needs the
# CA password.
export CAPASS="$CA_PASS"

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

is_revoked_name() { [[ " ${REVOKE:-} " == *" $1 "* ]]; }

# Group options for a name, from USER_GROUPS (for example alpha-1:blue,red).
group_args() {
  local entry
  for entry in ${USER_GROUPS:-}; do
    if [[ "${entry%%:*}" == "$1" ]]; then
      local g
      for g in $(echo "${entry#*:}" | tr ',' ' '); do printf -- '-g\n%s\n' "$g"; done
    fi
  done
}

# Create or update each enrolling user, with their groups. Safe on every start.
for user in ${USERS:-}; do
  if is_revoked_name "$user"; then continue; fi
  key="USER_PASS_$(echo "$user" | tr '[:lower:]-' '[:upper:]_')"
  if [[ -z "${!key:-}" ]]; then
    echo "No password for $user. Run ./setup.sh, then start again."
    continue
  fi
  mapfile -t groups < <(group_args "$user")
  if java -jar utils/UserManager.jar usermod -p "${!key}" "${groups[@]}" "$user" >/dev/null 2>&1; then
    echo "User ready: $user (groups: $(printf '%s ' "${groups[@]}" | sed 's/-g //g; s/ $//' | grep . || echo __ANON__))"
  else
    echo "Couldn't create user: $user"
  fi
done

# Certificates made in advance get their groups the same way, matched by name.
for entry in ${USER_GROUPS:-}; do
  name=${entry%%:*}
  [[ " ${USERS:-} " == *" $name "* ]] && continue
  is_revoked_name "$name" && continue
  mapfile -t groups < <(group_args "$name")
  java -jar utils/UserManager.jar usermod "${groups[@]}" "$name" >/dev/null 2>&1 &&
    echo "Groups ready: $name ($(echo "${entry#*:}" | tr ',' ' '))"
done

# REVOKE: delete the user, so they can't enroll again, and revoke every
# certificate the server issued them. init-certs.sh has already revoked any
# certificate made in advance.
if [[ -n "${REVOKE:-}" ]]; then
  admin=(--cert-type P12 --cert "$FILES/${ADMIN_CERT_NAME}.p12:${ADMIN_CERT_PASS}")
  api=https://localhost:8443/Marti/api/certadmin/cert
  for attempt in $(seq 1 60); do
    [[ "$(curl -sk "${admin[@]}" -o /dev/null -w '%{http_code}' "$api/active")" == 200 ]] && break
    sleep 5
  done
  for name in $REVOKE; do
    [[ "$name" == "$ADMIN_CERT_NAME" ]] && continue
    java -jar utils/UserManager.jar usermod -D "$name" >/dev/null 2>&1 || true
    ids=$(curl -sk "${admin[@]}" "$api/active" | NAME="$name" python3 -c '
import json, os, re, sys
name = os.environ["NAME"]
certs = json.load(sys.stdin).get("data", [])
# userDn holds the username for enrolled certificates, or a full DN.
print(",".join(str(c["id"]) for c in certs
               if c.get("userDn") == name or re.search(r"(^|,)\s*CN=" + re.escape(name) + r"\s*(,|$)", c.get("userDn", ""))))' 2>/dev/null || true)
    if [[ -n "$ids" ]]; then
      curl -sk "${admin[@]}" -X DELETE -o /dev/null "$api/revoke/$ids"
      echo "Revoked enrolled certificates for $name (IDs $ids)"
    fi
    echo "Locked out: $name"
  done
fi

wait "$server"
