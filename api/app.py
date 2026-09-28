"""Station search over the tables build.sql produces."""

import os
import re

from flask import Flask, jsonify, request
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

app = Flask(__name__)
pool = ConnectionPool(os.environ["DATABASE_URL"], kwargs={"row_factory": dict_row}, open=True)

COLUMNS = """
    s.station_id, s.mode, s.osm_type, s.osm_id, s.name, s.names, s.city, s.region, s.country,
    ST_Y(s.geom) AS lat, ST_X(s.geom) AS lng,
    s.wikidata, s.uic_ref, s.objects, s.lines
"""


def query(sql, params):
    with pool.connection() as conn:
        return conn.execute(sql, params).fetchall()


def point_params():
    lat, lon = request.args.get("lat", type=float), request.args.get("lon", type=float)
    return {"lat": lat, "lon": lon}


@app.get("/search")
def search():
    q = request.args.get("q", "").strip()
    if len(q) < 2:
        return jsonify(stations=[])
    params = {
        "q": q,
        "mode": request.args.get("mode"),
        "limit": min(request.args.get("limit", 10, type=int), 50),
        **point_params(),
    }
    # Prefix matches first, then trigram similarity; a given position breaks ties by distance.
    rows = query(
        f"""
        SELECT {COLUMNS}
        FROM (
            SELECT n.station_id,
                   bool_or(n.folded LIKE fold(%(q)s) || '%%') AS prefix,
                   max(similarity(n.folded, fold(%(q)s))) AS score
            FROM station_names n
            WHERE n.folded LIKE fold(%(q)s) || '%%' OR n.folded %% fold(%(q)s)
            GROUP BY n.station_id
        ) m
        JOIN stations s USING (station_id)
        WHERE %(mode)s::text IS NULL OR s.mode = %(mode)s
        ORDER BY m.prefix DESC, m.score DESC,
                 CASE WHEN %(lat)s::float8 IS NULL THEN 0
                      ELSE s.geom <-> ST_SetSRID(ST_MakePoint(%(lon)s::float8, %(lat)s::float8), 4326)
                 END,
                 s.name
        LIMIT %(limit)s
        """,
        params,
    )
    return jsonify(stations=rows)


@app.get("/reverse")
def reverse():
    params = {
        "mode": request.args.get("mode"),
        "radius": request.args.get("radius", 1, type=float) * 1000,
        "limit": min(request.args.get("limit", 10, type=int), 50),
        **point_params(),
    }
    if params["lat"] is None or params["lon"] is None:
        return jsonify(error="lat and lon are required"), 400
    rows = query(
        f"""
        SELECT {COLUMNS}, ST_Distance(s.geom::geography, p::geography) AS distance_m
        FROM stations s, ST_SetSRID(ST_MakePoint(%(lon)s, %(lat)s), 4326) AS p
        WHERE (%(mode)s::text IS NULL OR s.mode = %(mode)s)
          AND ST_DWithin(s.geom::geography, p::geography, %(radius)s)
        ORDER BY distance_m
        LIMIT %(limit)s
        """,
        params,
    )
    return jsonify(stations=rows)


@app.get("/object/<osm_type>/<int:osm_id>")
def osm_object(osm_type, osm_id):
    """The stations an OSM object belongs to, one per mode."""
    rows = query(
        f"""
        SELECT {COLUMNS}
        FROM stations s
        WHERE s.objects @> jsonb_build_array(jsonb_build_array(%(type)s::text, %(id)s::bigint))
        """,
        {"type": osm_type.upper(), "id": osm_id},
    )
    return jsonify(stations=rows)


def station_for_object(ref, mode):
    """The station of this mode containing an OSM object written "N27371862", or None."""
    if not ref or ref[0].upper() not in "NWR" or not ref[1:].isdigit():
        return None
    rows = query(
        """
        SELECT station_id FROM stations
        WHERE mode = %(mode)s
          AND objects @> jsonb_build_array(jsonb_build_array(%(type)s::text, %(id)s::bigint))
        LIMIT 1
        """,
        {"mode": mode, "type": ref[0].upper(), "id": int(ref[1:])},
    )
    return rows[0]["station_id"] if rows else None


# How many service variants to read stops for; enough to find the most direct.
MAX_SERVICE_VARIANTS = 20


@app.get("/line")
def line():
    """The lines, and for trains the services, running from one station to another, each
    with its stops in order.

    Stations are given by any of their OSM objects ("N27371862") and the mode. `ref` picks a
    line; `service` a train number, matched inside refs like "TGV 6033".

    Per line, the variant calling at the most stations in between: express and stopping
    services share tracks, and the stopping one names every station passed. Services are
    individual trains, so they come most direct first.
    """
    mode = request.args.get("mode")
    service = re.sub(r"\D", "", request.args.get("service") or "") or None
    params = {
        "from": station_for_object(request.args.get("from"), mode),
        "to": station_for_object(request.args.get("to"), mode),
        "mode": mode,
        "ref": request.args.get("ref"),
        "service": service,
    }
    if params["from"] is None or params["to"] is None:
        return jsonify(lines=[], services=[])

    # For each route calling at both, the stretch from the origin to the destination's
    # next call after it, so the direction is the one travelled.
    variants = query(
        """
        WITH ends AS (
            SELECT s.station_id, s.mode, o.osm_type, o.osm_id
            FROM stations s
            JOIN station_objects o ON o.mode = s.mode AND o.key = s.key
            WHERE s.station_id IN (%(from)s, %(to)s)
        ),
        from_pos AS (
            SELECT rm.relation_id, min(rm.seq) AS pf
            FROM route_stops rm
            JOIN ends e ON e.osm_type = rm.osm_type AND e.osm_id = rm.osm_id
            WHERE e.station_id = %(from)s
            GROUP BY rm.relation_id
        ),
        to_pos AS (
            SELECT rm.relation_id, min(rm.seq) AS pt
            FROM route_stops rm
            JOIN ends e ON e.osm_type = rm.osm_type AND e.osm_id = rm.osm_id
            JOIN from_pos f ON f.relation_id = rm.relation_id
            WHERE e.station_id = %(to)s AND rm.seq > f.pf
            GROUP BY rm.relation_id
        )
        SELECT r.relation_id, %(mode)s AS mode, r.tags, f.pf, t.pt,
               lr.relation_id IS NOT NULL AS is_line
        FROM from_pos f
        JOIN to_pos t USING (relation_id)
        JOIN rels r USING (relation_id)
        LEFT JOIN line_routes lr ON lr.relation_id = r.relation_id AND lr.mode = %(mode)s
        WHERE r.tags ? 'ref'
          AND (lr.relation_id IS NOT NULL OR (%(mode)s = 'train' AND r.tags ->> 'route' = 'train'))
          AND (%(ref)s::text IS NULL OR r.tags ->> 'ref' = %(ref)s)
          AND (%(service)s::text IS NULL
               OR r.tags ->> 'ref' ~ ('(^|[^0-9])' || %(service)s || '([^0-9]|$)'))
        ORDER BY is_line DESC, t.pt - f.pf
        """,
        params,
    )

    lines, services = {}, {}
    service_variants = 0
    for variant in variants:
        is_line = variant["is_line"]
        found = lines if is_line else services
        if not is_line:
            service_variants += 1
            if service_variants > MAX_SERVICE_VARIANTS:
                break
        stops = variant_stops(variant)
        tags = variant["tags"]
        ref = tags["ref"]
        # A line ref is only unique within its network; services sharing a ref ("OUIGo")
        # are told apart by name.
        key = (tags.get("network"), ref) if is_line else (ref, tags.get("name"))
        known = found.get(key)
        if known is None or (len(stops) > len(known["stops"])) == is_line:
            found[key] = {
                "ref": ref,
                "name": tags.get("name"),
                "network": tags.get("network"),
                "colour": tags.get("colour"),
                "stops": stops,
            }
    return jsonify(
        lines=sorted(lines.values(), key=lambda line: (len(line["ref"]), line["ref"])),
        services=sorted(services.values(), key=lambda service: len(service["stops"])),
    )


def variant_stops(variant):
    """The points of a route variant's calls between its two ends, in order.

    Its stop positions, which sit on the track, where it has them; the two ends are kept
    whatever they are, since they are where the trip starts and stops.
    """
    rows = query(
        """
        SELECT ST_Y(st.geom) AS lat, ST_X(st.geom) AS lng,
               (st.tags ->> 'public_transport' = 'stop_position') IS TRUE AS on_track
        FROM route_stops rm
        JOIN stops st ON st.osm_type = rm.osm_type AND st.osm_id = rm.osm_id
        WHERE rm.relation_id = %(relation_id)s AND rm.seq BETWEEN %(pf)s AND %(pt)s
        ORDER BY rm.seq
        """,
        variant,
    )
    middle = rows[1:-1]
    if any(row["on_track"] for row in middle):
        middle = [row for row in middle if row["on_track"]]
    return [{"lat": row["lat"], "lng": row["lng"]} for row in rows[:1] + middle + rows[-1:]]
