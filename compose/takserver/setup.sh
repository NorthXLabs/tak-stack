#!/usr/bin/env bash
# Prepares this folder to run TAK Server. Safe to run as often as you like.
#   - Creates config/secrets.env with random passwords, if it doesn't exist.
#   - Adds a password for each new user in USERS.
#   - Sets TAK_VERSION in .env to match your release, if you have one.
#
#   ./setup.sh                   the server, with settings in config/
#   ./setup.sh --instance b      a second, separate server on this computer, for
#                                testing federation. Settings go in config-b/,
#                                and it uses ports 10000 higher. Start it with:
#                                docker compose --env-file config-b/compose.env up -d
set -euo pipefail
cd "$(dirname "$0")"

# The Docker Hub version to use when there's no release folder.
DEFAULT_VERSION=5.8-RELEASE-92

instance=""
if [[ "${1:-}" == "--instance" ]]; then
  instance=${2:?Usage: ./setup.sh --instance <name>}
  [[ "$instance" =~ ^[a-z0-9]+$ ]] || { echo "Use lower-case letters and numbers for the name." >&2; exit 1; }
fi
config=config${instance:+-$instance}

# 0. A second server starts from a copy of the first one's settings, with its
# own certificate authority, so it's a separate organization.
if [[ -n "$instance" && ! -f "$config/takserver.env" ]]; then
  mkdir -p "$config/federation"
  upper=$(echo "$instance" | tr '[:lower:]' '[:upper:]')
  # Keep the location and address settings. Start with no users, certificates,
  # groups, lockouts or federation: those belong to the first server.
  sed -e "s/^CA_NAME=.*/CA_NAME=TAK-STACK-$upper-CA/" \
      -e "s/^ORGANIZATION=.*/ORGANIZATION=TAKStack-$upper/" \
      -e "s/^USERS=.*/USERS=/" \
      -e "s/^CLIENT_CERTS=.*/CLIENT_CERTS=/" \
      -e "s/^USER_GROUPS=.*/USER_GROUPS=/" \
      -e "s/^REVOKE=.*/REVOKE=/" \
      -e "s/^FEDERATION=.*/FEDERATION=false/" \
      -e "s/^FEDERATE_WITH=.*/FEDERATE_WITH=/" \
      -e "s/^FEDERATION_SHARE=.*/FEDERATION_SHARE=__ANON__/" \
      -e "s/^FEDERATION_RECEIVE=.*/FEDERATION_RECEIVE=__ANON__/" \
      config/takserver.env > "$config/takserver.env"
  echo "Settings:    created $config/takserver.env, with CA_NAME=TAK-STACK-$upper-CA and no users yet"
fi

# 1. Passwords: created once, never changed.
secrets=$config/secrets.env
if [[ -f "$secrets" ]]; then
  echo "Passwords:   keeping existing $secrets"
else
  umask 077
  while IFS= read -r line; do
    if [[ "$line" =~ ^([A-Z_]+)=$ ]]; then
      echo "${BASH_REMATCH[1]}=$(openssl rand -hex 16)"
    else
      echo "$line"
    fi
  done < config/secrets.env.example > "$secrets"
  umask 022
  echo "Passwords:   created $secrets"
fi

# 2. User passwords: one per user in USERS, added when a new user appears.
# TAK Server requires at least 15 characters, with upper and lower case letters,
# a number and a symbol.
users=$(grep -E '^USERS=' "$config/takserver.env" | cut -d= -f2-)
for user in $users; do
  key="USER_PASS_$(echo "$user" | tr '[:lower:]-' '[:upper:]_')"
  if ! grep -q "^$key=" "$secrets"; then
    echo "$key=Tak!$(openssl rand -hex 6)" >> "$secrets"
    echo "Passwords:   created a password for $user"
  fi
done

# 3. Version: read from the release, so it always matches.
if [[ -f release/tak/version.txt ]]; then
  version=$(tr -d '[:space:]' < release/tak/version.txt)
  echo "Release:     found TAK Server $version in release/"
else
  version=$DEFAULT_VERSION
  echo "Release:     none in release/. That's fine for the Docker Hub images."
fi

if [[ -n "$instance" ]]; then
  # A second server: its own project name, settings folder and ports.
  cat > "$config/compose.env" <<EOF
TAK_VERSION=$version
COMPOSE_PROJECT_NAME=takserver-$instance
TAK_CONFIG=$config
STREAMING_PORT=18089
WEB_PORT=18443
ENROLL_PORT=18446
FEDERATION_PORT=19001
EOF
  echo "Version:     TAK_VERSION=$version, in $config/compose.env"
  echo
  echo "Ready. Start this second server with:"
  echo "  docker compose --env-file $config/compose.env up -d"
  echo "It uses ports 18089, 18443, 18446 and 19001."
  exit 0
fi

echo "TAK_VERSION=$version" > .env
echo "Version:     TAK_VERSION=$version"

echo
if [[ -f release/tak/version.txt ]]; then
  echo "Ready. Start TAK Server with:"
  echo "  docker compose up -d --build"
else
  echo "Ready. To use the Docker Hub images, start TAK Server with:"
  echo "  docker compose -f compose.yaml -f compose.dockerhub.yaml up -d"
  echo
  echo "To build from the tak.gov release instead, copy it into release/ and run ./setup.sh again."
fi
