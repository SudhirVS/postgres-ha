FROM postgres:15-bullseye

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-psycopg2 \
    curl \
    && pip3 install --no-cache-dir patroni[etcd3] \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
COPY post_bootstrap.sh /etc/patroni/post_bootstrap.sh
COPY init.sql /etc/patroni/init.sql

RUN chmod +x /entrypoint.sh /etc/patroni/post_bootstrap.sh

EXPOSE 5432 8008

ENTRYPOINT ["/entrypoint.sh"]
