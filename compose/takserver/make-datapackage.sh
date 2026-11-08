#!/usr/bin/env bash
# Builds a data package that connects a TAK client to this server.
#
#   ./make-datapackage.sh <server address>
#       An enrollment package. It holds the server address and our CA, but no
#       passwords or certificates, so it's safe to share with your whole team.
#       Each user signs in with their own username and password.
#
#   ./make-datapackage.sh --with-cert <user> <server address>
#       A package with the user's own certificate and its password, for devices
#       that can't enroll. Share it only with that user. The user must be listed
#       in CLIENT_CERTS.
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  echo "Usage: ./make-datapackage.sh <server address>" >&2
  echo "       ./make-datapackage.sh --with-cert <user> <server address>" >&2
  echo "Example: ./make-datapackage.sh 192.168.1.50" >&2
  exit 1
}

user=""
if [[ "${1:-}" == "--with-cert" ]]; then
  user=${2:-}; address=${3:-}
  [[ -n "$user" && -n "$address" ]] || usage
else
  address=${1:-}
  [[ -n "$address" ]] || usage
fi

if ! docker compose ps --status running --services 2>/dev/null | grep -qx takserver; then
  echo "TAK Server isn't running. Start it with ./setup.sh and docker compose up -d first." >&2
  exit 1
fi

if [[ -n "$user" ]] && ! docker compose exec -T takserver test -f "/opt/tak/certs/files/$user.p12"; then
  echo "No certificate for '$user'. Add it to CLIENT_CERTS in config/takserver.env," >&2
  echo "then run: docker compose up -d" >&2
  exit 1
fi

name=${user:-enroll}-$address
mkdir -p datapackages

docker compose exec -T -e DP_USER="$user" -e DP_ADDRESS="$address" -e DP_NAME="$name" takserver python3 - <<'PY'
import os, uuid, zipfile
user, address, name = os.environ["DP_USER"], os.environ["DP_ADDRESS"], os.environ["DP_NAME"]
files = "/opt/tak/certs/files"

# Certificates go on the connection itself, not in ATAK's app-wide settings.
# ATAK deletes each certificate file once it imports it, so naming the same
# file in both places leaves the connection without one.
stream = f"""    <entry key="count" class="class java.lang.Integer">1</entry>
    <entry key="description0" class="class java.lang.String">TAK Server</entry>
    <entry key="enabled0" class="class java.lang.Boolean">true</entry>
    <entry key="connectString0" class="class java.lang.String">{address}:8089:ssl</entry>
    <entry key="caLocation0" class="class java.lang.String">cert/truststore.p12</entry>
    <entry key="caPassword0" class="class java.lang.String">{os.environ["CA_PASS"]}</entry>"""
app = """    <entry key="displayServerConnectionWidget" class="class java.lang.Boolean">true</entry>"""
contents = ["certs/server.pref", "certs/truststore.p12"]

if user:
    stream += f"""
    <entry key="certificateLocation0" class="class java.lang.String">cert/{user}.p12</entry>
    <entry key="clientPassword0" class="class java.lang.String">{os.environ["CLIENT_CERT_PASS"]}</entry>"""
    contents.append(f"certs/{user}.p12")
else:
    stream += """
    <entry key="enrollForCertificateWithTrust0" class="class java.lang.Boolean">true</entry>
    <entry key="enrollUseTrust0" class="class java.lang.Boolean">true</entry>
    <entry key="useAuth0" class="class java.lang.Boolean">true</entry>
    <entry key="cacheCreds0" class="class java.lang.String">Cache credentials</entry>"""

server_pref = f"""<?xml version='1.0' encoding='ASCII' standalone='yes'?>
<preferences>
  <preference version="1" name="cot_streams">
{stream}
  </preference>
  <preference version="1" name="com.atakmap.app_preferences">
{app}
  </preference>
</preferences>
"""
entries = "\n".join(f'    <Content ignore="false" zipEntry="{c}"/>' for c in contents)
manifest = f"""<MissionPackageManifest version="2">
  <Configuration>
    <Parameter name="uid" value="{uuid.uuid4()}"/>
    <Parameter name="name" value="{name}"/>
    <Parameter name="onReceiveDelete" value="true"/>
  </Configuration>
  <Contents>
{entries}
  </Contents>
</MissionPackageManifest>
"""
with zipfile.ZipFile(f"/tmp/{name}.zip", "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("MANIFEST/manifest.xml", manifest)
    z.writestr("certs/server.pref", server_pref)
    # Every CA the server trusts: the root and intermediate, plus the old ones
    # during a CA rotation, so devices trust the server before and after.
    z.write(f"{files}/truststore-active.p12", "certs/truststore.p12")
    if user:
        z.write(f"{files}/{user}.p12", f"certs/{user}.p12")
PY
docker compose cp "takserver:/tmp/$name.zip" "datapackages/$name.zip" >/dev/null 2>&1
docker compose exec -T takserver rm -f "/tmp/$name.zip"
echo "Created datapackages/$name.zip"
if [[ -n "$user" ]]; then
  echo "It contains $user's certificate and password. Share it only with that user."
else
  echo "Share it with your team. Each person signs in with their own username and password."
fi
