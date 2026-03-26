#!/bin/sh
set -e

# Substitute environment variables in kong.yml
envsubst < /home/kong/temp.yml > /usr/local/kong/kong.yml

exec /docker-entrypoint.sh kong docker-start
