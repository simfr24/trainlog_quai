"""Builds the stations from the raw tables of the import (osm2pgsql, into Postgres's raw
schema) in DuckDB, then publishes what the API reads to Postgres's live schema, typed and
indexed for it. Published to a build schema first, swapped in for live in one transaction, so
the API keeps answering from the previous build throughout.

Steps are the sections of build.sql that start with "-- @step <label>"; one made of a
"-- @python <function>" line runs that function of this file instead, and one holding
{part} runs once per core at once, on a cursor each, with {part} its number and {parts}
their count, to do its share: DuckDB splits a table between its threads by 122,880 rows, so a
few thousand heavy rows (boundaries to cut) would otherwise go to one. "{raw}" in build.sql is
the raw schema, "{here}" this directory, for places.csv and countries.geojson.

Postgres is reached as libpq's environment says (PGHOST, PGUSER...).
"""

import csv
import json
import os
import re
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from multiprocessing import Pool

import duckdb
import psycopg

from latin import latin_name
from usage import follow_redirects

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD_SQL = os.path.join(HERE, "build.sql")
TIMINGS = os.path.join(HERE, ".build_timings.json")
# The import's tables, and where the build is published: built in <schema>_build first.
RAW = os.environ.get("QUAI_RAW_SCHEMA", "raw")
SCHEMA = os.environ.get("QUAI_SCHEMA", "live")
CORES = os.cpu_count() or 8

# Names wholly in these ranges (Latin letters, punctuation, digits) are their own Latin name
# unless int_name says otherwise; only the others need latin_name(). As characters, not
# escapes: DuckDB's regular expressions are RE2's.
NON_LATIN = "[^\u0001-ɏḀ-ỿ -⁯]"


def merge_groups(con):
    """The groups of same-named stations within 400m of each other (near_pairs, build.sql),
    each taking the smallest key among them: every key takes its neighbours' smallest until
    none changes, as chains of them are one group."""
    con.execute("""
        CREATE TABLE edges AS
        SELECT mode, a AS key, b AS other FROM near_pairs
        UNION ALL SELECT mode, b, a FROM near_pairs
    """)
    con.execute("CREATE TABLE labels AS SELECT DISTINCT mode, key, key AS label FROM edges")
    while True:
        con.execute("""
            CREATE OR REPLACE TABLE next_labels AS
            SELECT l.mode, l.key, least(l.label, min(o.label)) AS label
            FROM labels l
            JOIN edges e ON e.mode = l.mode AND e.key = l.key
            JOIN labels o ON o.mode = e.mode AND o.key = e.other
            GROUP BY l.mode, l.key, l.label
        """)
        changed = con.execute("""
            SELECT count(*) FROM next_labels n JOIN labels l USING (mode, key)
            WHERE n.label <> l.label
        """).fetchone()[0]
        con.execute("DROP TABLE labels")
        con.execute("ALTER TABLE next_labels RENAME TO labels")
        if not changed:
            break
    con.execute("""
        UPDATE station_objects o SET key = l.label
        FROM labels l
        WHERE o.mode = l.mode AND o.key = l.key AND l.label <> l.key
    """)
    con.execute("DROP TABLE labels")
    con.execute("DROP TABLE edges")
    con.execute("DROP TABLE near_pairs")
    con.execute("DROP TABLE named")


def load_rows(con, table, columns, rows):
    """Rows from Python into a new table, through a CSV file: DuckDB takes those on all cores,
    and inserts one by one slowly."""
    with tempfile.NamedTemporaryFile("w", suffix=".csv", newline="", encoding="utf-8",
                                     delete=False) as f:
        csv.writer(f).writerows(rows)
    try:
        con.execute(f"CREATE TABLE {table} AS SELECT * FROM read_csv(?, auto_detect = false,"
                    f" header = false, delim = ',', quote = '\"', escape = '\"',"
                    f" columns = {columns})", [f.name])
    finally:
        os.unlink(f.name)


def station_latin(row):
    station_id, names, country = row
    return station_id, latin_name(names, country)


def latin_names(con):
    """Each station's international Latin-script name, for display and search, romanised on
    every core (quai's latin.py)."""
    rows = con.execute(
        "SELECT station_id, names, country FROM stations"
        " WHERE NOT map_contains(names, 'int_name') AND regexp_matches(name, ?)",
        [NON_LATIN],
    ).fetchall()
    with Pool(CORES) as pool:
        latin = pool.map(station_latin, rows, chunksize=1000)
    load_rows(con, "latin", "{'station_id': 'INTEGER', 'latin': 'VARCHAR'}", latin)
    con.execute("""
        UPDATE stations s SET latin = COALESCE(l.latin, s.names['int_name'], s.name)
        FROM (SELECT station_id FROM stations) x
        LEFT JOIN latin l USING (station_id)
        WHERE s.station_id = x.station_id
    """)
    con.execute("DROP TABLE latin")


def place_latin(row):
    name, country = row
    return name, country, latin_name({"name": name}, country)


def place_latin_names(con):
    """A Latin name for each place of a station named in another script with no English name,
    for the API to show readers of Latin script: 荷花池街道 is Hehuachijiedao."""
    for column in ("city", "settlement", "region"):
        rows = con.execute(
            f"SELECT DISTINCT {column}['name'], country FROM stations"
            f" WHERE NOT map_contains({column}, 'name:en') AND regexp_matches({column}['name'], ?)",
            [NON_LATIN],
        ).fetchall()
        with Pool(CORES) as pool:
            latin = pool.map(place_latin, rows, chunksize=100)
        load_rows(con, "place_latin",
                  "{'name': 'VARCHAR', 'country': 'VARCHAR', 'latin': 'VARCHAR'}", latin)
        con.execute(f"""
            UPDATE stations s SET {column} = map_concat(s.{column}, MAP {{'latin': l.latin}})
            FROM place_latin l
            WHERE s.{column}['name'] = l.name AND s.country IS NOT DISTINCT FROM l.country
              AND NOT map_contains(s.{column}, 'name:en') AND l.latin <> l.name
        """)
        con.execute("DROP TABLE place_latin")


def postgres():
    return psycopg.connect(autocommit=True)


# What the API needs of Postgres besides the tables: the folding it compares queries with
# names on (build.sql's search_fold), and the indexes' extensions. In public, which the build
# does not replace.
POSTGRES_SETUP = """
    CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA public;
    CREATE EXTENSION IF NOT EXISTS unaccent SCHEMA public;
    CREATE OR REPLACE FUNCTION public.fold(text) RETURNS text AS $$
        SELECT lower(public.unaccent('public.unaccent'::regdictionary, COALESCE($1, '')))
    $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
    CREATE OR REPLACE FUNCTION public.search_fold(text) RETURNS text AS $$
        SELECT trim(regexp_replace(
            regexp_replace(public.fold($1), '[''’]', '', 'g'),
            '[^[:alnum:]]+', ' ', 'g'))
    $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
"""


def concurrently(statements):
    """Run independent Postgres statements at the same time, each on a connection of its own:
    an index builds on one connection, some (GiST, GIN) on one core."""
    def run(statement):
        with postgres() as conn:
            conn.execute(statement)

    with ThreadPoolExecutor(max(1, len(statements))) as pool:
        for future in [pool.submit(run, statement) for statement in statements]:
            future.result()


# What the API reads, written by DuckDB as Postgres takes them (JSON as text, points as WKB),
# then typed as quai's in Postgres.
TO_POSTGRES = {
    "stations": """
        SELECT station_id, mode, key, osm_type, osm_id, name, to_json(names)::VARCHAR AS names,
               wikidata, uic_ref, ST_AsWKB(geom) AS geom,
               '[' || array_to_string(list_transform(objects, lambda o:
                   '["' || o.type || '", ' || o.id || ']'), ', ') || ']' AS objects,
               country, to_json(region)::VARCHAR AS region, to_json(city)::VARCHAR AS city,
               city_override, to_json(lines)::VARCHAR AS lines, to_json(tracks)::VARCHAR AS tracks,
               station_key, weight, latin, boundary_ids, line_name, ski_area, lift_end,
               to_json(settlement)::VARCHAR AS settlement, needs_place
        FROM stations""",
    "station_objects": """
        SELECT mode, key, osm_type, osm_id, to_json(tags)::VARCHAR AS tags, ST_AsWKB(geom) AS geom,
               is_primary, source_key
        FROM station_objects""",
    "station_names": "SELECT station_id, mode, name, city_prefixed, place FROM station_names",
    "rel_members": "SELECT relation_id, is_stop_area, route, osm_type, osm_id, role, seq FROM rel_members",
    "route_stops": "SELECT relation_id, seq, osm_type, osm_id FROM route_stops",
    "line_routes": "SELECT relation_id, mode, to_json(tags)::VARCHAR AS tags FROM line_routes",
}

TYPED = {
    "stations": """
        SELECT station_id, mode, key, osm_type::char(1) AS osm_type, osm_id, name,
               names::jsonb AS names, wikidata, uic_ref,
               ST_SetSRID(ST_GeomFromWKB(geom), 4326)::geometry(Point, 4326) AS geom,
               objects::jsonb AS objects, country, region::jsonb AS region, city::jsonb AS city,
               city_override, lines::jsonb AS lines, tracks::jsonb AS tracks, station_key, weight,
               latin, boundary_ids, line_name, ski_area, lift_end,
               settlement::jsonb AS settlement, needs_place
        FROM stations_raw""",
    "station_objects": """
        SELECT mode, key, osm_type::char(1) AS osm_type, osm_id, tags::jsonb AS tags,
               ST_SetSRID(ST_GeomFromWKB(geom), 4326)::geometry(Point, 4326) AS geom,
               is_primary, source_key
        FROM station_objects_raw""",
    # char(1) like osm2pgsql's own osm_type: a text one defeats the indexes on joins.
    "rel_members": """
        SELECT relation_id, is_stop_area, route, osm_type::char(1) AS osm_type, osm_id, role, seq
        FROM rel_members_raw""",
    "route_stops": """
        SELECT relation_id, seq, osm_type::char(1) AS osm_type, osm_id FROM route_stops_raw""",
    "line_routes": "SELECT relation_id, mode, tags::jsonb AS tags FROM line_routes_raw",
    # The import's own, which the API reads too.
    "stops": f"SELECT * FROM {RAW}.stops",
    "rels": f"SELECT * FROM {RAW}.rels",
}

# Named: two built at once would take the same name.
INDEXES = [
    "CREATE UNIQUE INDEX stations_station_id_key ON stations (station_id)",
    "CREATE UNIQUE INDEX stations_mode_station_key_idx ON stations (mode, station_key)",
    "CREATE INDEX stations_geom_idx ON stations USING gist (geom)",
    "CREATE INDEX stations_geography_idx ON stations USING gist ((geom::geography))",
    "CREATE INDEX stations_objects_idx ON stations USING gin (objects jsonb_path_ops)",
    "CREATE INDEX stations_mode_idx ON stations (mode)",
    "CREATE INDEX stations_mode_key_idx ON stations (mode, key)",
    "CREATE INDEX station_objects_mode_key_idx ON station_objects (mode, key)",
    "CREATE INDEX station_objects_osm_idx ON station_objects (osm_type, osm_id)",
    "CREATE INDEX stops_osm_id_idx ON stops (osm_type, osm_id)",
    "CREATE INDEX rels_relation_id_idx ON rels (relation_id)",
    "CREATE INDEX rel_members_osm_idx ON rel_members (osm_type, osm_id)",
    "CREATE INDEX rel_members_relation_idx ON rel_members (relation_id)",
    "CREATE INDEX route_stops_osm_idx ON route_stops (osm_type, osm_id)",
    "CREATE INDEX route_stops_relation_idx ON route_stops (relation_id, seq)",
    "CREATE INDEX line_routes_relation_idx ON line_routes (relation_id)",
]


def publish(con):
    """What the API reads, into Postgres's <schema>_build schema, which then replaces the live
    one in one transaction: built and indexed on separate connections at once, as an index
    builds on one, some (GiST, GIN) on one core."""
    with postgres() as conn:
        conn.execute(POSTGRES_SETUP)
        conn.execute(f"DROP SCHEMA IF EXISTS {SCHEMA}_build CASCADE; CREATE SCHEMA {SCHEMA}_build")

    def write(table):
        con.cursor().execute(f"CREATE TABLE pg.{SCHEMA}_build.{table}_raw AS {TO_POSTGRES[table]}")

    with ThreadPoolExecutor(len(TO_POSTGRES)) as pool:
        list(pool.map(write, TO_POSTGRES))

    in_build = f"SET search_path = {SCHEMA}_build, public; "
    modes = [mode for (mode,) in con.execute("SELECT DISTINCT mode FROM station_names").fetchall()]
    concurrently([in_build + f"CREATE TABLE {table} AS {sql}" for table, sql in TYPED.items()] + [
        in_build + f"""CREATE TABLE station_names_{mode} AS
            SELECT station_id::integer, mode::text, name::text, city_prefixed, place::text,
                   search_fold(name) AS folded
            FROM station_names_raw WHERE mode = '{mode}'""" for mode in modes])
    # DuckDB's text arrives as varchar, which the API's queries compare with text.
    with postgres() as conn:
        varchar = conn.execute("""
            SELECT table_name, string_agg(format('ALTER COLUMN %%I TYPE text', column_name), ', ')
            FROM information_schema.columns
            WHERE table_schema = %s AND data_type = 'character varying'
            GROUP BY table_name
        """, (f"{SCHEMA}_build",)).fetchall()
    concurrently([in_build + f"ALTER TABLE {table} {changes}" for table, changes in varchar])
    concurrently([in_build + statement for statement in INDEXES] + [
        in_build + statement for mode in modes for statement in (
            f"CREATE INDEX station_names_{mode}_trgm_idx ON station_names_{mode} USING gin (folded gin_trgm_ops)",
            f"CREATE INDEX station_names_{mode}_prefix_idx ON station_names_{mode} (folded text_pattern_ops)",
            f"CREATE INDEX station_names_{mode}_station_idx ON station_names_{mode} (station_id)")])

    with postgres() as conn:
        conn.execute(f"SET search_path = {SCHEMA}_build, public")
        conn.execute("DROP TABLE " + ", ".join(f"{table}_raw" for table in TO_POSTGRES))
        conn.execute("ALTER TABLE stations ADD CONSTRAINT stations_pkey PRIMARY KEY"
                     " USING INDEX stations_station_id_key")
        # One table per mode, so that a search reads its mode's names only.
        conn.execute("""
            CREATE TABLE station_names (
                station_id integer, mode text, name text, city_prefixed boolean, place text,
                folded text
            ) PARTITION BY LIST (mode)
        """)
        for mode in modes:
            conn.execute(f"ALTER TABLE station_names ATTACH PARTITION station_names_{mode}"
                         f" FOR VALUES IN ('{mode}')")
        conn.execute("CREATE INDEX ON station_names USING gin (folded gin_trgm_ops)")
        conn.execute("CREATE INDEX ON station_names (folded text_pattern_ops)")
        conn.execute("CREATE INDEX ON station_names (station_id)")
        key_redirects(conn)
        conn.execute("CREATE UNIQUE INDEX ON key_redirects (mode, old_key)")
        concurrently([f"ANALYZE {SCHEMA}_build.{table}" for (table,) in conn.execute(
            "SELECT tablename FROM pg_tables WHERE schemaname = %s", (f"{SCHEMA}_build",))])
        with conn.transaction():
            conn.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
            conn.execute(f"ALTER SCHEMA {SCHEMA}_build RENAME TO {SCHEMA}")
        if SCHEMA == "live":
            # Trainlog's usage counts (usage.py) follow the stations whose keys this build moved.
            follow_redirects(conn)
            prewarm(conn)


def prewarm(conn):
    """Load what searches read into memory, as the disk may be a hard drive."""
    conn.execute("CREATE EXTENSION IF NOT EXISTS pg_prewarm SCHEMA public")
    conn.execute("""
        SELECT public.pg_prewarm(c.oid)
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'live' AND c.relkind IN ('r', 'i')
          AND (c.relname LIKE 'station_names%' OR c.relname LIKE 'stations%'
               OR c.relname LIKE 'key_redirects%')
    """)


def key_redirects(conn):
    """Where each key Trainlog may have stored and this build no longer has now leads: the
    station holding most of its old station's objects; keys already redirected are carried
    over the same way. A station gone with all its objects leaves no redirect: Trainlog keeps
    the trip's own name and position."""
    previous = conn.execute(
        "SELECT 1 FROM information_schema.tables WHERE table_schema = %s AND table_name = 'key_redirects'",
        (SCHEMA,)).fetchone()
    if not previous:
        conn.execute("CREATE TABLE key_redirects (mode text, old_key text, new_key text)")
        return
    conn.execute(f"""
        CREATE TABLE key_redirects AS
        WITH old_keys AS (
            SELECT mode, station_key AS old_key, station_key AS live_key FROM {SCHEMA}.stations
            UNION ALL SELECT mode, old_key, new_key FROM {SCHEMA}.key_redirects
        ),
        vanished AS (
            SELECT o.* FROM old_keys o
            WHERE NOT EXISTS (
                SELECT 1 FROM stations b WHERE b.mode = o.mode AND b.station_key = o.old_key)
        ),
        moved AS (
            SELECT DISTINCT ON (ls.mode, ls.station_key)
                   ls.mode, ls.station_key AS live_key, bs.station_key AS new_key
            FROM (SELECT DISTINCT mode, live_key FROM vanished) v
            JOIN {SCHEMA}.stations ls ON ls.mode = v.mode AND ls.station_key = v.live_key
            JOIN {SCHEMA}.station_objects lo ON lo.mode = ls.mode AND lo.key = ls.key
            JOIN station_objects bo
              ON bo.mode = lo.mode AND bo.osm_type = lo.osm_type AND bo.osm_id = lo.osm_id
            JOIN stations bs ON bs.mode = bo.mode AND bs.key = bo.key
            GROUP BY ls.mode, ls.station_key, bs.station_key
            ORDER BY ls.mode, ls.station_key, count(*) DESC, bs.station_key
        )
        SELECT DISTINCT ON (v.mode, v.old_key)
               v.mode::text AS mode, v.old_key::text AS old_key,
               COALESCE(b.station_key, m.new_key)::text AS new_key
        FROM vanished v
        LEFT JOIN stations b ON b.mode = v.mode AND b.station_key = v.live_key
        LEFT JOIN moved m ON m.mode = v.mode AND m.live_key = v.live_key
        WHERE COALESCE(b.station_key, m.new_key) IS NOT NULL
        ORDER BY v.mode, v.old_key, (v.old_key = v.live_key) DESC
    """)


def in_parts(con, sql):
    def run(part):
        con.cursor().execute(sql.replace("{parts}", str(CORES)).replace("{part}", str(part)))

    with ThreadPoolExecutor(CORES) as pool:
        list(pool.map(run, range(CORES)))


def load_steps(path):
    steps, label, lines = [], None, []
    for line in open(path, encoding="utf-8"):
        match = re.match(r"--\s*@step\s+(.+)", line)
        if match:
            steps.append((label, "".join(lines)))
            label, lines = match.group(1).strip(), []
        else:
            lines.append(line)
    steps.append((label, "".join(lines)))
    return [(label, sql.replace("{here}", HERE).replace("{raw}", RAW)) for label, sql in steps
            if re.sub(r"--[^\n]*", "", sql).strip() or re.search(r"--\s*@python\s+\w+", sql)]


def duration(seconds):
    minutes, seconds = divmod(seconds, 60)
    return f"{int(minutes)}m{seconds:04.1f}s" if minutes else f"{seconds:.1f}s"


def main():
    con = duckdb.connect()
    con.execute(f"SET threads = {CORES}")
    con.execute(f"SET temp_directory = '{os.path.join(HERE, '.tmp')}'")
    for extension in ("spatial", "postgres"):
        con.install_extension(extension)
        con.load_extension(extension)
    # Empty: libpq's environment says where, as for psycopg.
    con.execute("ATTACH '' AS pg (TYPE postgres)")

    timings = {}
    started = time.monotonic()
    for i, (label, sql) in enumerate(load_steps(BUILD_SQL) + [("publish", "-- @python publish")]):
        print(f"[{i + 1:2}] {label:<26}", end=" ", flush=True)
        step_started = time.monotonic()
        function = re.search(r"--\s*@python\s+(\w+)", sql)
        if function:
            globals()[function.group(1)](con)
        elif "{part}" in sql:
            in_parts(con, sql)
        else:
            con.execute(sql)
        timings[label] = time.monotonic() - step_started
        print(f"{duration(timings[label]):>8}", flush=True)

    total = time.monotonic() - started
    print(f"Built and live in {duration(total)}"
          f" ({duration(total - timings['load'] - timings['publish'])} without loading and publishing).")
    with open(TIMINGS, "w") as f:
        json.dump(timings, f, indent=1)


if __name__ == "__main__":
    main()
