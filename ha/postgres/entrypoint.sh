#!/bin/bash
set -e

CONFIG_FILE="/etc/patroni/patroni.yml"
RENDERED_CONFIG="/tmp/patroni-rendered.yml"

sed "s/\${POSTGRES_PASSWORD}/${POSTGRES_PASSWORD}/g" "$CONFIG_FILE" > "$RENDERED_CONFIG"
chmod 600 "$RENDERED_CONFIG"

mkdir -p /var/lib/postgresql/data/patroni
chmod 700 /var/lib/postgresql/data/patroni
chown -R postgres:postgres /var/lib/postgresql/data

mkdir -p /var/run/postgresql
chown -R postgres:postgres /var/run/postgresql

chown postgres:postgres "$RENDERED_CONFIG"

exec gosu postgres patroni "$RENDERED_CONFIG"
