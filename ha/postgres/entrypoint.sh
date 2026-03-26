#!/bin/bash
set -e

CONFIG_FILE="/etc/patroni/patroni.yml"
RENDERED_CONFIG="/tmp/patroni-rendered.yml"

# Substitute ${POSTGRES_PASSWORD} in the Patroni config
sed "s/\${POSTGRES_PASSWORD}/${POSTGRES_PASSWORD}/g" "$CONFIG_FILE" > "$RENDERED_CONFIG"
chmod 600 "$RENDERED_CONFIG"

# Create data directory and set ownership to postgres user
mkdir -p /var/lib/postgresql/data/patroni
chown -R postgres:postgres /var/lib/postgresql/data

# Create unix socket directory
mkdir -p /var/run/postgresql
chown -R postgres:postgres /var/run/postgresql

# Give postgres user access to the rendered config
chown postgres:postgres "$RENDERED_CONFIG"

# Run Patroni as postgres user (initdb cannot run as root)
exec gosu postgres patroni "$RENDERED_CONFIG"
