#!/usr/bin/env bash
# Prepares this folder to run TAK Server. Safe to run as often as you like.
#   - Creates config/secrets.env with random passwords, if it doesn't exist.
#   - Adds a password for each new user in USERS.
#   - Sets TAK_VERSION in .env to match your release, if you have one.
set -euo pipefail
cd "$(dirname "$0")"

# The Docker Hub version to use when there's no release folder.
DEFAULT_VERSION=5.8-RELEASE-92

# 1. Passwords: created once, never changed.
secrets=config/secrets.env
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
users=$(grep -E '^USERS=' config/takserver.env | cut -d= -f2-)
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
