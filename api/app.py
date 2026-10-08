"""Station search over the tables build.sql produces."""

import math
import os
import re

from flask import Flask, jsonify, request
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

app = Flask(__name__)
pool = ConnectionPool(os.environ["DATABASE_URL"], kwargs={"row_factory": dict_row}, open=True)

COLUMNS = """
    s.station_id, s.station_key, s.mode, s.osm_type, s.osm_id, s.name, s.latin, s.names,
    s.city, s.region, s.country, ST_Y(s.geom) AS lat, ST_X(s.geom) AS lng,
    s.wikidata, s.uic_ref, s.objects, s.lines, s.tracks, s.weight
"""


def query(sql, params):
    with pool.connection() as conn:
        return conn.execute(sql, params).fetchall()


def point_params():
    lat, lon = request.args.get("lat", type=float), request.args.get("lon", type=float)
    return {"lat": lat, "lon": lon}


def with_labels(rows):
    """Add each station's `label`: its name in `lang` when asked for and mapped, else its
    international Latin-script name."""
    lang = request.args.get("lang")
    keys = [f"name:{lang}", f"name:{lang.split('-')[0]}"] if lang else []
    for row in rows:
        names = row["names"] or {}
        row["label"] = next((names[k] for k in keys if names.get(k)), None) \
            or row["latin"] or row["name"]
    return rows


@app.get("/search")
def search():
    q = request.args.get("q", "").strip()
    if len(q) < 2:
        return jsonify(stations=[])
    mode = request.args.get("mode")
    params = {
        "q": q,
        "mode": mode,
        "limit": min(request.args.get("limit", 10, type=int), 50),
        **point_params(),
    }
    # Under three letters nearly every name shares a trigram with the query, so only
    # prefixes count. A literal mode, not "mode IS NULL OR", lets the planner read only
    # that mode's partition.
    fuzzy = "OR search_fold(%(q)s) <%% n.folded" if len(q) >= 3 else ""
    mode_filter = "AND n.mode = %(mode)s" if mode else ""
    # Tiers, best first: the whole name; the start of one of the station's names; the start
    # of a word in one ("montparnasse" in "Gare Montparnasse"); the start of a city-prefixed
    # name ("berlin" in "Berlin Albrechtshof"); anything else matching. Within a tier the
    # more important station comes first, but fuzzy matches go by score before that.
    rows = query(
        f"""
        WITH matched AS (
            SELECT n.station_id, n.name,
                   CASE
                       WHEN n.city_prefixed THEN
                           CASE WHEN n.folded LIKE search_fold(%(q)s) || '%%' THEN 3 ELSE 4 END
                       WHEN n.folded = search_fold(%(q)s) THEN 0
                       WHEN n.folded LIKE search_fold(%(q)s) || '%%' THEN 1
                       WHEN ' ' || n.folded LIKE '%% ' || search_fold(%(q)s) || '%%' THEN 2
                       ELSE 4
                   END AS tier,
                   word_similarity(search_fold(%(q)s), n.folded) AS score
            FROM station_names n
            WHERE (n.folded LIKE search_fold(%(q)s) || '%%' {fuzzy}) {mode_filter}
        ),
        best AS (
            SELECT station_id, min(tier) AS tier, round(max(score)::numeric, 1) AS score,
                   (array_agg(name ORDER BY tier, score DESC, length(name)))[1] AS matched
            FROM matched
            GROUP BY station_id
        )
        SELECT {COLUMNS}, b.matched
        FROM best b
        JOIN stations s USING (station_id)
        ORDER BY b.tier,
                 CASE WHEN b.tier = 4 THEN b.score END DESC NULLS FIRST,
                 s.weight DESC,
                 CASE WHEN %(lat)s::float8 IS NULL THEN 0
                      ELSE s.geom <-> ST_SetSRID(ST_MakePoint(%(lon)s::float8, %(lat)s::float8), 4326)
                 END,
                 s.name
        LIMIT %(limit)s
        """,
        params,
    )
    return jsonify(stations=with_labels(rows))


@app.get("/station/<mode>/<key>")
def station(mode, key):
    """The station a key Trainlog stored leads to, following redirects of vanished keys."""
    rows = query(
        f"""
        SELECT {COLUMNS}
        FROM stations s
        WHERE s.mode = %(mode)s
          AND s.station_key IN (%(key)s, (SELECT new_key FROM key_redirects
                                          WHERE mode = %(mode)s AND old_key = %(key)s))
        ORDER BY s.station_key = %(key)s DESC
        LIMIT 1
        """,
        {"mode": mode, "key": key},
    )
    if not rows:
        return jsonify(error="unknown station"), 404
    station = with_labels(rows)[0]
    # Every OSM object grouped into the station, with its tags: what the grouping was made of.
    if request.args.get("objects"):
        station["osm_objects"] = query(
            """
            SELECT o.osm_type, o.osm_id, o.is_primary, o.tags,
                   ST_Y(o.geom) AS lat, ST_X(o.geom) AS lng
            FROM stations s
            JOIN station_objects o ON o.mode = s.mode AND o.key = s.key
            WHERE s.station_id = %(station_id)s
            ORDER BY o.is_primary DESC, o.osm_type, o.osm_id
            """,
            {"station_id": station["station_id"]},
        )
    return jsonify(station=station)


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
    return jsonify(stations=with_labels(rows))


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
    return jsonify(stations=with_labels(rows))


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

# A stop list is out of order, as some routes are mapped, when its path is this much longer
# than the straight line between the ends and one hop alone covers half of that line.
# The hop test keeps ring lines, whose path is long but made of short hops.
MAX_DETOUR = 1.8


def metres(a, b):
    lat1, lat2 = math.radians(a["lat"]), math.radians(b["lat"])
    dlat, dlng = lat2 - lat1, math.radians(b["lng"] - a["lng"])
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlng / 2) ** 2
    return 12742000 * math.asin(math.sqrt(h))


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

    # For each route calling at both, the stretch from the origin to the destination's next
    # call after it, so the direction is the one travelled. Routes in the older mapping
    # scheme (public_transport:version 1) are one relation for both directions, so for
    # them the destination may also come before the origin, and the stretch is read back.
    variants = query(
        """
        WITH ends AS (
            SELECT s.station_id, s.mode, o.osm_type, o.osm_id
            FROM stations s
            JOIN station_objects o ON o.mode = s.mode AND o.key = s.key
            WHERE s.station_id IN (%(from)s, %(to)s)
        ),
        calls AS (
            SELECT rm.relation_id, rm.seq, e.station_id
            FROM route_stops rm
            JOIN ends e ON e.osm_type = rm.osm_type AND e.osm_id = rm.osm_id
        ),
        origins AS (
            SELECT relation_id, min(seq) AS first_call, max(seq) AS last_call
            FROM calls WHERE station_id = %(from)s
            GROUP BY relation_id
        ),
        spans AS (
            SELECT o.relation_id, o.first_call AS low, min(c.seq) AS high, false AS reversed
            FROM origins o
            JOIN calls c ON c.relation_id = o.relation_id
                        AND c.station_id = %(to)s AND c.seq > o.first_call
            GROUP BY o.relation_id, o.first_call
            UNION ALL
            SELECT o.relation_id, max(c.seq) AS low, o.last_call AS high, true AS reversed
            FROM origins o
            JOIN rels r ON r.relation_id = o.relation_id
            JOIN calls c ON c.relation_id = o.relation_id
                        AND c.station_id = %(to)s AND c.seq < o.last_call
            WHERE COALESCE(r.tags ->> 'public_transport:version', '1') <> '2'
            GROUP BY o.relation_id, o.last_call
        )
        SELECT r.relation_id, %(mode)s AS mode, r.tags, sp.low, sp.high, sp.reversed,
               lr.relation_id IS NOT NULL AS is_line
        FROM spans sp
        JOIN rels r USING (relation_id)
        LEFT JOIN line_routes lr ON lr.relation_id = r.relation_id AND lr.mode = %(mode)s
        WHERE r.tags ? 'ref'
          AND (lr.relation_id IS NOT NULL OR (%(mode)s = 'train' AND r.tags ->> 'route' = 'train'))
          AND (%(ref)s::text IS NULL OR r.tags ->> 'ref' = %(ref)s)
          AND (%(service)s::text IS NULL
               OR r.tags ->> 'ref' ~ ('(^|[^0-9])' || %(service)s || '([^0-9]|$)'))
        ORDER BY is_line DESC, sp.high - sp.low
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

    Platforms are left out, as they sit beside the track rather than on it; every other
    call is kept, whether mapped as a stop position or as the station itself. The two ends
    are kept whatever they are, since they are where the trip starts and stops.
    """
    rows = query(
        """
        SELECT ST_Y(st.geom) AS lat, ST_X(st.geom) AS lng,
               (st.tags ->> 'public_transport' = 'platform' OR st.tags ->> 'railway' = 'platform')
                   IS TRUE AS platform
        FROM route_stops rm
        JOIN stops st ON st.osm_type = rm.osm_type AND st.osm_id = rm.osm_id
        WHERE rm.relation_id = %(relation_id)s AND rm.seq BETWEEN %(low)s AND %(high)s
        ORDER BY rm.seq
        """,
        variant,
    )
    if variant["reversed"]:
        rows.reverse()
    middle = [row for row in rows[1:-1] if not row["platform"]]
    stops = [{"lat": row["lat"], "lng": row["lng"]} for row in rows[:1] + middle + rows[-1:]]
    if len(stops) > 2:
        direct = metres(stops[0], stops[-1])
        hops = [metres(a, b) for a, b in zip(stops, stops[1:])]
        if sum(hops) > MAX_DETOUR * direct and max(hops) > direct / 2:
            return [stops[0], stops[-1]]
    return stops


# The tag marking a stop position as used by each mode ("train=yes").
MODE_TAGS = {
    "train": ["train"],
    "tram": ["tram", "light_rail"],
    "metro": ["subway", "light_rail", "monorail"],
    "bus": ["bus", "trolleybus"],
    "ferry": ["ferry"],
    "funicular": ["funicular"],
    "aerialway": ["aerialway"],
}
SNAP_RADIUS_M = 300


@app.post("/snap")
def snap():
    """Each point moved onto the nearest stop position of `mode`, or left where it is.

    Timetables often place a stop at the station building, which a router snaps onto the
    nearest track or road of any kind: the tram line in front of the station rather than the
    platforms. A stop position sits on the tracks or road the mode itself uses.
    """
    body = request.get_json(silent=True) or {}
    keys = MODE_TAGS.get(body.get("mode"))
    points = body.get("points") or []
    if not keys or not points:
        return jsonify(points=points)
    rows = query(
        """
        SELECT p.i, ST_Y(n.geom) AS lat, ST_X(n.geom) AS lng
        FROM unnest(%(lats)s::float8[], %(lngs)s::float8[]) WITH ORDINALITY AS p(lat, lng, i)
        CROSS JOIN LATERAL (
            SELECT st.geom
            FROM stops st
            WHERE st.geom && ST_Expand(ST_SetSRID(ST_MakePoint(p.lng, p.lat), 4326), 0.01)
              AND st.tags ->> 'public_transport' = 'stop_position'
              AND EXISTS (SELECT 1 FROM unnest(%(keys)s::text[]) AS k WHERE st.tags ->> k = 'yes')
              AND ST_DWithin(st.geom::geography,
                             ST_SetSRID(ST_MakePoint(p.lng, p.lat), 4326)::geography,
                             %(radius)s)
            ORDER BY st.geom <-> ST_SetSRID(ST_MakePoint(p.lng, p.lat), 4326)
            LIMIT 1
        ) n
        """,
        {
            "lats": [float(point["lat"]) for point in points],
            "lngs": [float(point["lng"]) for point in points],
            "keys": keys,
            "radius": SNAP_RADIUS_M,
        },
    )
    snapped = [dict(point) for point in points]
    for row in rows:
        snapped[row["i"] - 1] = {"lat": row["lat"], "lng": row["lng"]}
    return jsonify(points=snapped)
