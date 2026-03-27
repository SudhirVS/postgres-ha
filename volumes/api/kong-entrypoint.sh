#!/bin/sh
set -e

sed \
  -e "s|\${SUPABASE_ANON_KEY}|${SUPABASE_ANON_KEY}|g" \
  -e "s|\${SUPABASE_SERVICE_KEY}|${SUPABASE_SERVICE_KEY}|g" \
  -e "s|\${DASHBOARD_USERNAME}|${DASHBOARD_USERNAME}|g" \
  -e "s|\${DASHBOARD_PASSWORD}|${DASHBOARD_PASSWORD}|g" \
  /home/kong/temp.yml > /usr/local/kong/kong.yml

# Start kong as daemon then tail logs to keep container alive
kong start --conf /usr/local/kong/kong.yml

exec tail -f /usr/local/kong/logs/error.log
