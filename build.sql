-- Turns the raw tables of the import (osm2pgsql, into Postgres's raw schema) into one row per
-- station and mode, with its names, place and lines, ready to search. Run by build.py in
-- DuckDB, where every query, insert and update runs on all cores; build.py then publishes the
-- result to Postgres's live schema, which the API reads. Tags are MAP(VARCHAR, VARCHAR),
-- JSON only on the way out.

-- @step setup
-- Postgres's unaccent folds these letters too, which strip_accents leaves.
CREATE MACRO fold(s) AS strip_accents(
    replace(replace(replace(replace(replace(replace(replace(replace(replace(
        lower(COALESCE(s, '')),
        'æ', 'ae'), 'œ', 'oe'), 'ß', 'ss'), 'ł', 'l'), 'ø', 'o'), 'đ', 'd'), 'ð', 'd'),
        'þ', 'th'), 'ı', 'i'));

-- What names and queries are compared on: folded, apostrophes dropped and other punctuation
-- turned into single spaces, so "St. Gallen" is "st gallen" and "Lyon-Part-Dieu" has the word
-- "part". As Postgres's search_fold (build.py), which the API folds queries with.
CREATE MACRO search_fold(s) AS
    trim(regexp_replace(regexp_replace(fold(s), '[''’]', '', 'g'), '[^\pL\p{Nd}]+', ' ', 'g'));

-- A name folded as search_fold, but with an apostrophe a word break: "Cœur d'Orly" is
-- "coeur d orly", in which Orly's name is a word. search_fold drops them, for "oconnell" to
-- find O'Connell, which would hide the place in every French elision ("coeur dorly").
CREATE MACRO elision_fold(s) AS trim(regexp_replace(fold(s), '[^\pL\p{Nd}]+', ' ', 'g'));

-- Metres between two points, on the sphere: X is the longitude, whatever DuckDB's
-- ST_Distance_Sphere takes.
CREATE MACRO dist_m(a, b) AS 2 * 6371008.8 * asin(sqrt(
    pow(sin(radians(ST_Y(b) - ST_Y(a)) / 2), 2)
    + cos(radians(ST_Y(a))) * cos(radians(ST_Y(b))) * pow(sin(radians(ST_X(b) - ST_X(a)) / 2), 2)));

-- Two points within m metres. First within m / 22264 degrees, which holds up to 78° of
-- latitude, as a join the spatial index can answer; then in metres. DuckDB answers a join with
-- its spatial index only when the join is on that alone: an equality beside it (the same mode)
-- makes it a hash join on that, which then measures every pair. So the spatial joins below
-- find candidates into a table of their own, filtered by the next statement.
CREATE MACRO near(a, b, m) AS ST_DWithin(a, b, m / 22264.0) AND dist_m(a, b) <= m;

CREATE MACRO without_quay(s) AS regexp_replace(s,
    '\s+\((?:(?:[Qq]uai|[Qq]uay|[Bb]ay|[Ss]tand|[Vv]oie|[Pp]latform|[Pp]lateforme)\s+)?([A-Z]{1,2}[0-9]{0,2}|[0-9]{1,2}[A-Z]?)\)$', '');

CREATE MACRO without_line(s) AS regexp_replace(s,
    '\s*[(\[](?:m[ée]tro|rer|tram(?:way)?|ligne|line|linie|lijn|linea|línea|u-?bahn|s-?bahn|'
    'stadtbahn|subway|bus|trolleybus)\b[^)\]]*[)\]]\s*$', '', 'i');

CREATE MACRO quay_of(s) AS NULLIF(regexp_extract(s,
    '\s\((?:(?:[Qq]uai|[Qq]uay|[Bb]ay|[Ss]tand|[Vv]oie|[Pp]latform|[Pp]lateforme)\s+)?([A-Z]{1,2}[0-9]{0,2}|[0-9]{1,2}[A-Z]?)\)$', 1), '');

CREATE MACRO quay_code(s) AS NULLIF(regexp_extract(s,
    '^(?:(?:[Qq]uai|[Qq]uay|[Bb]ay|[Ss]tand|[Vv]oie|[Pp]latform|[Pp]lateforme|[Pp]erron|'
    '[Bb]ahnsteig|[Aa]ndén|[Bb]inario|[Ss]por|[Ll]aituri)\s*(?:n[°o]\.?\s*)?)?'
    '([A-Z]{1,2}[0-9]{0,2}|[0-9]{1,3}[A-Z]?)$', 1), '');

CREATE MACRO is_quay_code(s) AS quay_code(s) IS NOT NULL;

CREATE MACRO is_primary_stop(tags) AS
    (tags['railway'] IN ('station', 'halt', 'tram_stop')
     OR tags['highway'] = 'bus_stop'
     OR tags['amenity'] IN ('bus_station', 'ferry_terminal')
     OR tags['aerialway'] = 'station'
     OR tags['public_transport'] = 'station') IS TRUE
    AND NOT is_quay_code(tags['name']);

-- A place as stations carry it: its name, its English one, and its names in the languages
-- Trainlog's readers read in another script than Latin, for the API to give each reader the
-- place in theirs (with_labels). Not every language: a city's dozens of names, carried by
-- each of its stations, would weigh more than the stations.
CREATE MACRO place_json(tags) AS map_from_entries(list_filter(map_entries(tags), lambda e:
    e.key IN ('name', 'name:en', 'name:zh', 'name:zh-Hans', 'name:ja', 'name:ko', 'name:ru', 'name:uk')));

-- Every run of up to five consecutive words of the given names, and the starts of a name in
-- Chinese or Japanese, which leave no space after a place: "泉州东" starts with 泉州. What a
-- boundary name, itself up to a few words, is compared to, as an exact match.
CREATE MACRO name_runs(name) AS CASE WHEN COALESCE(name, '') = '' THEN [] ELSE flatten(
    list_transform(range(1, len(string_split(name, ' ')) + 1), lambda i:
        list_transform(range(i, least(i + 4, len(string_split(name, ' '))) + 1), lambda j:
            array_to_string(string_split(name, ' ')[i:j], ' '))))
    || list_transform(range(2, length(regexp_extract(name, '^[぀-ヿ㐀-䶿一-鿿]+'))), lambda n:
            left(regexp_extract(name, '^[぀-ヿ㐀-䶿一-鿿]+'), n)) END;
CREATE MACRO word_runs(a, b, c) AS name_runs(a) || name_runs(b) || name_runs(c);


-- @step load
-- The raw tables, from Postgres (attached as pg by build.py): tags as maps, members as
-- structs, geometries from WKB.
CREATE TABLE stops AS
SELECT osm_type, osm_id, json_transform(tags, '"MAP(VARCHAR, VARCHAR)"') AS tags,
       ST_GeomFromWKB(wkb) AS geom
FROM postgres_query('pg', 'SELECT osm_type::text, osm_id, tags::text, ST_AsBinary(geom) AS wkb FROM {raw}.stops');

CREATE TABLE rels AS
SELECT relation_id, json_transform(tags, '"MAP(VARCHAR, VARCHAR)"') AS tags,
       json_transform(members, '[{"type": "VARCHAR", "ref": "BIGINT", "role": "VARCHAR"}]') AS members
FROM postgres_query('pg', 'SELECT relation_id, tags::text, members::text FROM {raw}.rels');

CREATE TABLE boundaries AS
SELECT relation_id, admin_level, json_transform(tags, '"MAP(VARCHAR, VARCHAR)"') AS tags,
       ST_GeomFromWKB(wkb) AS geom
FROM postgres_query('pg', 'SELECT relation_id, admin_level, tags::text, ST_AsBinary(geom) AS wkb FROM {raw}.boundaries');

CREATE TABLE line_ways AS
SELECT way_id, kind, name, ST_GeomFromWKB(wkb) AS geom
FROM postgres_query('pg', 'SELECT way_id, kind, name, ST_AsBinary(geom) AS wkb FROM {raw}.line_ways');

CREATE TABLE ski_areas AS
SELECT osm_type, osm_id, name, ST_GeomFromWKB(wkb) AS geom
FROM postgres_query('pg', 'SELECT osm_type::text, osm_id, name, ST_AsBinary(geom) AS wkb FROM {raw}.ski_areas');

CREATE TABLE places AS
SELECT node_id, place, json_transform(tags, '"MAP(VARCHAR, VARCHAR)"') AS tags,
       ST_GeomFromWKB(wkb) AS geom
FROM postgres_query('pg', 'SELECT node_id, place, tags::text, ST_AsBinary(geom) AS wkb FROM {raw}.places');


-- @step relation members
CREATE TABLE rel_members AS
SELECT relation_id,
       tags['public_transport'] = 'stop_area' AS is_stop_area,
       tags['route'] AS route,
       m.type AS osm_type, m.ref AS osm_id, m.role AS role, seq
FROM (SELECT relation_id, tags, unnest(members) AS m, unnest(range(1, len(members) + 1)) AS seq
      FROM rels);


-- @step route stops
-- Each route's calls in order. Mappers often list every stop and then every platform, so
-- only members with a stop role count; routes mapped without roles keep all their nodes.
CREATE TABLE route_stops AS
SELECT relation_id, seq, osm_type, osm_id
FROM (
    SELECT rm.*, bool_or(rm.role LIKE 'stop%') OVER (PARTITION BY rm.relation_id) AS has_stops
    FROM rel_members rm
    WHERE rm.route IS NOT NULL
) m
WHERE role LIKE 'stop%' OR NOT has_stops;


-- @step line routes
-- The routes that count as a line of a station in each mode. Train routes are often mapped
-- one per service; a ref with a train number in it ("TGV 505", "6033") is a service.
CREATE TABLE line_routes AS
SELECT r.relation_id, m.mode, r.tags
FROM rels r
JOIN (VALUES ('metro', 'subway'), ('metro', 'light_rail'), ('metro', 'monorail'),
             ('tram', 'tram'), ('tram', 'light_rail'), ('train', 'train')) AS m(mode, route)
  ON m.route = r.tags['route']
WHERE r.tags['ref'] IS NOT NULL
  AND (m.mode <> 'train'
       OR (NOT regexp_matches(r.tags['ref'], '[0-9]{3}')
           AND COALESCE(r.tags['service'], '')
               NOT IN ('high_speed', 'long_distance', 'national', 'international', 'night')));


-- @step stop area groups
-- Stop areas sharing a station node are one station: Châtelet is a stop_area per line.
-- Linked through station nodes only, as a shared entrance can join two distinct stations.
CREATE TABLE area_group AS
WITH RECURSIVE links AS (
    SELECT DISTINCT relation_id AS a, relation_id AS b FROM rel_members WHERE is_stop_area
    UNION
    SELECT x.relation_id, y.relation_id
    FROM rel_members x
    JOIN rel_members y USING (osm_type, osm_id)
    JOIN stops s USING (osm_type, osm_id)
    WHERE x.is_stop_area AND y.is_stop_area AND is_primary_stop(s.tags)
),
reach(a, b) AS (
    SELECT a, b FROM links
    UNION
    SELECT r.a, l.b FROM reach r JOIN links l ON l.a = r.b
)
SELECT a AS relation_id, min(b) AS group_id FROM reach GROUP BY a;


-- @step stop modes
-- Which modes each stop serves. Must match Trainlog's trip types.
CREATE TABLE stop_modes AS
SELECT s.osm_type, s.osm_id, m.mode
FROM stops s
CROSS JOIN LATERAL (VALUES
    -- A railway station is a train station unless its station= says another mode, or a dead
    -- one: station=rail (Lausanne), preserved_railway (Ongar) and the like are trains, and
    -- "train;subway" is one too. train=yes on a metro station (Paris's Gare d'Austerlitz,
    -- Bérault) is mapper noise: the trains stop at the station beside it. Tram-trains
    -- (station=light_rail) keep it.
    ('train',     s.tags['railway'] IN ('station', 'halt')
                  AND (regexp_matches(s.tags['station'], '(^|;)\s*train\s*($|;)')
                       OR NOT list_has_any(
                           string_split(regexp_replace(COALESCE(s.tags['station'], ''), '\s', '', 'g'), ';'),
                           ['subway', 'light_rail', 'monorail', 'funicular', 'miniature', 'tram',
                            'disused', 'abandoned', 'construction', 'proposed']))
                  OR s.tags['train'] = 'yes'
                  AND COALESCE(s.tags['station'], '') NOT IN ('subway', 'monorail')),
    ('metro',     s.tags['station'] IN ('subway', 'light_rail', 'monorail')
                  OR s.tags['subway'] = 'yes' OR s.tags['light_rail'] = 'yes'
                  OR s.tags['monorail'] = 'yes'),
    ('tram',      s.tags['railway'] = 'tram_stop' OR s.tags['tram'] = 'yes'
                  OR s.tags['station'] = 'light_rail' OR s.tags['light_rail'] = 'yes'),
    ('bus',       s.tags['highway'] = 'bus_stop' OR s.tags['amenity'] = 'bus_station'
                  OR s.tags['bus'] = 'yes'),
    ('ferry',     s.tags['amenity'] = 'ferry_terminal' OR s.tags['ferry'] = 'yes'),
    ('funicular', s.tags['station'] = 'funicular' OR s.tags['funicular'] = 'yes'),
    ('aerialway', s.tags['aerialway'] = 'station')
) AS m(mode, applies)
WHERE m.applies;


-- @step station objects
-- Every object of a station, keyed by what groups them: its stop areas, else its wikidata,
-- else the object alone. Only primary objects can found a station; platforms and stop
-- positions join one. source_key: the group it was found in, before the merges below.
CREATE TABLE station_objects AS
WITH object_area AS (
    SELECT rm.osm_type, rm.osm_id, min(ag.group_id) AS group_id
    FROM rel_members rm
    JOIN area_group ag USING (relation_id)
    GROUP BY rm.osm_type, rm.osm_id
)
SELECT sm.mode, k.key, s.osm_type, s.osm_id, s.tags, s.geom,
       is_primary_stop(s.tags) AS is_primary, k.key AS source_key
FROM stop_modes sm
JOIN stops s USING (osm_type, osm_id)
LEFT JOIN object_area oa USING (osm_type, osm_id)
CROSS JOIN LATERAL (SELECT COALESCE('A' || oa.group_id, 'Q' || s.tags['wikidata'],
                                    s.osm_type || s.osm_id) AS key) k;

-- @step untagged stop positions
-- Stop positions often carry no mode tag; inside a stop_area they belong to its stations.
-- Not its entrances, which say nothing about where trains stop.
INSERT INTO station_objects
SELECT DISTINCT a.mode, a.key, s.osm_type, s.osm_id, s.tags, s.geom, false, a.key
FROM (SELECT DISTINCT mode, key FROM station_objects WHERE key LIKE 'A%') a
JOIN area_group ag ON ag.group_id = CAST(substr(a.key, 2) AS BIGINT)
JOIN rel_members rm ON rm.relation_id = ag.relation_id
JOIN stops s ON s.osm_type = rm.osm_type AND s.osm_id = rm.osm_id
WHERE NOT EXISTS (SELECT 1 FROM stop_modes sm WHERE sm.osm_type = s.osm_type AND sm.osm_id = s.osm_id)
  AND COALESCE(s.tags['railway'], '') NOT IN ('subway_entrance', 'train_station_entrance')
  AND NOT map_contains(s.tags, 'entrance');

-- @step merge nearby duplicates
-- One station is often several same-named groups close together: a bus stop per side of the
-- street, a quay each ("(E)", "(F)"), one with its town and one without ("Royan - Gare",
-- "Gare"), one per line ("Charles de Gaulle — Étoile (Métro 1)", "(Métro 6)"), or two station
-- nodes with no shared stop_area. Those within 400m of each other are one, as chains of them
-- are: pairs within 400m, on an equirectangular projection so that is metres at any latitude,
-- joined on a 400m grid so as not to compare every "Gare" with every other, then the groups
-- they chain into (build.py, merge_groups).
CREATE TABLE named AS
SELECT mode, key, name,
       ST_X(geom) * 111320 * cos(radians(ST_Y(geom))) AS x, ST_Y(geom) * 110540 AS y
FROM (
    SELECT DISTINCT ON (o.mode, o.key)
           o.mode, o.key,
           search_fold(regexp_replace(
               without_line(without_quay(COALESCE(o.tags['name'], area.tags['name']))),
               '^.+?\s+-\s+', '')) AS name,
           o.geom
    FROM station_objects o
    LEFT JOIN rels area
      ON area.relation_id = CASE WHEN o.key LIKE 'A%' THEN CAST(substr(o.key, 2) AS BIGINT) END
    WHERE o.is_primary
    ORDER BY o.mode, o.key, map_contains(o.tags, 'name') DESC, o.osm_type, o.osm_id
)
WHERE name <> '';

CREATE TABLE near_pairs AS
WITH cells AS (
    SELECT *, floor(x / 400)::BIGINT AS cx, floor(y / 400)::BIGINT AS cy FROM named
)
SELECT a.mode, a.key AS a, b.key AS b
FROM cells a
CROSS JOIN (VALUES (-1), (0), (1)) AS dx(d)
CROSS JOIN (VALUES (-1), (0), (1)) AS dy(d)
JOIN cells b
  ON b.mode = a.mode AND b.name = a.name AND b.cx = a.cx + dx.d AND b.cy = a.cy + dy.d
WHERE a.key < b.key AND (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 <= 400 ^ 2;

-- @step merge groups
-- @python merge_groups

-- @step attach stray stops
-- Stop positions and platforms outside any stop_area form groups of their own, with no
-- station to found. They belong to the nearest station of their mode within 400m: routes list
-- their calls by these objects, so leaving them out loses the calls.
CREATE TABLE strays AS
SELECT DISTINCT ON (o.mode, o.key) o.mode, o.key, o.geom
FROM station_objects o
WHERE NOT EXISTS (
    SELECT 1 FROM station_objects p WHERE p.mode = o.mode AND p.key = o.key AND p.is_primary
)
ORDER BY o.mode, o.key;
CREATE TABLE stray_candidates AS
SELECT st.mode AS stray_mode, st.key AS stray_key, p.mode, p.key, p.is_primary,
       dist_m(p.geom, st.geom) AS d
FROM strays st
JOIN station_objects p ON near(p.geom, st.geom, 400);
CREATE TABLE stray_stations AS
SELECT DISTINCT ON (stray_mode, stray_key) stray_mode AS mode, stray_key AS key, key AS station_key
FROM stray_candidates
WHERE mode = stray_mode AND is_primary
ORDER BY stray_mode, stray_key, d;
UPDATE station_objects o SET key = n.station_key
FROM stray_stations n
WHERE o.mode = n.mode AND o.key = n.key;
DROP TABLE strays;
DROP TABLE stray_candidates;
DROP TABLE stray_stations;

-- @step bus stations
-- A bus station and the stops around it are one station, whatever their names: each bus stop
-- group within 80m of a bus station joins the nearest. 80m keeps the stops across the street
-- apart.
CREATE TABLE bus_stations AS
SELECT DISTINCT ON (key) key, geom
FROM station_objects
WHERE mode = 'bus' AND is_primary AND tags['amenity'] = 'bus_station'
ORDER BY key, osm_type, osm_id;
CREATE TABLE bus_stops AS
SELECT key, geom
FROM station_objects
WHERE mode = 'bus' AND is_primary AND key NOT IN (SELECT key FROM bus_stations);
CREATE TABLE absorbed_stops AS
SELECT DISTINCT ON (g.key) g.key, b.key AS into_key
FROM bus_stations b
JOIN bus_stops g ON near(g.geom, b.geom, 80)
ORDER BY g.key, dist_m(g.geom, b.geom);
UPDATE station_objects o SET key = a.into_key
FROM absorbed_stops a
WHERE o.mode = 'bus' AND o.key = a.key;
DROP TABLE bus_stations;
DROP TABLE bus_stops;
DROP TABLE absorbed_stops;


-- @step stations
-- One row per station: the representative object, its names (those of the station's
-- stop_area too), every object. Weighed here by its objects and wikidata, further by its
-- routes (weights).
CREATE TABLE stations AS
WITH rep AS (
    SELECT DISTINCT ON (mode, key) mode, key, osm_type, osm_id, tags, geom
    FROM station_objects
    WHERE is_primary
    ORDER BY mode, key, (tags['amenity'] = 'bus_station') IS TRUE DESC,
             map_contains(tags, 'name') DESC,
             (tags['name'] IS DISTINCT FROM without_line(tags['name'])),
             osm_type, osm_id
),
grouped AS (
    SELECT mode, key,
           list({'type': osm_type, 'id': osm_id}) AS objects,
           max(tags['wikidata']) AS wikidata,
           max(tags['uic_ref']) AS uic_ref,
           count(DISTINCT source_key) > 1 AS merged
    FROM station_objects
    GROUP BY mode, key
),
-- The stop_area relations of each station, which /object must also resolve.
areas AS (
    SELECT o.mode, o.key, list(DISTINCT {'type': 'R', 'id': ag.relation_id}) AS objects
    FROM (SELECT DISTINCT mode, key, source_key FROM station_objects WHERE source_key LIKE 'A%') o
    JOIN area_group ag ON ag.group_id = CAST(substr(o.source_key, 2) AS BIGINT)
    GROUP BY o.mode, o.key
)
SELECT CAST(row_number() OVER (ORDER BY r.mode, r.key) AS INTEGER) AS station_id,
       r.mode,
       r.key,
       r.osm_type,
       r.osm_id,
       -- A station merged from several, not named after one of their lines.
       CASE WHEN g.merged THEN without_line(without_quay(COALESCE(r.tags['name'], area.tags['name'])))
            ELSE without_quay(COALESCE(r.tags['name'], area.tags['name'])) END AS name,
       COALESCE(map_from_entries(list_transform(list_filter(
           map_entries(map_concat(COALESCE(area.tags, MAP {}), r.tags)), lambda e:
               -- name:<language>[-<script>], not the likes of name:source or name:etymology.
               regexp_full_match(e.key, 'name:[a-z]{2,3}([-_][A-Za-z]{2,4})?')
               OR e.key IN ('name', 'int_name', 'alt_name', 'official_name', 'short_name',
                            'loc_name', 'nat_name', 'reg_name', 'old_name')),
           lambda e: {'key': e.key, 'value': without_quay(e.value)})), MAP {}) AS names,
       g.wikidata,
       g.uic_ref,
       r.geom,
       g.objects || COALESCE(a.objects, []) AS objects,
       NULL::VARCHAR AS country,
       NULL::MAP(VARCHAR, VARCHAR) AS region,
       NULL::MAP(VARCHAR, VARCHAR) AS city,
       NULL::BOOLEAN AS city_override,
       NULL::STRUCT(ref VARCHAR, colour VARCHAR, lat DOUBLE, lng DOUBLE)[] AS lines,
       NULL::STRUCT(ref VARCHAR, lat DOUBLE, lng DOUBLE, on_track BOOLEAN)[] AS tracks,
       NULL::VARCHAR AS station_key,
       ln(1 + len(g.objects || COALESCE(a.objects, [])))
           + CASE WHEN g.wikidata IS NOT NULL THEN 0.5 ELSE 0 END AS weight,
       NULL::VARCHAR AS latin,
       NULL::BIGINT[] AS boundary_ids,
       NULL::VARCHAR AS line_name,
       NULL::VARCHAR AS ski_area,
       NULL::VARCHAR AS lift_end,
       NULL::MAP(VARCHAR, VARCHAR) AS settlement,
       NULL::BOOLEAN AS needs_place
FROM rep r
JOIN grouped g USING (mode, key)
LEFT JOIN areas a USING (mode, key)
LEFT JOIN rels area
  ON area.relation_id = CASE WHEN r.key LIKE 'A%' THEN CAST(substr(r.key, 2) AS BIGINT) END
WHERE COALESCE(r.tags['name'], area.tags['name']) IS NOT NULL;


-- @step lift ends
-- A named lift with no named station mapped at an end (Tråstølheisen): a station there, known
-- by the lift's name and which end it is (lift_end: lower at its first node, upper at its
-- last, lifts being mapped uphill). Not where another way of the same lift goes on (a joint).
INSERT INTO stations (station_id, mode, key, osm_type, osm_id, name, names, geom, objects,
                      station_key, line_name, lift_end, weight)
SELECT (SELECT max(station_id) FROM stations) + row_number() OVER (ORDER BY e.way_id, e.lift_end),
       'aerialway', 'L' || e.way_id || e.lift_end, 'W', e.way_id, e.name,
       MAP {'name': e.name}, e.geom,
       [{'type': 'W', 'id': e.way_id}],
       'W' || e.way_id || ':' || e.lift_end, e.name, e.lift_end, ln(2)
FROM (
    SELECT w.way_id, w.name, v.lift_end, v.geom
    FROM line_ways w
    CROSS JOIN LATERAL (VALUES ('lower', ST_StartPoint(w.geom)),
                               ('upper', ST_EndPoint(w.geom))) AS v(lift_end, geom)
    WHERE w.kind = 'aerialway'
) e
WHERE NOT EXISTS (
        SELECT 1 FROM station_objects o
        WHERE o.mode = 'aerialway' AND o.is_primary AND map_contains(o.tags, 'name')
          AND near(o.geom, e.geom, 60))
  AND NOT EXISTS (
        SELECT 1 FROM line_ways other
        WHERE other.kind = 'aerialway' AND other.way_id <> e.way_id AND other.name = e.name
          AND ST_DWithin(other.geom, e.geom, 5 / 22264.0)
          AND dist_m(ST_ClosestPoint(other.geom, e.geom), e.geom) <= 5);


-- @step station keys
-- The key Trainlog stores, unique within the mode: the wikidata item, else the UIC code,
-- else the representative object. A lift's end has its own already.
UPDATE stations s SET station_key = c.key
FROM (
    SELECT DISTINCT ON (station_id) station_id, key
    FROM (
        SELECT s.station_id, k.priority, k.key,
               count(*) OVER (PARTITION BY s.mode, k.key) AS holders
        FROM stations s
        CROSS JOIN LATERAL (VALUES
            (1, CASE WHEN regexp_full_match(s.wikidata, 'Q[0-9]+') THEN s.wikidata END),
            (2, 'UIC' || NULLIF(trim(s.uic_ref), '')),
            (3, s.osm_type || s.osm_id)
        ) AS k(priority, key)
        WHERE k.key IS NOT NULL AND s.station_key IS NULL
    ) candidates
    WHERE holders = 1
    ORDER BY station_id, priority
) c
WHERE s.station_id = c.station_id;


-- @step weights
-- How much a station matters, to order stations matching a search equally well: the routes
-- calling at it.
UPDATE stations s SET weight = s.weight + 2 * ln(1 + r.routes)
FROM (
    SELECT st.station_id, count(DISTINCT rs.relation_id) AS routes
    FROM route_stops rs
    JOIN rels r USING (relation_id)
    JOIN (VALUES ('train', 'train'), ('metro', 'subway'), ('metro', 'light_rail'),
                 ('metro', 'monorail'), ('tram', 'tram'), ('tram', 'light_rail')) AS m(mode, route)
      ON m.route = r.tags['route']
    JOIN station_objects o ON o.osm_type = rs.osm_type AND o.osm_id = rs.osm_id AND o.mode = m.mode
    JOIN stations st ON st.mode = o.mode AND st.key = o.key
    GROUP BY st.station_id
) r
WHERE s.station_id = r.station_id;


-- @step boundary pieces
-- Boundaries cut into small pieces: a point-in-polygon test then touches a few hundred
-- vertices instead of a whole country's outline. Their ids only, the tags joined after.
-- A share on each core: DuckDB splits a table between its threads by 122,880 rows, so a
-- query over these 23,000 boundaries would run on one.
CREATE TABLE boundary_parts (relation_id BIGINT, admin_level INTEGER, geom GEOMETRY);

-- @step cut boundaries
INSERT INTO boundary_parts
SELECT relation_id, admin_level, unnest(ST_Dump(ST_Subdivide(geom, 256))).geom
FROM boundaries
WHERE relation_id % {parts} = {part};


-- @step city overrides
-- The boundaries that are the city of the stations inside them, and their names: those
-- places.csv lists (by relation id, or by admin level and name), then those tagged
-- place=city at region level or below, and China's prefecture-level cities.
CREATE TABLE city_overrides AS
SELECT DISTINCT ON (b.relation_id) b.relation_id, NULLIF(p.name, '') AS name,
       NULLIF(p.name_en, '') AS name_en
FROM read_csv('{here}/places.csv', comment = '#', header = true, all_varchar = true) p
JOIN boundaries b
  ON b.relation_id = TRY_CAST(p.relation_id AS BIGINT)
  OR (p.relation_id IS NULL AND b.admin_level = TRY_CAST(p.admin_level AS INTEGER)
      AND b.tags['name'] = p.boundary_name)
ORDER BY b.relation_id;
INSERT INTO city_overrides
SELECT relation_id, NULL, NULL FROM boundaries
WHERE ((admin_level BETWEEN 4 AND 7 AND tags['place'] = 'city')
       OR (admin_level = 5 AND tags['name'] LIKE '%市'))
  AND relation_id NOT IN (SELECT relation_id FROM city_overrides);


-- @step country shapes
-- Trainlog's countries, cut into small pieces as the boundaries are: the country a station is
-- in, as Trainlog counts it.
-- Read as JSON, which DuckDB parses four times as fast as the GeoJSON driver does.
CREATE TABLE country_polygons AS
SELECT row_number() OVER () AS id, code, geom
FROM (SELECT f.properties.countryCode AS code, unnest(ST_Dump(ST_GeomFromGeoJSON(f.geometry))).geom AS geom
      FROM (SELECT unnest(features) AS f
            FROM read_json('{here}/countries.geojson', maximum_object_size = 1000000000,
                           columns = {'features': 'STRUCT(properties STRUCT(countryCode VARCHAR), geometry JSON)[]'})));
CREATE TABLE country_shapes (code VARCHAR, geom GEOMETRY);

-- @step cut countries
INSERT INTO country_shapes
SELECT code, unnest(ST_Dump(ST_Subdivide(geom, 256))).geom
FROM country_polygons
WHERE id % {parts} = {part};


-- @step country, region, city
-- One lookup per station for every level at once. The country is Trainlog's (country_shapes),
-- else OSM's, else the region's ISO3166-2 code ("FR-IDF"), for extracts that cut the
-- country's own boundary. The city is the smallest boundary places.csv names
-- (city_overrides), else the lowest municipality.
DROP TABLE country_polygons;
CREATE TABLE boundary_hits AS
SELECT s.station_id, b.relation_id
FROM stations s
JOIN boundary_parts b ON ST_Contains(b.geom, s.geom);
-- Each boundary's place as stations carry it, once per boundary rather than per station in it.
CREATE TABLE boundary_places AS
SELECT b.relation_id, b.admin_level, co.relation_id IS NOT NULL AS is_city,
       upper(b.tags['ISO3166-1:alpha2']) AS country,
       upper(left(b.tags['ISO3166-2'], 2)) AS region_country,
       place_json(b.tags) AS place,
       place_json(map_concat(b.tags, map_from_entries(list_filter(
           [{'key': 'name', 'value': co.name}, {'key': 'name:en', 'value': COALESCE(co.name_en, co.name)}],
           lambda e: e.value IS NOT NULL)))) AS city_place
FROM boundaries b
LEFT JOIN city_overrides co USING (relation_id);
CREATE TABLE station_places AS
SELECT h.station_id,
       max(b.country) FILTER (WHERE b.admin_level = 2) AS country,
       max(b.region_country) FILTER (WHERE b.admin_level = 4) AS region_country,
       (list(b.place) FILTER (WHERE b.admin_level = 4))[1] AS region,
       COALESCE(
           (list(b.city_place ORDER BY b.admin_level DESC) FILTER (WHERE b.is_city))[1],
           (list(b.place ORDER BY b.admin_level DESC) FILTER (WHERE b.admin_level BETWEEN 6 AND 8))[1]
       ) AS city,
       bool_or(b.is_city) AS city_override,
       list(DISTINCT b.relation_id) FILTER (WHERE b.admin_level BETWEEN 4 AND 8 OR b.is_city)
           AS boundary_ids
FROM boundary_hits h
JOIN boundary_places b USING (relation_id)
GROUP BY h.station_id;

CREATE TABLE station_countries AS
SELECT DISTINCT ON (s.station_id) s.station_id, c.code
FROM stations s
JOIN country_shapes c ON ST_Contains(c.geom, s.geom)
ORDER BY s.station_id, c.code;

UPDATE stations s SET
    country = COALESCE(c.code, p.country, p.region_country),
    region  = p.region,
    city    = p.city,
    city_override = p.city_override,
    boundary_ids = p.boundary_ids
FROM (SELECT station_id FROM stations) x
LEFT JOIN station_places p USING (station_id)
LEFT JOIN station_countries c USING (station_id)
WHERE s.station_id = x.station_id;
DROP TABLE boundary_hits;
DROP TABLE boundary_places;
DROP TABLE station_places;
DROP TABLE station_countries;


-- @step settlements
-- The town, village or hamlet a station is at, which people know it by better than its
-- municipality (Åndalsnes, in Rauma kommune): of the places within their kind's reach (a
-- city 8km, a town 4km, a village 2km, a hamlet 800m), in the station's own municipality where
-- it has one (Gare de Dax is in Dax, though Saint-Paul-lès-Dax, over the commune's edge, is
-- nearer); a city first, whose hamlets are its neighbourhoods (Fyllingsdalen terminal is in
-- Bergen, not Sælen), then the nearest relative to its reach.
-- Not in China, whose towns are no one's name for where a station is: its prefecture-level
-- city is (city_overrides). Not suburbs or districts: Paris's stations are in Paris, not Bercy.
CREATE TABLE muni_levels AS
SELECT relation_id, admin_level FROM boundaries WHERE admin_level BETWEEN 6 AND 8;
CREATE TABLE place_munis AS
SELECT DISTINCT pl.node_id, b.relation_id
FROM places pl
JOIN boundary_parts b ON ST_Contains(b.geom, pl.geom)
JOIN muni_levels ml ON ml.relation_id = b.relation_id;
CREATE TABLE station_munis AS
SELECT s.station_id, arg_max(ml.relation_id, ml.admin_level) AS relation_id
FROM stations s, unnest(s.boundary_ids) AS u(bid)
JOIN muni_levels ml ON ml.relation_id = u.bid
GROUP BY s.station_id;
-- The places within the farthest reach (a city's), in one spatial join with one radius for
-- all, then within their own.
CREATE TABLE settled_stations AS
SELECT station_id, geom FROM stations WHERE country IS DISTINCT FROM 'CN';
CREATE TABLE nearby_places AS
SELECT s.station_id, pl.node_id, pl.place, dist_m(pl.geom, s.geom) AS metres
FROM settled_stations s
JOIN places pl ON near(pl.geom, s.geom, 8000);
CREATE TABLE reachable AS
SELECT station_id, node_id, metres / CASE place WHEN 'city' THEN 8000 WHEN 'town' THEN 4000
                                                WHEN 'village' THEN 2000 ELSE 800 END AS reach
FROM nearby_places;
CREATE TABLE station_settlements AS
SELECT DISTINCT ON (r.station_id) r.station_id,
       map_concat(place_json(pl.tags), MAP {'place': pl.place}) AS settlement
FROM reachable r
JOIN places pl USING (node_id)
LEFT JOIN station_munis m ON m.station_id = r.station_id
LEFT JOIN place_munis pm ON pm.node_id = r.node_id AND pm.relation_id = m.relation_id
WHERE r.reach <= 1 AND (m.relation_id IS NULL OR pm.node_id IS NOT NULL)
ORDER BY r.station_id, pl.place = 'city' DESC, r.reach;
UPDATE stations s SET settlement = x.settlement
FROM station_settlements x
WHERE s.station_id = x.station_id;
DROP TABLE settled_stations;
DROP TABLE nearby_places;
DROP TABLE reachable;
DROP TABLE station_settlements;
DROP TABLE station_munis;
DROP TABLE place_munis;
DROP TABLE muni_levels;


-- @step station lines
-- Each line calling at the station, at the middle of its stop positions there (else of its
-- platforms).
UPDATE stations s SET lines = l.lines
FROM (
    WITH line_objects AS (
        SELECT DISTINCT ON (st.station_id, lr.tags['ref'], o.osm_type, o.osm_id)
               st.station_id,
               lr.tags['ref'] AS ref,
               lr.tags['colour'] AS colour,
               o.geom,
               (o.tags['public_transport'] = 'stop_position') IS TRUE AS is_stop_position
        FROM stations st
        JOIN station_objects o ON o.mode = st.mode AND o.key = st.key
        JOIN rel_members rm ON rm.osm_type = o.osm_type AND rm.osm_id = o.osm_id
        JOIN line_routes lr ON lr.relation_id = rm.relation_id AND lr.mode = st.mode
        ORDER BY st.station_id, lr.tags['ref'], o.osm_type, o.osm_id
    ),
    line_points AS (
        SELECT station_id, ref, max(colour) AS colour,
               ST_Centroid(ST_Collect(COALESCE(list(geom) FILTER (WHERE is_stop_position), list(geom)))) AS geom
        FROM line_objects
        GROUP BY station_id, ref
    )
    SELECT station_id,
           list({'ref': ref, 'colour': colour, 'lat': ST_Y(geom), 'lng': ST_X(geom)}
                ORDER BY length(ref), ref) AS lines
    FROM line_points
    GROUP BY station_id
) l
WHERE s.station_id = l.station_id;


-- @step platform stop positions
-- A platform numbered for one track, whose stop position on that track is unnumbered: its
-- track can sit on the stop position, when each is the other's nearest within 30m and the
-- platform's next stop position is at least half as far again.
CREATE TABLE platform_stops AS
WITH platforms AS (
    SELECT st.station_id, o.osm_type, o.osm_id, o.geom
    FROM stations st
    JOIN station_objects o ON o.mode = st.mode AND o.key = st.key
    WHERE st.mode IN ('train', 'metro', 'tram', 'funicular')
      AND (o.tags['public_transport'] = 'platform' OR o.tags['railway'] = 'platform')
      AND regexp_full_match(COALESCE(o.tags['railway:track_ref'], o.tags['local_ref'], o.tags['ref']), '[^;]+')
),
stops AS (
    SELECT st.station_id, o.osm_type, o.osm_id, o.geom
    FROM stations st
    JOIN station_objects o ON o.mode = st.mode AND o.key = st.key
    WHERE st.mode IN ('train', 'metro', 'tram', 'funicular')
      AND o.tags['public_transport'] = 'stop_position'
      AND NOT (map_contains(o.tags, 'railway:track_ref') OR map_contains(o.tags, 'local_ref')
               OR map_contains(o.tags, 'ref'))
),
pairs AS (
    SELECT p.station_id, p.osm_type, p.osm_id, s.geom AS stop_geom,
           dist_m(p.geom, s.geom) AS d,
           row_number() OVER (PARTITION BY p.station_id, p.osm_type, p.osm_id ORDER BY ST_Distance(p.geom, s.geom)) AS for_platform,
           row_number() OVER (PARTITION BY s.station_id, s.osm_type, s.osm_id ORDER BY ST_Distance(p.geom, s.geom)) AS for_stop
    FROM platforms p
    JOIN stops s USING (station_id)
)
SELECT a.station_id, a.osm_type, a.osm_id, a.stop_geom
FROM pairs a
LEFT JOIN pairs b ON b.station_id = a.station_id AND b.osm_type = a.osm_type AND b.osm_id = a.osm_id
                 AND b.for_platform = 2
WHERE a.for_platform = 1 AND a.for_stop = 1 AND a.d <= 30 AND (b.d IS NULL OR b.d >= 1.5 * a.d);


-- @step station tracks
-- Where a vehicle calling at a given track stops: [{ref, lat, lng, on_track}]. A stop position
-- sits on the track itself; a platform ("1;3") between its tracks, so it only stands in for a
-- track with no stop position.
UPDATE stations s SET tracks = t.tracks
FROM (
    WITH refs AS (
        SELECT st.station_id,
               regexp_replace(trim(r.part),
                   '^(voie|gleis|gl\.?|track|platform|quai|binario|v[ií]a|spoor|tor|peron)\s*', '', 'i') AS ref,
               (o.tags['public_transport'] = 'stop_position' OR ps.station_id IS NOT NULL) IS TRUE AS on_track,
               COALESCE(ps.stop_geom, o.geom) AS geom, st.geom AS station_geom
        FROM stations st
        JOIN station_objects o ON o.mode = st.mode AND o.key = st.key
        LEFT JOIN platform_stops ps
          ON ps.station_id = st.station_id AND ps.osm_type = o.osm_type AND ps.osm_id = o.osm_id
        CROSS JOIN LATERAL (SELECT unnest(string_split(
            COALESCE(o.tags['railway:track_ref'], o.tags['local_ref'],
                     quay_code(o.tags['name']),
                     quay_of(o.tags['name']),
                     -- A bus or ferry stop's ref is its network's stop code, not a quay.
                     CASE WHEN st.mode NOT IN ('bus', 'ferry') THEN o.tags['ref'] END), ';')) AS part) r
        WHERE st.mode IN ('train', 'metro', 'tram', 'funicular', 'bus', 'ferry')
          AND (o.tags['public_transport'] IN ('stop_position', 'platform')
               OR o.tags['railway'] = 'platform' OR o.tags['highway'] = 'bus_stop')
    ),
    best AS (
        SELECT DISTINCT ON (station_id, ref) station_id, ref, on_track, geom
        FROM refs
        -- Shaped like a track: "7", "112", "12a", "A", "M3".
        WHERE regexp_full_match(ref, '([0-9]{1,3}|[0-9]{1,2}[A-Za-z]|[A-Za-z]{1,2}[0-9]{0,2})')
        ORDER BY station_id, ref, on_track DESC, ST_Distance(geom, station_geom)
    )
    SELECT station_id,
           list({'ref': ref, 'lat': round(ST_Y(geom), 6), 'lng': round(ST_X(geom), 6), 'on_track': on_track}
                ORDER BY length(ref), ref) AS tracks
    FROM best
    GROUP BY station_id
) t
WHERE s.station_id = t.station_id;


-- @step lift lines
-- The line an aerialway or funicular station is on: the named line passing within 60m of it,
-- when only one does; where several pass, the one named as the station.
CREATE TABLE station_lift_ways AS
SELECT st.station_id, w.way_id, w.name,
       dist_m(ST_ClosestPoint(w.geom, st.geom), st.geom) AS d
FROM stations st
JOIN line_ways w ON w.kind = st.mode AND ST_DWithin(w.geom, st.geom, 60 / 22264.0)
WHERE st.mode IN ('aerialway', 'funicular');
DELETE FROM station_lift_ways WHERE d > 60;

UPDATE stations s SET line_name = l.name
FROM (
    SELECT station_id, min(name) AS name
    FROM station_lift_ways
    GROUP BY station_id
    HAVING count(DISTINCT name) = 1
) l
WHERE s.station_id = l.station_id;

UPDATE stations s SET line_name = l.name
FROM (
    SELECT DISTINCT ON (sw.station_id) sw.station_id, sw.name
    FROM station_lift_ways sw
    JOIN stations st USING (station_id)
    WHERE st.line_name IS NULL AND search_fold(sw.name) = search_fold(st.name)
    ORDER BY sw.station_id, sw.d
) l
WHERE s.station_id = l.station_id;

-- A lift's two stations named alike: told apart as its lower and upper ends; and a station
-- named as its lift, on a lift whose other end got a station (lift ends).
UPDATE stations s SET lift_end = e.lift_end
FROM (
    SELECT DISTINCT ON (st.station_id) st.station_id,
           CASE WHEN ST_Distance(st.geom, ST_StartPoint(w.geom)) <= ST_Distance(st.geom, ST_EndPoint(w.geom))
                THEN 'lower' ELSE 'upper' END AS lift_end
    FROM stations st
    JOIN station_lift_ways sw ON sw.station_id = st.station_id AND sw.name = st.line_name
    JOIN line_ways w ON w.way_id = sw.way_id AND w.kind = 'aerialway'
    WHERE st.mode = 'aerialway' AND st.lift_end IS NULL
      AND (EXISTS (SELECT 1 FROM stations twin
                   WHERE twin.mode = st.mode AND twin.station_id <> st.station_id
                     AND twin.line_name = st.line_name
                     AND search_fold(twin.name) = search_fold(st.name)
                     AND dist_m(twin.geom, st.geom) <= 10000)
           OR (search_fold(st.name) = search_fold(st.line_name)
               AND EXISTS (SELECT 1 FROM stations added
                           WHERE added.mode = 'aerialway' AND added.osm_type = 'W'
                             AND added.osm_id = w.way_id AND added.lift_end IS NOT NULL)))
    ORDER BY st.station_id, sw.d
) e
WHERE s.station_id = e.station_id;

-- A lift's or funicular's station moved onto its line, where a router can find the lift.
UPDATE stations s SET geom = m.geom
FROM (
    SELECT DISTINCT ON (st.station_id) st.station_id, ST_ClosestPoint(w.geom, st.geom) AS geom
    FROM stations st
    JOIN station_lift_ways sw ON sw.station_id = st.station_id AND sw.name = st.line_name
    JOIN line_ways w ON w.way_id = sw.way_id
    ORDER BY st.station_id, sw.d
) m
WHERE s.station_id = m.station_id;

-- The ski area an aerialway or funicular station is in: the smallest named area containing
-- the middle of its line; a station on no known line, the smallest area within 100m.
UPDATE stations s SET ski_area = a.name
FROM (
    SELECT DISTINCT ON (st.station_id) st.station_id, ski.name
    FROM stations st
    JOIN station_lift_ways sw ON sw.station_id = st.station_id AND sw.name = st.line_name
    JOIN line_ways w ON w.way_id = sw.way_id
    JOIN ski_areas ski ON ST_Contains(ski.geom, ST_LineInterpolatePoint(w.geom, 0.5))
    ORDER BY st.station_id, ST_Area(ski.geom)
) a
WHERE s.station_id = a.station_id;

UPDATE stations s SET ski_area = a.name
FROM (
    SELECT DISTINCT ON (st.station_id) st.station_id, ski.name
    FROM stations st
    JOIN ski_areas ski
      ON ST_DWithin(ski.geom, st.geom, 100 / (111320 * cos(radians(ST_Y(st.geom)))))
    WHERE st.mode IN ('aerialway', 'funicular') AND st.line_name IS NULL
    ORDER BY st.station_id, ST_Area(ski.geom)
) a
WHERE s.station_id = a.station_id;
DROP TABLE station_lift_ways;


-- @step latin names
-- @python latin_names

-- @step place latin names
-- @python place_latin_names


-- @step place names
-- Whether a station's name needs its city to make sense: "Gare" in Royan is "Royan - Gare";
-- not when the name already says one of its places, at any level from municipality to region,
-- nor that of a town or village near it, nor, for a train station, ferry terminal or
-- funicular, when no other of its mode in the country has it.
CREATE TABLE boundary_names AS
SELECT DISTINCT relation_id, name
FROM (
    SELECT b.relation_id, search_fold(trim(part)) AS full_name,
           trim(regexp_replace(regexp_replace(search_fold(trim(part)),
               '\b(region|regione|capital|capitale|hoofdstedelijk|gewest|district|city|'
               'ville|of|de|du|des|la|le|the|metropolitan|greater|gemeinde|stadt|kreis|landkreis|'
               'oblast|raion|rayon|okrug|province|provincia|prefecture|municipality|municipio|'
               'commune|county|kommune|fylke)\b', '', 'g'), '\s+', ' ', 'g')) AS bare_name
    FROM (
        SELECT b.relation_id, unnest(map_entries(map_concat(b.tags, map_from_entries(list_filter(
                   [{'key': 'override', 'value': co.name}, {'key': 'override:en', 'value': co.name_en}],
                   lambda e: e.value IS NOT NULL))))) AS t
        FROM boundaries b
        LEFT JOIN city_overrides co USING (relation_id)
        WHERE b.admin_level BETWEEN 4 AND 8 OR co.relation_id IS NOT NULL
    ) b, unnest(string_split_regex(b.t.value, '\s+-\s+|\s*/\s*|;')) AS p(part)
    WHERE b.t.key = 'name' OR regexp_full_match(b.t.key, 'name:[a-z]{2,3}') OR b.t.key LIKE 'override%'
       OR b.t.key IN ('int_name', 'alt_name', 'official_name', 'short_name')
) n,
-- "臺北市" without its last character is "臺北": a single non-Latin word less its suffix.
LATERAL (VALUES (full_name), (bare_name),
                (CASE WHEN NOT regexp_matches(full_name, '[ a-z]') AND length(full_name) >= 3
                      THEN left(full_name, -1) END)) AS v(name)
WHERE length(name) >= 2;

CREATE TABLE station_runs AS
SELECT station_id, boundary_ids,
       word_runs(search_fold(name), search_fold(latin),
                 NULLIF(elision_fold(name), search_fold(name))) AS runs
FROM stations
WHERE city IS NOT NULL OR settlement IS NOT NULL;

CREATE TABLE place_said AS
SELECT DISTINCT sr.station_id
FROM station_runs sr, unnest(sr.boundary_ids) AS u(bid), unnest(sr.runs) AS r(run)
JOIN boundary_names bn ON bn.relation_id = u.bid AND bn.name = r.run;

CREATE TABLE place_names AS
SELECT node_id, geom, search_fold(tags['name']) AS name, search_fold(tags['name:en']) AS name_en
FROM places;

CREATE TABLE unsaid AS
SELECT s.station_id, s.geom
FROM stations s
WHERE s.station_id IN (SELECT station_id FROM station_runs)
  AND s.station_id NOT IN (SELECT station_id FROM place_said);
CREATE TABLE places_near AS
SELECT u.station_id, pl.name, pl.name_en
FROM unsaid u
JOIN place_names pl ON near(pl.geom, u.geom, 3000);
CREATE TABLE named_after_places AS
SELECT DISTINCT p.station_id
FROM places_near p
JOIN station_runs sr USING (station_id)
WHERE list_contains(sr.runs, p.name) OR list_contains(sr.runs, p.name_en);
DROP TABLE unsaid;
DROP TABLE places_near;

CREATE TABLE unique_names AS
SELECT station_id, mode
FROM (SELECT station_id, mode,
             count(*) OVER (PARTITION BY mode, country, search_fold(name)) AS same_name
      FROM stations) named
WHERE same_name = 1;

UPDATE stations s SET needs_place = (s.city IS NOT NULL OR s.settlement IS NOT NULL)
    AND s.station_id NOT IN (SELECT station_id FROM place_said)
    -- A name taken from a nearby place says where only if no other station of the country has it:
    -- the stops called "Bergen" in each German hamlet of that name need their municipality.
    AND s.station_id NOT IN (SELECT station_id FROM named_after_places
                             WHERE station_id IN (SELECT station_id FROM unique_names))
    AND s.station_id NOT IN (SELECT station_id FROM unique_names
                             WHERE mode IN ('train', 'ferry', 'funicular'));
DROP TABLE station_runs;
DROP TABLE place_said;
DROP TABLE place_names;
DROP TABLE named_after_places;
DROP TABLE unique_names;


-- @step search names
-- Every spelling to search on: its names, its lift's line or ski area before them, the names
-- of the other stops gathered into it, and each of these with its city before and after.
CREATE TABLE own_names AS
SELECT DISTINCT s.station_id, s.mode, trim(part) AS name
FROM stations s,
     unnest(map_values(map_concat(s.names, MAP {'latin': s.latin}))) AS n(v),
     unnest(string_split(n.v, ';')) AS p(part)
WHERE trim(part) <> '';

CREATE TABLE line_names AS
SELECT DISTINCT n.station_id, n.mode, p.prefix || ' ' || n.name AS name
FROM own_names n
JOIN stations s USING (station_id)
CROSS JOIN LATERAL (VALUES (s.line_name), (s.ski_area)) AS p(prefix)
WHERE p.prefix IS NOT NULL
  AND search_fold(n.name) NOT LIKE '%' || search_fold(p.prefix) || '%';

CREATE TABLE object_names AS
SELECT DISTINCT st.station_id, st.mode, without_quay(o.tags['name']) AS name
FROM stations st
JOIN station_objects o ON o.mode = st.mode AND o.key = st.key
WHERE o.is_primary AND map_contains(o.tags, 'name') AND NOT is_quay_code(o.tags['name'])
  AND NOT EXISTS (SELECT 1 FROM own_names n
                  WHERE n.station_id = st.station_id AND n.name = without_quay(o.tags['name']))
  AND NOT EXISTS (SELECT 1 FROM line_names n
                  WHERE n.station_id = st.station_id AND n.name = without_quay(o.tags['name']));

CREATE TABLE plain_names AS
SELECT station_id, mode, name FROM own_names
UNION
SELECT station_id, mode, name FROM line_names
UNION
SELECT station_id, mode, name FROM object_names;

CREATE TABLE station_names AS
SELECT station_id, mode, name, false AS city_prefixed, NULL::VARCHAR AS place
FROM plain_names
UNION ALL
SELECT DISTINCT n.station_id, n.mode, v.name, true, v.place
FROM plain_names n
JOIN stations s USING (station_id)
CROSS JOIN LATERAL (VALUES (s.city['name']), (s.city['name:en']),
                           (s.settlement['name']), (s.settlement['name:en'])) AS c(city)
CROSS JOIN LATERAL (VALUES (c.city || ' ' || n.name, search_fold(c.city)),
                           (n.name || ' ' || c.city, NULL)) AS v(name, place)
WHERE c.city IS NOT NULL AND search_fold(n.name) NOT LIKE '%' || search_fold(c.city) || '%';
DROP TABLE own_names;
DROP TABLE line_names;
DROP TABLE object_names;
DROP TABLE plain_names;
