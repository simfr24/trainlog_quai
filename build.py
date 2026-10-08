"""Run build.sql step by step, showing progress and an ETA, then put the result live.

Everything is built in the `build` schema, where osm2pgsql imported the raw tables, and
swapped in for `live` in one transaction at the end, so the API keeps answering from the
previous build throughout. With --reuse, the raw tables are copied from `live` first, to
rebuild without importing again.

Steps are the sections of build.sql that start with a "-- @step <label>" line; a step made
of a "-- @python <function>" line runs that function of this file instead. The ETA comes
from the previous successful run's step timings, scaled by the input file's size.
"""

import csv
import json
import os
import re
import sys
import threading
import time

import psycopg

from latin import latin_name

BUILD_SQL = "/data/build.sql"
INPUT = "/data/filtered.osm.pbf"
TIMINGS = "/data/.build_timings.json"
PLACES = "/data/places.csv"
RAW_TABLES = ("stops", "rels", "boundaries")

# For this session only: the API's connections keep the server defaults.
SESSION = """
    SET work_mem = '1GB';
    SET maintenance_work_mem = '4GB';
    SET max_parallel_workers_per_gather = 8;
    SET max_parallel_maintenance_workers = 4;
    SET synchronous_commit = off;
"""


# Names wholly in these ranges (Latin letters, punctuation, digits) are their own Latin name
# unless int_name says otherwise; only the others need latin_name().
NON_LATIN = r"[^\u0001-\u024F\u1E00-\u1EFF\u2000-\u206F]"


def latin_names(conn):
    """Each station's international Latin-script name, for display and search."""
    conn.execute("UPDATE stations SET latin = COALESCE(names ->> 'int_name', name)")
    with conn.transaction():
        cursor = conn.cursor(name="non_latin")
        cursor.execute(
            "SELECT station_id, names, country FROM stations"
            " WHERE NOT names ? 'int_name' AND name ~ %s",
            (NON_LATIN,),
        )
        rows = [(station_id, latin_name(names, country))
                for station_id, names, country in cursor]
    conn.execute("CREATE TEMP TABLE latin (station_id integer, latin text)")
    with conn.cursor().copy("COPY latin FROM STDIN") as copy:
        for row in rows:
            copy.write_row(row)
    conn.execute("UPDATE stations s SET latin = l.latin FROM latin l"
                 " WHERE s.station_id = l.station_id")
    conn.execute("DROP TABLE latin")


def load_city_overrides(conn):
    """The boundaries that are the city of the stations inside them, and their names: those
    places.csv lists (by relation id, or by admin level and name), then those tagged
    place=city at region level or below."""
    conn.execute("DROP TABLE IF EXISTS city_overrides")
    conn.execute("CREATE TABLE city_overrides (relation_id bigint PRIMARY KEY, name text, name_en text)")
    with open(PLACES, encoding="utf-8") as f:
        rows = list(csv.DictReader(line for line in f if line.strip() and not line.startswith("#")))
    for row in rows:
        conn.execute(
            """
            INSERT INTO city_overrides
            SELECT relation_id, %(name)s, %(name_en)s FROM boundaries
            WHERE relation_id = %(relation_id)s
               OR (%(relation_id)s IS NULL AND admin_level = %(admin_level)s
                   AND tags ->> 'name' = %(boundary_name)s)
            ON CONFLICT DO NOTHING
            """,
            {
                "relation_id": int(row["relation_id"]) if row["relation_id"] else None,
                "admin_level": int(row["admin_level"]) if row["admin_level"] else None,
                "boundary_name": row["boundary_name"] or None,
                "name": row["name"] or None,
                "name_en": row["name_en"] or None,
            },
        )
    conn.execute("""
        INSERT INTO city_overrides
        SELECT relation_id, NULL, NULL FROM boundaries
        WHERE admin_level BETWEEN 4 AND 7 AND tags ->> 'place' = 'city'
        ON CONFLICT DO NOTHING
    """)


def live_has(conn, table, column=None):
    return conn.execute(
        "SELECT 1 FROM information_schema.columns"
        " WHERE table_schema = 'live' AND table_name = %s AND (%s::text IS NULL OR column_name = %s)",
        (table, column, column),
    ).fetchone() is not None


def key_redirects(conn):
    """Where each key Trainlog may have stored and this build no longer has now leads.

    A key leads on to the build station holding most of its old station's objects; keys
    already redirected are carried over the same way. A station gone with all its objects
    leaves no redirect: Trainlog keeps the trip's own name and position.
    """
    conn.execute("CREATE TABLE key_redirects (mode text, old_key text, new_key text)")
    if not live_has(conn, "stations", "station_key"):
        return
    redirected = (
        "UNION ALL SELECT mode, old_key, new_key FROM live.key_redirects"
        if live_has(conn, "key_redirects") else ""
    )
    conn.execute(f"""
        WITH old_keys AS (
            SELECT mode, station_key AS old_key, station_key AS live_key FROM live.stations
            {redirected}
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
            JOIN live.stations ls ON ls.mode = v.mode AND ls.station_key = v.live_key
            JOIN live.station_objects lo ON lo.mode = ls.mode AND lo.key = ls.key
            JOIN station_objects bo
              ON bo.mode = lo.mode AND bo.osm_type = lo.osm_type AND bo.osm_id = lo.osm_id
            JOIN stations bs ON bs.mode = bo.mode AND bs.key = bo.key
            GROUP BY ls.mode, ls.station_key, bs.station_key
            ORDER BY ls.mode, ls.station_key, count(*) DESC, bs.station_key
        )
        INSERT INTO key_redirects
        SELECT DISTINCT ON (v.mode, v.old_key)
               v.mode, v.old_key, COALESCE(b.station_key, m.new_key)
        FROM vanished v
        LEFT JOIN stations b ON b.mode = v.mode AND b.station_key = v.live_key
        LEFT JOIN moved m ON m.mode = v.mode AND m.live_key = v.live_key
        WHERE COALESCE(b.station_key, m.new_key) IS NOT NULL
        ORDER BY v.mode, v.old_key, (v.old_key = v.live_key) DESC
    """)


def prewarm(conn):
    """Load what searches read into memory: the disk is a hard drive."""
    conn.execute("CREATE EXTENSION IF NOT EXISTS pg_prewarm SCHEMA public")
    conn.execute("""
        SELECT public.pg_prewarm(c.oid)
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'live' AND c.relkind IN ('r', 'i')
          AND (c.relname LIKE 'station_names%' OR c.relname LIKE 'stations%'
               OR c.relname LIKE 'key_redirects%')
    """)


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
    # Only sections holding SQL or a function to run, not just comments.
    return [(label, sql) for label, sql in steps
            if re.sub(r"--[^\n]*", "", sql).strip() or re.search(r"--\s*@python\s+\w+", sql)]


def duration(seconds):
    minutes, seconds = divmod(int(seconds), 60)
    return f"{minutes}m{seconds:02d}s" if minutes else f"{seconds}s"


def expected_timings(steps):
    """Each step's expected duration from the last run, or None if any is unknown."""
    try:
        with open(TIMINGS) as f:
            previous = json.load(f)
        scale = os.path.getsize(INPUT) / previous["input_size"]
        return [previous["steps"][label] * scale for label, _ in steps]
    except (OSError, ValueError, KeyError, ZeroDivisionError):
        return None


def run_step(conn, sql, report):
    """Run one step in a thread, calling report(elapsed) every second until it ends."""
    errors = []
    function = re.search(r"--\s*@python\s+(\w+)", sql)

    def execute():
        try:
            if function:
                globals()[function.group(1)](conn)
            else:
                conn.execute(sql)
        except Exception as e:
            errors.append(e)

    thread = threading.Thread(target=execute)
    started = time.monotonic()
    thread.start()
    while thread.is_alive():
        report(time.monotonic() - started)
        thread.join(1)
    if errors:
        raise errors[0]
    return time.monotonic() - started


def main():
    steps = load_steps(BUILD_SQL)
    expected = expected_timings(steps)
    timings = {}
    build_started = time.monotonic()

    with psycopg.connect(autocommit=True) as conn:
        if "--reuse" in sys.argv:
            conn.execute("DROP SCHEMA IF EXISTS build CASCADE; CREATE SCHEMA build")
            for table in RAW_TABLES:
                def report(elapsed):
                    print(f"\rcopying {table:<20} {duration(elapsed):>7}", end="", flush=True)

                report(run_step(conn, f"CREATE TABLE build.{table} (LIKE live.{table} INCLUDING ALL);"
                                      f"INSERT INTO build.{table} SELECT * FROM live.{table}", report))
                print()
        conn.execute(SESSION)
        conn.execute("SET search_path = build, public")

        for i, (label, sql) in enumerate(steps):
            def report(elapsed, finished=False):
                if expected:
                    done = (sum(expected[:i + 1]) if finished
                            else sum(expected[:i]) + min(elapsed, expected[i]))
                    remaining = sum(expected[i + 1:]) + max(expected[i] - elapsed, 0)
                    progress = f"{done / sum(expected):4.0%}  ETA {duration(remaining)}"
                else:
                    progress = f"{(i + finished) / len(steps):4.0%}"
                print(f"\r[{i + 1}/{len(steps)}] {label:<26} {duration(elapsed):>7}  {progress}   ",
                      end="", flush=True)

            try:
                timings[label] = run_step(conn, sql, report)
            except KeyboardInterrupt:
                # Otherwise the server keeps running the step and holds its tables.
                conn.cancel()
                raise
            report(timings[label], finished=True)
            print()

        # Needs the live build, so made last, just before it is replaced.
        print("redirecting vanished keys...", flush=True)
        key_redirects(conn)
        conn.execute("CREATE UNIQUE INDEX ON key_redirects (mode, old_key)")

        with conn.transaction():
            conn.execute("DROP SCHEMA IF EXISTS live CASCADE")
            conn.execute("ALTER SCHEMA build RENAME TO live")

        print("prewarming...", flush=True)
        prewarm(conn)

    print(f"Built and live in {duration(time.monotonic() - build_started)}.")
    with open(TIMINGS, "w") as f:
        json.dump({"input_size": os.path.getsize(INPUT), "steps": timings}, f, indent=1)


if __name__ == "__main__":
    try:
        main()
    except psycopg.Error as e:
        print(f"\n{e}", file=sys.stderr)
        sys.exit(1)
