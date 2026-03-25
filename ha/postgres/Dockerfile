FROM postgres:15-bullseye

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-psycopg2 \
    curl \
    && pip3 install --no-cache-dir patroni[etcd3] \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Supabase-specific extensions (mirrors supabase/postgres image)
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-15-pg-safeupdate \
    postgresql-15-pgjwt \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5432 8008

ENTRYPOINT ["/entrypoint.sh"]
