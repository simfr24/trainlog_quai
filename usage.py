"""How many Trainlog users have used each station, for search to put the stations people use
first among those matching a search alike (api/app.py, USAGE_WEIGHT).

Trainlog exports it (scripts/export_station_usage.py) as a CSV of mode, station_key, users
(and trips, unused here). It is kept in the public schema, apart from the build's: a rebuild
replaces the stations, not this, and the keys it moved are followed (follow_redirects, run by
build.py once a build is live). Loading a new file replaces the old one.

    make usage USAGE=usage.csv
"""

import csv
import sys

import psycopg

TABLE = """
CREATE TABLE IF NOT EXISTS public.station_usage (
    mode text NOT NULL,
    station_key text NOT NULL,
    users integer NOT NULL,
    PRIMARY KEY (mode, station_key)
)
"""


def follow_redirects(conn):
    """Moves each count on to the key a build redirected its station's to (live.key_redirects),
    adding up those landing on one station."""
    conn.execute(TABLE)
    if conn.execute("SELECT to_regclass('live.key_redirects')").fetchone()[0] is None:
        return 0
    with conn.transaction():
        moved = conn.execute("""
            DELETE FROM public.station_usage u
            USING live.key_redirects r
            WHERE r.mode = u.mode AND r.old_key = u.station_key
            RETURNING r.mode, r.new_key, u.users
        """).fetchall()
        totals = {}
        for mode, key, users in moved:
            totals[(mode, key)] = totals.get((mode, key), 0) + users
        for (mode, key), users in totals.items():
            conn.execute("""
                INSERT INTO public.station_usage (mode, station_key, users) VALUES (%s, %s, %s)
                ON CONFLICT (mode, station_key)
                DO UPDATE SET users = station_usage.users + EXCLUDED.users
            """, (mode, key, users))
    return len(moved)


def load(path):
    """Replaces the counts with those in the CSV at `path`. Returns how many stations."""
    counts = {}
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            key = (row["mode"], row["station_key"])
            counts[key] = counts.get(key, 0) + int(row["users"])
    with psycopg.connect(autocommit=True) as conn:
        conn.execute(TABLE)
        with conn.transaction():
            conn.execute("TRUNCATE public.station_usage")
            with conn.cursor().copy(
                    "COPY public.station_usage (mode, station_key, users) FROM STDIN") as copy:
                for (mode, key), users in counts.items():
                    copy.write_row((mode, key, users))
        moved = follow_redirects(conn)
        conn.execute("ANALYZE public.station_usage")
    return len(counts), moved


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: usage.py FILE.csv")
    stations, moved = load(sys.argv[1])
    print(f"{stations} stations' usage loaded, {moved} moved on to their new keys.")
