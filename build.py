"""Run build.sql step by step, showing progress and an ETA.

Steps are the sections of build.sql that start with a "-- @step <label>" line. The ETA
comes from the previous successful run's step timings, scaled by the input file's size.
"""

import json
import os
import re
import sys
import threading
import time

import psycopg

BUILD_SQL = "/data/build.sql"
INPUT = "/data/filtered.osm.pbf"
TIMINGS = "/data/.build_timings.json"


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
    # Only sections holding SQL, not just comments.
    return [(label, sql) for label, sql in steps if re.sub(r"--[^\n]*", "", sql).strip()]


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

    def execute():
        try:
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
        for i, (label, sql) in enumerate(steps):
            def report(elapsed):
                if expected:
                    done = sum(expected[:i]) + min(elapsed, expected[i])
                    remaining = sum(expected[i + 1:]) + max(expected[i] - elapsed, 0)
                    progress = f"{done / sum(expected):4.0%}  ETA {duration(remaining)}"
                else:
                    progress = f"{i / len(steps):4.0%}"
                print(f"\r[{i + 1}/{len(steps)}] {label:<26} {duration(elapsed):>7}  {progress}   ",
                      end="", flush=True)

            try:
                timings[label] = run_step(conn, sql, report)
            except KeyboardInterrupt:
                # Otherwise the server keeps running the step and holds its tables.
                conn.cancel()
                raise
            report(timings[label])
            print()

    print(f"Built in {duration(time.monotonic() - build_started)}.")
    with open(TIMINGS, "w") as f:
        json.dump({"input_size": os.path.getsize(INPUT), "steps": timings}, f, indent=1)


if __name__ == "__main__":
    try:
        main()
    except psycopg.Error as e:
        print(f"\n{e}", file=sys.stderr)
        sys.exit(1)
