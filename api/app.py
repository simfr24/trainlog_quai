"""Station search over the tables build.sql produces."""

import math
import os
import re
import unicodedata

from flask import Flask, jsonify, request
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

app = Flask(__name__)
# Each connection is checked before use: after the database restarts (a build changing its
# settings), the pool's old connections are dead, and each would otherwise fail one search.
pool = ConnectionPool(os.environ["DATABASE_URL"], kwargs={"row_factory": dict_row}, open=True,
                      check=ConnectionPool.check_connection)

COLUMNS = """
    s.station_id, s.station_key, s.mode, s.osm_type, s.osm_id, s.name, s.latin, s.names,
    s.city, s.region, s.country, ST_Y(s.geom) AS lat, ST_X(s.geom) AS lng,
    s.wikidata, s.uic_ref, s.objects, s.lines, s.tracks, s.weight, s.needs_place,
    s.line_name, s.ski_area, s.lift_end, s.settlement, s.city_override
"""


def query(sql, params):
    with pool.connection() as conn:
        return conn.execute(sql, params).fetchall()


def point_params():
    lat, lon = request.args.get("lat", type=float), request.args.get("lon", type=float)
    return {"lat": lat, "lon": lon}


# The scripts each language's readers read besides Latin, as Unicode names their letters: a
# name in them is shown as it is, rather than romanised.
SCRIPTS = {"zh": ("CJK",), "ja": ("CJK", "HIRAGANA", "KATAKANA"), "ko": ("HANGUL",),
           "ru": ("CYRILLIC",), "uk": ("CYRILLIC",)}
# The name:<code> tags to read a language from where it is not simply its own (and its base
# for a regional one, pt for pt-BR): Trainlog's Chinese is simplified, and Swiss German and
# Norwegian are mostly mapped as German and Bokmål.
LANG_KEYS = {"zh": ["zh-Hans", "zh"], "gsw": ["gsw", "de"], "no": ["no", "nb"]}


def readable(text, lang):
    """Whether readers of `lang` read every letter of `text`."""
    scripts = ("LATIN",) + SCRIPTS.get(lang, ())
    return all(unicodedata.name(ch, "").startswith(scripts) for ch in text or "" if ch.isalpha())


def in_lang(names, lang):
    if not lang:
        return None
    keys = LANG_KEYS.get(lang) or [lang, lang.split("-")[0]]
    return next((names[f"name:{k}"] for k in keys if names.get(f"name:{k}")), None)


def place_label(place, lang):
    """A place's name in `lang`, else its own if in the reader's script, else in Latin."""
    if not place:
        return None
    own = place.get("name") if readable(place.get("name"), lang) else None
    return (in_lang(place, lang) or own or place.get("name:en") or place.get("latin")
            or place.get("name"))


def with_labels(rows):
    """Add each station's `label`, in `lang` when asked for: its name in that language where
    mapped, else its own where in the reader's script (北京南 for Chinese and Japanese), else
    its international Latin-script name. Its city and settlement get theirs, and its region
    is given as its label alone."""
    lang = request.args.get("lang")
    for row in rows:
        names = row["names"] or {}
        own = row["name"] if lang in SCRIPTS and readable(row["name"], lang) else None
        row["label"] = in_lang(names, lang) or own or row["latin"] or row["name"]
        for key in ("city", "settlement"):
            if row.get(key):
                row[key]["label"] = place_label(row[key], lang)
        row["region"] = place_label(row.get("region"), lang)
    return rows


# How much distance (ln(1 + km)) weighs against importance (weights run from about 1 for a
# bus stop to 15 for a major terminus): 1 km away costs 1.4, 10 km 4.8, 500 km 12.4.
DISTANCE_PENALTY = 2.0
# What matching a station's whole name adds to its importance.
EXACT_BONUS = 2.0
# The word similarity a fuzzy match (no name starting with the query) needs to be offered;
# the index finds candidates from pg_trgm's 0.6.
FUZZY_MIN = 0.7
# What being used by Trainlog's users adds to importance, per ln(1 + users) (usage.py): a
# station a hundred people use gains 6.9, about a terminus's routes; one ten use, 3.6.
USAGE_WEIGHT = 1.5

# Loaded by usage.py, kept apart from the build's schema; there, if empty, before the first.
with pool.connection() as _conn:
    _conn.execute("""
        CREATE TABLE IF NOT EXISTS public.station_usage (
            mode text NOT NULL, station_key text NOT NULL, users integer NOT NULL,
            PRIMARY KEY (mode, station_key))
    """)


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
        "distance_penalty": DISTANCE_PENALTY,
        "exact_bonus": EXACT_BONUS,
        "fuzzy_min": FUZZY_MIN,
        "usage_weight": USAGE_WEIGHT,
        **point_params(),
    }
    # Under three letters nearly every name shares a trigram with the query, so only
    # prefixes count. A literal mode, not "mode IS NULL OR", lets the planner read only
    # that mode's partition.
    fuzzy = "OR search_fold(%(q)s) <%% n.folded" if len(q) >= 3 else ""
    mode_filter = "AND n.mode = %(mode)s" if mode else ""
    # Tiers, best first: whole words starting one of the station's names, city-prefixed or
    # not ("agen" in "Agen Gare", not in "Agence Commerciale": typing a city's name asks for
    # its stations, the whole of it: "central" is not Central Bedfordshire's); the start of one of the station's names (the whole name counts
    # EXACT_BONUS more importance, not a tier of its own: "Oslo", a stop in Alsace, is no
    # better an answer than Oslo bussterminal); the start of a word in one ("montparnasse" in
    # "Gare Montparnasse"); the start of a city-prefixed name ("berlin" in "Berlin
    # Albrechtshof"); anything else matching. Within a tier the more important station comes
    # first (its weight, and how many Trainlog users use it), but fuzzy matches go by score
    # before that. Given a
    # position (lat, lon), distance counts against importance: of the many stops named
    # "Poste", the one nearby, not the slightly busier one across the country.
    rows = query(
        f"""
        WITH matched AS (
            SELECT n.station_id, n.name,
                   CASE
                       WHEN (n.folded = search_fold(%(q)s)
                             OR n.folded LIKE search_fold(%(q)s) || ' %%')
                            AND (n.place IS NULL OR search_fold(%(q)s) = n.place
                                 OR search_fold(%(q)s) LIKE n.place || ' %%') THEN 0
                       WHEN n.city_prefixed THEN
                           CASE WHEN n.folded LIKE search_fold(%(q)s) || '%%' THEN 3 ELSE 4 END
                       WHEN n.folded LIKE search_fold(%(q)s) || '%%' THEN 1
                       WHEN ' ' || n.folded LIKE '%% ' || search_fold(%(q)s) || '%%' THEN 2
                       ELSE 4
                   END AS tier,
                   word_similarity(search_fold(%(q)s), n.folded) AS score,
                   NOT n.city_prefixed AND n.folded = search_fold(%(q)s) AS exact
            FROM station_names n
            WHERE (n.folded LIKE search_fold(%(q)s) || '%%' {fuzzy}) {mode_filter}
        ),
        best AS (
            SELECT station_id, min(tier) AS tier, round(max(score)::numeric, 1) AS score,
                   bool_or(exact) AS exact,
                   (array_agg(name ORDER BY tier, score DESC, length(name)))[1] AS matched
            FROM matched
            GROUP BY station_id
        )
        SELECT {COLUMNS}, b.matched, b.tier, b.score::float8 AS score,
               d.km AS distance_km
        FROM best b
        JOIN stations s USING (station_id)
        LEFT JOIN station_usage u ON u.mode = s.mode AND u.station_key = s.station_key
        CROSS JOIN LATERAL (
            SELECT CASE WHEN %(lat)s::float8 IS NOT NULL THEN
                ST_DistanceSphere(s.geom, ST_SetSRID(ST_MakePoint(%(lon)s::float8, %(lat)s::float8), 4326)) / 1000
            END AS km
        ) d
        -- A fuzzy match only when close: at 0.6, "kiev" finds Hakka romanisations ("kieuˇ")
        -- and "issigeac" finds Issigau, where nothing but a fallback should answer.
        WHERE b.tier < 4 OR b.score >= %(fuzzy_min)s
        ORDER BY b.tier,
                 CASE WHEN b.tier = 4 THEN b.score END DESC NULLS FIRST,
                 s.weight + CASE WHEN b.exact THEN %(exact_bonus)s ELSE 0 END
                     + %(usage_weight)s * ln(1 + COALESCE(u.users, 0))
                     - %(distance_penalty)s * ln(1 + COALESCE(d.km, 0)) DESC,
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


def tidy_stops(stops):
    """A route's stops ([lat, lng, name]) in an order that can be drawn.

    Many routes are mapped badly: both directions in one relation (Toulouse - Albi - Rodez out
    and back), or stops out of order (Varilhes before Toulouse). A stop listed again is
    dropped; and where a chain from one end to the nearest stop each time is much shorter than
    the given order, the chain is taken, run in the given direction. A curved line (Oslo's 4
    via Majorstuen) keeps its order, being no shorter chained.
    """
    seen, kept = set(), []
    for stop in stops:
        key = (stop[2] or "").strip().lower() or (round(stop[0], 4), round(stop[1], 4))
        if key not in seen:
            seen.add(key)
            kept.append(stop)
    if len(kept) < 3:
        return kept

    def at(stop):
        return {"lat": stop[0], "lng": stop[1]}

    def length(chain):
        return sum(metres(at(a), at(b)) for a, b in zip(chain, chain[1:]))

    start, end = max(
        ((i, j) for i in range(len(kept)) for j in range(i + 1, len(kept))),
        key=lambda ij: metres(at(kept[ij[0]]), at(kept[ij[1]])),
    )
    chain, rest = [kept[start]], kept[:start] + kept[start + 1:]
    while rest:
        nearest = min(rest, key=lambda stop: metres(at(chain[-1]), at(stop)))
        chain.append(nearest)
        rest.remove(nearest)
    if length(chain) >= length(kept) / 1.3:
        return kept
    # The direction the route was mapped in: from the end its first stop is nearer.
    if metres(at(kept[0]), at(chain[-1])) < metres(at(kept[0]), at(chain[0])):
        chain.reverse()
    return chain


@app.get("/station/<mode>/<key>/line")
def station_line(mode, key):
    """The line `ref` through a station: each of its route relations calling there, with its
    stops in order ([lat, lng, name]), to draw where the line goes."""
    rows = query(
        """
        WITH station AS (
            SELECT mode, key FROM stations WHERE mode = %(mode)s AND station_key = %(key)s
        ),
        routes AS (
            SELECT DISTINCT lr.relation_id
            FROM station st
            JOIN station_objects o ON o.mode = st.mode AND o.key = st.key
            JOIN rel_members rm ON rm.osm_type = o.osm_type AND rm.osm_id = o.osm_id
            JOIN line_routes lr ON lr.relation_id = rm.relation_id AND lr.mode = st.mode
            WHERE lr.tags ->> 'ref' = %(ref)s
        )
        SELECT r.relation_id, r.tags ->> 'name' AS name, r.tags ->> 'colour' AS colour,
               json_agg(json_build_array(ST_Y(s.geom), ST_X(s.geom), s.tags ->> 'name')
                        ORDER BY rs.seq) AS stops
        FROM routes
        JOIN rels r USING (relation_id)
        JOIN route_stops rs USING (relation_id)
        JOIN stops s ON s.osm_type = rs.osm_type AND s.osm_id = rs.osm_id
        GROUP BY r.relation_id, r.tags
        """,
        {"mode": mode, "key": key, "ref": request.args.get("ref")},
    )
    for row in rows:
        row["stops"] = tidy_stops(row["stops"])
    return jsonify(routes=rows)


# The route relations of each mode, beyond those counted as its lines (line_routes).
ROUTE_TYPES = {
    "train": ["train"],
    "metro": ["subway", "light_rail", "monorail"],
    "tram": ["tram", "light_rail"],
}


@app.get("/station/<mode>/<key>/services")
def station_services(mode, key):
    """The routes calling at a station that are not among its lines: trains mapped one route
    per train number ("TER 876206"), long-distance and night services."""
    rows = query(
        """
        SELECT DISTINCT r.relation_id, r.tags ->> 'ref' AS ref, r.tags ->> 'name' AS name,
               r.tags ->> 'network' AS network, r.tags ->> 'service' AS service,
               r.tags ->> 'colour' AS colour
        FROM stations st
        JOIN station_objects o ON o.mode = st.mode AND o.key = st.key
        JOIN rel_members rm ON rm.osm_type = o.osm_type AND rm.osm_id = o.osm_id
        JOIN rels r ON r.relation_id = rm.relation_id
        WHERE st.mode = %(mode)s AND st.station_key = %(key)s
          AND r.tags ->> 'route' = ANY(%(routes)s)
          AND NOT EXISTS (SELECT 1 FROM line_routes lr
                          WHERE lr.relation_id = r.relation_id AND lr.mode = st.mode)
        ORDER BY network, ref, name
        """,
        {"mode": mode, "key": key, "routes": ROUTE_TYPES.get(mode, [])},
    )
    return jsonify(services=rows)


@app.get("/route/<int:relation_id>")
def route(relation_id):
    """One route relation's stops in order ([lat, lng, name]), tidied as for a line."""
    rows = query(
        """
        SELECT r.relation_id, r.tags ->> 'name' AS name, r.tags ->> 'colour' AS colour,
               json_agg(json_build_array(ST_Y(s.geom), ST_X(s.geom), s.tags ->> 'name')
                        ORDER BY rs.seq) AS stops
        FROM rels r
        JOIN route_stops rs USING (relation_id)
        JOIN stops s ON s.osm_type = rs.osm_type AND s.osm_id = rs.osm_id
        WHERE r.relation_id = %(id)s
        GROUP BY r.relation_id, r.tags
        """,
        {"id": relation_id},
    )
    for row in rows:
        row["stops"] = tidy_stops(row["stops"])
    return jsonify(routes=rows)


@app.post("/directions")
def directions():
    """Where a vehicle stops at each station of a journey, by its direction of travel:
    {mode, keys: [station_key or null, ...]} in the order travelled gives {positions: [[lat,
    lng] or null, ...]}. Each station's is the stop position of a route relation (one per line
    and direction, in OSM) calling there and then at the next station; the last station's,
    the one of a relation calling at the one before and then there. Two tracks a few metres
    apart, one per direction, are told apart by this alone. A bus's route often lists only
    its platforms (the stops by the kerb, each on its side of the road), which then do:
    beside the carriageway taken. Null where no relation runs between the two.

    Of the relations running between two stations, the one running between most of the
    journey's: an interchange is served by other lines too, and line 5 also runs from Jaurès
    to Stalingrad, which put a line 2 journey on line 5's track there and sent the route
    round to turn back. Then stop positions over platforms, then the fewest stops between."""
    body = request.get_json(silent=True) or {}
    mode, keys = body.get("mode"), body.get("keys")
    if not mode or not isinstance(keys, list) or len(keys) > 200:
        return jsonify(error="mode and up to 200 keys are required"), 400
    positions = [None] * len(keys)
    pairs = [(i, a, b) for i, (a, b) in enumerate(zip(keys, keys[1:])) if a and b and a != b]
    if not pairs:
        return jsonify(positions=positions)
    rows = query(
        """
        SELECT DISTINCT ON (p.i, ra.relation_id)
               p.i, ra.relation_id, rb.seq - ra.seq AS gap, sp.a::int + sp.b::int AS stop_positions,
               ST_Y(oa.geom) AS alat, ST_X(oa.geom) AS alng,
               ST_Y(ob.geom) AS blat, ST_X(ob.geom) AS blng
        FROM unnest(%(idx)s::int[], %(a)s::text[], %(b)s::text[]) AS p(i, a, b)
        JOIN stations sa ON sa.mode = %(mode)s AND sa.station_key = p.a
        JOIN station_objects oa ON oa.mode = sa.mode AND oa.key = sa.key
        JOIN route_stops ra ON ra.osm_type = oa.osm_type AND ra.osm_id = oa.osm_id
        JOIN route_stops rb ON rb.relation_id = ra.relation_id AND rb.seq > ra.seq
        JOIN station_objects ob ON ob.osm_type = rb.osm_type AND ob.osm_id = rb.osm_id
        JOIN stations sb ON sb.mode = ob.mode AND sb.key = ob.key AND sb.station_key = p.b
        CROSS JOIN LATERAL (VALUES
            (oa.tags ->> 'public_transport' = 'stop_position',
             ob.tags ->> 'public_transport' = 'stop_position')) AS sp(a, b)
        WHERE (sp.a OR (%(mode)s = 'bus' AND (oa.tags ->> 'public_transport' = 'platform'
                                              OR oa.tags ->> 'highway' = 'bus_stop')))
          AND (sp.b OR (%(mode)s = 'bus' AND (ob.tags ->> 'public_transport' = 'platform'
                                              OR ob.tags ->> 'highway' = 'bus_stop')))
        ORDER BY p.i, ra.relation_id, sp.a::int + sp.b::int DESC, rb.seq - ra.seq
        """,
        {"mode": mode, "idx": [i for i, _, _ in pairs],
         "a": [a for _, a, _ in pairs], "b": [b for _, _, b in pairs]},
    )
    serves = {}
    for row in rows:
        serves[row["relation_id"]] = serves.get(row["relation_id"], 0) + 1
    best = {}
    for row in rows:
        rank = (serves[row["relation_id"]], row["stop_positions"], -row["gap"])
        if row["i"] not in best or rank > best[row["i"]][0]:
            best[row["i"]] = (rank, row)
    for i, _, _ in pairs:
        if i not in best:
            continue
        row = best[i][1]
        positions[i] = [row["alat"], row["alng"]]
        if i + 1 == len(keys) - 1 or positions[i + 1] is None:
            positions[i + 1] = [row["blat"], row["blng"]]
    return jsonify(positions=positions)


@app.post("/nearest")
def nearest():
    """The nearest station of `mode` within `radius` metres of each point, for many at once:
    {mode, radius, points: [[lat, lng], ...]} gives {stations: [station or null, ...]} in
    the points' order. What a trip's ends were, for a client tidying its station names.
    With `candidates` (up to 10), each point has that many of the nearest instead, as a
    list, nearest first: for a client to pick by name among stations close together."""
    body = request.get_json(silent=True) or {}
    mode, points = body.get("mode"), body.get("points") or []
    if not mode or not isinstance(points, list) or len(points) > 5000:
        return jsonify(error="mode and at most 5000 points are required"), 400
    try:
        lats = [float(p[0]) for p in points]
        lngs = [float(p[1]) for p in points]
        radius = min(float(body.get("radius") or 400), 2000)
        candidates = min(max(int(body.get("candidates") or 1), 1), 10)
    except (TypeError, ValueError, IndexError):
        return jsonify(error="points are [lat, lng] pairs"), 400
    rows = query(
        f"""
        SELECT p.i, {COLUMNS},
               -- To the nearest of its point and its objects, as /reverse.
               LEAST(ST_Distance(s.geom::geography,
                                 ST_SetSRID(ST_MakePoint(p.lng, p.lat), 4326)::geography),
                     (SELECT min(ST_Distance(o.geom::geography,
                                             ST_SetSRID(ST_MakePoint(p.lng, p.lat), 4326)::geography))
                      FROM station_objects o WHERE o.mode = s.mode AND o.key = s.key)) AS distance_m
        FROM unnest(%(lats)s::float8[], %(lngs)s::float8[]) WITH ORDINALITY AS p(lat, lng, i)
        CROSS JOIN LATERAL (
            SELECT * FROM stations s
            WHERE s.mode = %(mode)s
              AND s.geom && ST_Expand(ST_SetSRID(ST_MakePoint(p.lng, p.lat), 4326), %(degrees)s)
            ORDER BY s.geom <-> ST_SetSRID(ST_MakePoint(p.lng, p.lat), 4326)
            LIMIT %(candidates)s
        ) s
        WHERE ST_DWithin(s.geom::geography,
                         ST_SetSRID(ST_MakePoint(p.lng, p.lat), 4326)::geography, %(radius)s)
        ORDER BY p.i, distance_m
        """,
        # The box around a point: radius in degrees of latitude, widened for longitude up to 70°.
        {"lats": lats, "lngs": lngs, "mode": mode, "radius": radius, "candidates": candidates,
         "degrees": radius / 111320 * 3},
    )
    if "candidates" in body:
        stations = [[] for _ in points]
        for row in with_labels(rows):
            stations[row.pop("i") - 1].append(row)
        return jsonify(stations=stations)
    stations = [None] * len(points)
    for row in with_labels(rows):
        stations[row.pop("i") - 1] = row
    return jsonify(stations=stations)


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
    # The distance to a station is to the nearest of its point and its objects (platforms,
    # stop positions): a stop on one of a big station's platforms is at it, though 220m from
    # its node (Paris Nord), and nearer it than a station whose node is closer.
    # With quays=1, each station's objects that carry a stop-point id (ref:IFOPT: Germany's
    # DHIDs, de:05315:16101:7:72; Switzerland's SLOIDs), [{ids, ref, lat, lng, on_track}]:
    # a timetable naming its stops by those ids (Transitous's DELFI) then says the very
    # platform, whatever its own platform numbers ("75" for Chorweiler's track 2).
    quays = """,
        (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                    'ids', string_to_array(COALESCE(o.tags ->> 'ref:IFOPT', o.tags ->> 'ref:ifopt'), ';'),
                    'ref', COALESCE(o.tags ->> 'local_ref', o.tags ->> 'ref'),
                    'lat', ST_Y(o.geom), 'lng', ST_X(o.geom),
                    'on_track', o.tags ->> 'public_transport' = 'stop_position')), '[]')
         FROM station_objects o
         WHERE o.mode = s.mode AND o.key = s.key
           AND (o.tags ? 'ref:IFOPT' OR o.tags ? 'ref:ifopt')) AS quays
    """ if request.args.get("quays") else ""
    rows = query(
        f"""
        SELECT {COLUMNS}, d.m AS distance_m{quays}
        FROM stations s, ST_SetSRID(ST_MakePoint(%(lon)s, %(lat)s), 4326) AS p
        CROSS JOIN LATERAL (
            SELECT LEAST(ST_Distance(s.geom::geography, p::geography),
                         (SELECT min(ST_Distance(o.geom::geography, p::geography))
                          FROM station_objects o WHERE o.mode = s.mode AND o.key = s.key)) AS m
        ) d
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
