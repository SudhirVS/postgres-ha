-- ============================================================
-- Supabase HA - Post-Bootstrap Initialization
-- Runs once on the primary after Patroni bootstraps the cluster.
-- Mirrors docker/volumes/db/* from the official Supabase repo.
-- ============================================================

-- Replication user (used by Patroni streaming replication)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
    CREATE USER replicator WITH REPLICATION LOGIN PASSWORD 'POSTGRES_PASSWORD_PLACEHOLDER';
  END IF;
END $$;

-- pg_rewind user (used by Patroni for rewind after failover)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rewind_user') THEN
    CREATE USER rewind_user WITH LOGIN PASSWORD 'POSTGRES_PASSWORD_PLACEHOLDER';
    GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text, boolean, boolean) TO rewind_user;
    GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean) TO rewind_user;
    GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text) TO rewind_user;
    GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO rewind_user;
  END IF;
END $$;

-- ============================================================
-- Supabase core roles (mirrors roles.sql)
-- ============================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_admin') THEN
    CREATE USER supabase_admin LOGIN CREATEROLE CREATEDB REPLICATION BYPASSRLS PASSWORD 'POSTGRES_PASSWORD_PLACEHOLDER';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_auth_admin') THEN
    CREATE USER supabase_auth_admin NOINHERIT CREATEROLE LOGIN NOREPLICATION PASSWORD 'POSTGRES_PASSWORD_PLACEHOLDER';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_storage_admin') THEN
    CREATE USER supabase_storage_admin NOINHERIT CREATEROLE LOGIN NOREPLICATION PASSWORD 'POSTGRES_PASSWORD_PLACEHOLDER';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_functions_admin') THEN
    CREATE USER supabase_functions_admin NOINHERIT CREATEROLE LOGIN NOREPLICATION PASSWORD 'POSTGRES_PASSWORD_PLACEHOLDER';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE USER authenticator NOINHERIT LOGIN PASSWORD 'POSTGRES_PASSWORD_PLACEHOLDER';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbouncer') THEN
    CREATE USER pgbouncer LOGIN PASSWORD 'POSTGRES_PASSWORD_PLACEHOLDER';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dashboard_user') THEN
    CREATE USER dashboard_user NOINHERIT CREATEROLE LOGIN PASSWORD 'POSTGRES_PASSWORD_PLACEHOLDER';
  END IF;
END $$;

GRANT anon, authenticated, service_role TO authenticator;
GRANT supabase_auth_admin TO postgres;
GRANT supabase_storage_admin TO postgres;
GRANT supabase_functions_admin TO postgres;
GRANT supabase_admin TO postgres;

-- ============================================================
-- Extensions schema (mirrors supabase/postgres image defaults)
-- ============================================================
CREATE SCHEMA IF NOT EXISTS extensions;
GRANT USAGE ON SCHEMA extensions TO postgres, anon, authenticated, service_role;

CREATE EXTENSION IF NOT EXISTS "uuid-ossp"    WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto       WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgjwt          WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA extensions;

-- ============================================================
-- _supabase database + schemas (mirrors _supabase.sql, logs.sql, pooler.sql)
-- ============================================================
SELECT 'CREATE DATABASE _supabase OWNER postgres'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '_supabase') \gexec

\c _supabase
CREATE SCHEMA IF NOT EXISTS _analytics;
ALTER SCHEMA _analytics OWNER TO postgres;
CREATE SCHEMA IF NOT EXISTS _supavisor;
ALTER SCHEMA _supavisor OWNER TO postgres;
\c postgres

-- ============================================================
-- Realtime schema (mirrors realtime.sql)
-- ============================================================
CREATE SCHEMA IF NOT EXISTS _realtime;
ALTER SCHEMA _realtime OWNER TO postgres;

-- ============================================================
-- pgbouncer auth function (required by Supavisor)
-- ============================================================
CREATE SCHEMA IF NOT EXISTS pgbouncer;
GRANT USAGE ON SCHEMA pgbouncer TO pgbouncer;

CREATE OR REPLACE FUNCTION pgbouncer.get_auth(p_usename TEXT)
RETURNS TABLE(username TEXT, password TEXT) AS $$
BEGIN
  RAISE WARNING 'PgBouncer auth request: %', p_usename;
  RETURN QUERY
    SELECT usename::TEXT, passwd::TEXT
    FROM pg_catalog.pg_shadow
    WHERE usename = p_usename;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE ALL ON FUNCTION pgbouncer.get_auth(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pgbouncer.get_auth(TEXT) TO pgbouncer;
