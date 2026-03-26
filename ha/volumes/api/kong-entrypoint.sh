#!/bin/sh
set -e

# Substitute environment variables manually (envsubst not available in kong image)
sed \
  -e "s|\${SUPABASE_ANON_KEY}|${SUPABASE_ANON_KEY}|g" \
  -e "s|\${SUPABASE_SERVICE_KEY}|${SUPABASE_SERVICE_KEY}|g" \
  -e "s|\${DASHBOARD_USERNAME}|${DASHBOARD_USERNAME}|g" \
  -e "s|\${DASHBOARD_PASSWORD}|${DASHBOARD_PASSWORD}|g" \
  /home/kong/temp.yml > /usr/local/kong/kong.yml

exec /docker-entrypoint.sh kong docker-start
