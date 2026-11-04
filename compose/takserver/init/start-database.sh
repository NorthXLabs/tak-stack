#!/usr/bin/env bash
# Starts the TAK Server database, setting the password from configuration.
# Safe on every start.
set -euo pipefail
: "${POSTGRES_PASSWORD:?}"

# Some image builds ship with an empty data folder. Create the database
# cluster on first start if it isn't there yet.
if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
  echo "Creating database cluster in $PGDATA"
  initdb -D "$PGDATA" --no-locale -E UTF8
fi

export envpass="$POSTGRES_PASSWORD"
exec /opt/tak/db-utils/configureInDocker.sh
