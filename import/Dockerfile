FROM debian:trixie-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends osm2pgsql postgresql-client python3 python3-psycopg python3-icu \
    && rm -rf /var/lib/apt/lists/*
