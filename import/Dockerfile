FROM debian:trixie-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends osm2pgsql postgresql-client python3 python3-pip \
       python3-psycopg python3-icu python3-pypinyin ca-certificates \
    && rm -rf /var/lib/apt/lists/*
# DuckDB, which Debian does not package, and the extensions build.py loads, fetched now rather
# than on each build. The version build.py was written against.
RUN pip install --no-cache-dir --break-system-packages duckdb==1.5.6 \
    && python3 -c "import duckdb; c = duckdb.connect(); [c.install_extension(e) for e in ('spatial', 'postgres')]"
