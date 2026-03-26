#!/bin/bash
set -e

# Substitute password placeholder in init.sql and run it
sed "s/POSTGRES_PASSWORD_PLACEHOLDER/${POSTGRES_PASSWORD}/g" \
    /etc/patroni/init.sql | \
    psql -U postgres -d postgres
