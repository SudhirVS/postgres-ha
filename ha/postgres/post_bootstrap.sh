#!/bin/bash
set -e

PG="psql -U postgres -h /var/run/postgresql"

echo ">>> Running Supabase init on postgres DB..."
sed "s/POSTGRES_PASSWORD_PLACEHOLDER/${POSTGRES_PASSWORD}/g" \
    /etc/patroni/init.sql | $PG -d postgres

echo ">>> Creating _supabase database..."
$PG -d postgres -tc "SELECT 1 FROM pg_database WHERE datname='_supabase'" \
    | grep -q 1 || $PG -d postgres -c "CREATE DATABASE _supabase OWNER postgres;"

echo ">>> Creating schemas in _supabase..."
$PG -d _supabase -c "
  CREATE SCHEMA IF NOT EXISTS _analytics;
  ALTER SCHEMA _analytics OWNER TO postgres;
  CREATE SCHEMA IF NOT EXISTS _supavisor;
  ALTER SCHEMA _supavisor OWNER TO postgres;
  GRANT ALL ON SCHEMA _analytics  TO supabase_admin;
  GRANT ALL ON SCHEMA _supavisor  TO supabase_admin;
"

echo ">>> Supabase post-bootstrap complete."
