#!/bin/bash
set -e

# Substitute environment variables in the Patroni config
CONFIG_FILE="/etc/patroni/patroni.yml"
RENDERED_CONFIG="/tmp/patroni-rendered.yml"

# Replace ${POSTGRES_PASSWORD} placeholders in the config
sed "s/\${POSTGRES_PASSWORD}/${POSTGRES_PASSWORD}/g" "$CONFIG_FILE" > "$RENDERED_CONFIG"

# Create the data directory with correct ownership
mkdir -p /var/lib/postgresql/data/patroni
chown -R postgres:postgres /var/lib/postgresql/data

# Create the unix socket directory
mkdir -p /var/run/postgresql
chown -R postgres:postgres /var/run/postgresql

exec patroni "$RENDERED_CONFIG"
