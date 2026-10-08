-- Turns the raw osm2pgsql tables (stops, rels, boundaries) into one row per station and
-- mode, with its names, place and lines, ready to search.
--
-- Runs in the `build` schema, which build.py swaps in for `live` once complete. Extensions
-- and functions live in public, which is not swapped.

-- @step setup
CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA public;
CREATE EXTENSION IF NOT EXISTS unaccent SCHEMA public;
CREATE EXTENSION IF NOT EXISTS btree_gist SCHEMA public;

CREATE OR REPLACE FUNCTION public.fold(text) RETURNS text AS $$
    SELECT lower(public.unaccent('public.unaccent'::regdictionary, COALESCE($1, '')))
$$ LANGUAGE sql IMMUTABLE;

-- What names and queries are compared on: folded, apostrophes dropped and other punctuation
-- turned into single spaces, so "St. Gallen" is "st gallen" and "Lyon-Part-Dieu" has the
-- word "part". A separate function from fold(), which the live tables were built with.
CREATE OR REPLACE FUNCTION public.search_fold(text) RETURNS text AS $$
    SELECT trim(regexp_replace(
        regexp_replace(public.fold($1), '[''’]', '', 'g'),
        '[^[:alnum:]]+', ' ', 'g'))
$$ LANGUAGE sql IMMUTABLE;

-- The station, stop or terminal itself, as opposed to its platforms and stop positions.
CREATE OR REPLACE FUNCTION public.is_primary_stop(tags jsonb) RETURNS boolean AS $$
    SELECT (tags ->> 'railway' IN ('station', 'halt', 'tram_stop')
            OR tags ->> 'highway' = 'bus_stop'
            OR tags ->> 'amenity' IN ('bus_station', 'ferry_terminal')
            OR tags ->> 'aerialway' = 'station'
            OR tags ->> 'public_transport' = 'station') IS TRUE
$$ LANGUAGE sql IMMUTABLE;

-- osm2pgsql indexes these by position only; /line looks routes and stops up by id.
CREATE INDEX IF NOT EXISTS stops_osm_id_idx ON stops (osm_type, osm_id);
CREATE INDEX IF NOT EXISTS rels_relation_id_idx ON rels (relation_id);

DROP TABLE IF EXISTS key_redirects, station_names, stations, station_objects, stop_modes, area_group, line_routes,
    rel_members, route_stops, boundary_parts;


-- @step relation members
CREATE TABLE rel_members AS
SELECT r.relation_id,
       r.tags ->> 'public_transport' = 'stop_area' AS is_stop_area,
       r.tags ->> 'route' AS route,
       -- char(1) like osm2pgsql's own osm_type: a text one defeats the indexes on joins.
       (e.member ->> 'type')::char(1) AS osm_type,
       (e.member ->> 'ref')::bigint AS osm_id,
       e.member ->> 'role' AS role,
       e.seq
FROM rels r, jsonb_array_elements(r.members) WITH ORDINALITY AS e(member, seq);
CREATE INDEX ON rel_members (osm_type, osm_id);
CREATE INDEX ON rel_members (relation_id);

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
CREATE INDEX ON route_stops (osm_type, osm_id);
CREATE INDEX ON route_stops (relation_id, seq);


-- @step line routes
-- The routes that count as a line of a station in each mode. Train routes are often mapped
-- one per service; a ref with a train number in it ("TGV 505", "6033") is a service.
CREATE TABLE line_routes AS
SELECT r.relation_id, m.mode, r.tags
FROM rels r
JOIN (VALUES ('metro', 'subway'), ('metro', 'light_rail'), ('metro', 'monorail'),
             ('tram', 'tram'), ('tram', 'light_rail'), ('train', 'train')) AS m(mode, route)
  ON m.route = r.tags ->> 'route'
WHERE r.tags ? 'ref'
  AND (m.mode <> 'train'
       OR (r.tags ->> 'ref' !~ '[0-9]{3}'
           AND COALESCE(r.tags ->> 'service', '')
               NOT IN ('high_speed', 'long_distance', 'national', 'international', 'night')));
CREATE INDEX ON line_routes (relation_id);


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
CREATE INDEX ON area_group (group_id);
CREATE INDEX ON area_group (relation_id);


-- @step stop modes
-- Which modes each stop serves. Must match Trainlog's trip types.
CREATE TABLE stop_modes AS
SELECT s.osm_type, s.osm_id, m.mode
FROM stops s
CROSS JOIN LATERAL (VALUES
    ('train',     s.tags ->> 'railway' IN ('station', 'halt')
                  AND COALESCE(s.tags ->> 'station', 'train') = 'train'
                  OR s.tags ->> 'train' = 'yes'),
    ('metro',     s.tags ->> 'station' IN ('subway', 'light_rail', 'monorail')
                  OR s.tags ->> 'subway' = 'yes' OR s.tags ->> 'light_rail' = 'yes'
                  OR s.tags ->> 'monorail' = 'yes'),
    -- Light rail is either, depending on the city: Bybanen is a tram, the DLR a metro.
    ('tram',      s.tags ->> 'railway' = 'tram_stop' OR s.tags ->> 'tram' = 'yes'
                  OR s.tags ->> 'station' = 'light_rail' OR s.tags ->> 'light_rail' = 'yes'),
    ('bus',       s.tags ->> 'highway' = 'bus_stop' OR s.tags ->> 'amenity' = 'bus_station'
                  OR s.tags ->> 'bus' = 'yes'),
    ('ferry',     s.tags ->> 'amenity' = 'ferry_terminal' OR s.tags ->> 'ferry' = 'yes'),
    ('funicular', s.tags ->> 'station' = 'funicular' OR s.tags ->> 'funicular' = 'yes'),
    ('aerialway', s.tags ->> 'aerialway' = 'station')
) AS m(mode, applies)
WHERE m.applies;
CREATE INDEX ON stop_modes (osm_type, osm_id);


-- @step station objects
-- Every object of a station, keyed by what groups them: its stop areas, else its wikidata,
-- else the object alone. Only primary objects (the station, stop or terminal itself) can
-- found a station; platforms and stop positions join one.
CREATE TABLE station_objects AS
WITH object_area AS (
    SELECT rm.osm_type, rm.osm_id, min(ag.group_id) AS group_id
    FROM rel_members rm
    JOIN area_group ag USING (relation_id)
    GROUP BY rm.osm_type, rm.osm_id
)
SELECT sm.mode,
       COALESCE(
           'A' || oa.group_id,
           'Q' || (s.tags ->> 'wikidata'),
           s.osm_type || s.osm_id
       ) AS key,
       s.osm_type, s.osm_id, s.tags, s.geom,
       is_primary_stop(s.tags) AS is_primary
FROM stop_modes sm
JOIN stops s USING (osm_type, osm_id)
LEFT JOIN object_area oa USING (osm_type, osm_id);

-- @step untagged stop positions
-- Stop positions often carry no mode tag; inside a stop_area they belong to its stations.
INSERT INTO station_objects
SELECT DISTINCT a.mode, a.key, s.osm_type, s.osm_id, s.tags, s.geom, false
FROM (SELECT DISTINCT mode, key FROM station_objects WHERE key LIKE 'A%') a
JOIN area_group ag ON ag.group_id = CASE WHEN a.key LIKE 'A%' THEN substr(a.key, 2)::bigint END
JOIN rel_members rm ON rm.relation_id = ag.relation_id
JOIN stops s ON s.osm_type = rm.osm_type AND s.osm_id = rm.osm_id
WHERE NOT EXISTS (SELECT 1 FROM stop_modes sm WHERE sm.osm_type = s.osm_type AND sm.osm_id = s.osm_id);
CREATE INDEX ON station_objects (mode, key);
CREATE INDEX ON station_objects (osm_type, osm_id);

-- @step merge nearby duplicates
-- One station is often several same-named groups close together: a bus stop per side of
-- the street, or two station nodes with no shared stop_area. Clustered within 400m, on an
-- equirectangular projection so that is metres at any latitude.
ALTER TABLE station_objects ADD COLUMN source_key text;
UPDATE station_objects SET source_key = key;

WITH named AS (
    SELECT DISTINCT ON (o.mode, o.key)
           o.mode, o.key, search_fold(COALESCE(o.tags ->> 'name', area.tags ->> 'name')) AS name, o.geom
    FROM station_objects o
    LEFT JOIN rels area
      ON area.relation_id = CASE WHEN o.key LIKE 'A%' THEN substr(o.key, 2)::bigint END
    WHERE o.is_primary
    ORDER BY o.mode, o.key, (o.tags ? 'name') DESC, o.osm_type, o.osm_id
),
clustered AS (
    SELECT mode, key, name,
           ST_ClusterDBSCAN(
               ST_MakePoint(ST_X(geom) * 111320 * cos(radians(ST_Y(geom))), ST_Y(geom) * 110540),
               400, 1)
               OVER (PARTITION BY mode, name) AS cluster
    FROM named
    WHERE name <> ''
),
merged AS (
    SELECT mode, key, min(key) OVER (PARTITION BY mode, name, cluster) AS merged_key
    FROM clustered
)
UPDATE station_objects o SET key = m.merged_key
FROM merged m
WHERE o.mode = m.mode AND o.key = m.key AND m.key <> m.merged_key;


-- @step attach stray stops
-- Stop positions and platforms outside any stop_area form groups of their own, with no
-- station to found. They belong to the nearest station of their mode, when one is close:
-- routes list their calls by these objects, so leaving them out loses the calls.
CREATE INDEX ON station_objects USING gist (mode, geom) WHERE is_primary;
WITH strays AS (
    SELECT DISTINCT ON (o.mode, o.key) o.mode, o.key, o.geom
    FROM station_objects o
    WHERE NOT EXISTS (
        SELECT 1 FROM station_objects p WHERE p.mode = o.mode AND p.key = o.key AND p.is_primary
    )
),
nearest AS (
    SELECT st.mode, st.key, n.key AS station_key
    FROM strays st
    CROSS JOIN LATERAL (
        SELECT p.key, p.geom
        FROM station_objects p
        WHERE p.mode = st.mode AND p.is_primary
        ORDER BY p.geom <-> st.geom
        LIMIT 1
    ) n
    WHERE ST_DWithin(n.geom::geography, st.geom::geography, 400)
)
UPDATE station_objects o SET key = n.station_key
FROM nearest n
WHERE o.mode = n.mode AND o.key = n.key;

-- @step stations
CREATE TABLE stations AS
WITH rep AS (
    SELECT DISTINCT ON (mode, key) mode, key, osm_type, osm_id, tags, geom
    FROM station_objects
    WHERE is_primary
    ORDER BY mode, key, (tags ? 'name') DESC, osm_type, osm_id
),
grouped AS (
    SELECT mode, key,
           jsonb_agg(jsonb_build_array(osm_type, osm_id)) AS objects,
           max(tags ->> 'wikidata') AS wikidata,
           max(tags ->> 'uic_ref') AS uic_ref
    FROM station_objects
    GROUP BY mode, key
),
-- The stop_area relations of each station, which /object must also resolve.
areas AS (
    SELECT o.mode, o.key, jsonb_agg(DISTINCT jsonb_build_array('R', ag.relation_id)) AS objects
    FROM (SELECT DISTINCT mode, key, source_key FROM station_objects WHERE source_key LIKE 'A%') o
    JOIN area_group ag
      ON ag.group_id = CASE WHEN o.source_key LIKE 'A%' THEN substr(o.source_key, 2)::bigint END
    GROUP BY o.mode, o.key
)
SELECT row_number() OVER (ORDER BY r.mode, r.key)::int AS station_id,
       r.mode,
       r.key,
       r.osm_type,
       r.osm_id,
       COALESCE(r.tags ->> 'name', area.tags ->> 'name') AS name,
       COALESCE((
           SELECT jsonb_object_agg(k, v)
           FROM jsonb_each_text(COALESCE(area.tags, '{}') || r.tags) AS t(k, v)
           -- name:<language>[-<script>], not the likes of name:source or name:etymology.
           WHERE k ~ '^name:[a-z]{2,3}([-_][A-Za-z]{2,4})?$'
              OR k IN ('name', 'int_name', 'alt_name', 'official_name', 'short_name',
                       'loc_name', 'nat_name', 'reg_name', 'old_name')
       ), '{}') AS names,
       g.wikidata,
       g.uic_ref,
       r.geom,
       g.objects || COALESCE(a.objects, '[]') AS objects,
       NULL::text AS country,
       NULL::text AS region,
       NULL::jsonb AS city,
       NULL::jsonb AS lines,
       NULL::jsonb AS tracks,
       NULL::text AS station_key,
       NULL::float8 AS weight,
       NULL::text AS latin
FROM rep r
JOIN grouped g USING (mode, key)
LEFT JOIN areas a USING (mode, key)
LEFT JOIN rels area
  ON area.relation_id = CASE WHEN r.key LIKE 'A%' THEN substr(r.key, 2)::bigint END
WHERE COALESCE(r.tags ->> 'name', area.tags ->> 'name') IS NOT NULL;

ALTER TABLE stations ADD PRIMARY KEY (station_id);
CREATE INDEX ON stations USING gist (geom);
CREATE INDEX ON stations USING gist ((geom::geography));
CREATE INDEX ON stations USING gin (objects jsonb_path_ops);
CREATE INDEX ON stations (mode);
CREATE INDEX ON stations (mode, key);


-- @step station keys
-- The key Trainlog stores, unique within the mode: the wikidata item, else the UIC code,
-- else the representative object. The first two survive OSM remapping a station's objects;
-- key_redirects (see build.py) covers the rest.
UPDATE stations s SET station_key = c.key
FROM (
    SELECT DISTINCT ON (station_id) station_id, key
    FROM (
        SELECT s.station_id, k.priority, k.key,
               count(*) OVER (PARTITION BY s.mode, k.key) AS holders
        FROM stations s
        CROSS JOIN LATERAL (VALUES
            (1, CASE WHEN s.wikidata ~ '^Q[0-9]+$' THEN s.wikidata END),
            (2, 'UIC' || NULLIF(trim(s.uic_ref), '')),
            (3, s.osm_type || s.osm_id)
        ) AS k(priority, key)
        WHERE k.key IS NOT NULL
    ) candidates
    WHERE holders = 1
    ORDER BY station_id, priority
) c
WHERE s.station_id = c.station_id;
ALTER TABLE stations ALTER COLUMN station_key SET NOT NULL;
CREATE UNIQUE INDEX ON stations (mode, station_key);


-- @step weights
-- How much a station matters, to order stations matching a search equally well: the routes
-- calling at it, its number of objects, and having a wikidata item. Gare de Lyon over a halt.
UPDATE stations SET weight = ln(1 + jsonb_array_length(objects))::float8
                           + CASE WHEN wikidata IS NOT NULL THEN 0.5 ELSE 0 END;
UPDATE stations s SET weight = s.weight + 2 * ln(1 + r.routes)::float8
FROM (
    SELECT st.station_id, count(DISTINCT rs.relation_id) AS routes
    FROM route_stops rs
    JOIN rels r USING (relation_id)
    JOIN (VALUES ('train', 'train'), ('metro', 'subway'), ('metro', 'light_rail'),
                 ('metro', 'monorail'), ('tram', 'tram'), ('tram', 'light_rail')) AS m(mode, route)
      ON m.route = r.tags ->> 'route'
    JOIN station_objects o ON o.osm_type = rs.osm_type AND o.osm_id = rs.osm_id AND o.mode = m.mode
    JOIN stations st ON st.mode = o.mode AND st.key = o.key
    GROUP BY st.station_id
) r
WHERE s.station_id = r.station_id;


-- @step boundary pieces
-- Boundaries cut into small pieces: a point-in-polygon test then touches a few hundred
-- vertices instead of a whole country's outline.
CREATE TABLE boundary_parts AS
SELECT relation_id, admin_level, tags, ST_Subdivide(geom, 256) AS geom
FROM boundaries;
CREATE INDEX ON boundary_parts USING gist (geom);

-- @step country, region, city
-- One lookup per station for every level at once. The country falls back on the region's
-- ISO3166-2 code ("FR-IDF"), for extracts that cut the country's own boundary.
UPDATE stations s SET
    country = COALESCE(p.country, p.region_country),
    region  = p.region,
    city    = p.city
FROM (
    SELECT s.station_id,
           max(upper(b.tags ->> 'ISO3166-1:alpha2')) FILTER (WHERE b.admin_level = 2) AS country,
           max(upper(left(b.tags ->> 'ISO3166-2', 2))) FILTER (WHERE b.admin_level = 4)
               AS region_country,
           max(b.tags ->> 'name') FILTER (WHERE b.admin_level = 4) AS region,
           (array_agg(jsonb_strip_nulls(jsonb_build_object(
                'name', b.tags ->> 'name', 'name:en', b.tags ->> 'name:en'))
                ORDER BY b.admin_level DESC) FILTER (WHERE b.admin_level BETWEEN 6 AND 8))[1]
               AS city
    FROM stations s
    JOIN boundary_parts b ON ST_Contains(b.geom, s.geom)
    GROUP BY s.station_id
) p
WHERE s.station_id = p.station_id;


-- @step station lines
-- Each line's point is a stop of that line, preferably its stop position, which sits on
-- the line's own track.
WITH line_stops AS (
    SELECT DISTINCT ON (st.station_id, lr.tags ->> 'ref')
           st.station_id,
           lr.tags ->> 'ref' AS ref,
           lr.tags ->> 'colour' AS colour,
           ST_Y(o.geom) AS lat,
           ST_X(o.geom) AS lng
    FROM stations st
    JOIN station_objects o ON o.mode = st.mode AND o.key = st.key
    JOIN rel_members rm ON rm.osm_type = o.osm_type AND rm.osm_id = o.osm_id
    JOIN line_routes lr ON lr.relation_id = rm.relation_id AND lr.mode = st.mode
    ORDER BY st.station_id, lr.tags ->> 'ref',
             (o.tags ->> 'public_transport' = 'stop_position') IS TRUE DESC
)
UPDATE stations s SET lines = l.lines
FROM (
    SELECT station_id,
           jsonb_agg(jsonb_build_object('ref', ref, 'colour', colour, 'lat', lat, 'lng', lng)
                     ORDER BY length(ref), ref) AS lines
    FROM line_stops
    GROUP BY station_id
) l
WHERE s.station_id = l.station_id;


-- @step station tracks
-- Where a vehicle calling at a given track stops, for rail modes, as timetables give their
-- tracks: [{ref, lat, lng, on_track}]. A stop position sits on the track itself; a platform
-- ("1;3") sits between its tracks, so it only stands in for a track with no stop position.
WITH refs AS (
    SELECT st.station_id, n.ref,
           o.tags ->> 'public_transport' = 'stop_position' IS TRUE AS on_track,
           o.geom, st.geom AS station_geom
    FROM stations st
    JOIN station_objects o ON o.mode = st.mode AND o.key = st.key
    CROSS JOIN LATERAL regexp_split_to_table(
        COALESCE(o.tags ->> 'railway:track_ref', o.tags ->> 'local_ref', o.tags ->> 'ref'), ';') AS r
    -- "Voie 2", "Gleis 7": the track is the part after the word.
    CROSS JOIN LATERAL (SELECT regexp_replace(trim(r),
        '^(voie|gleis|gl\.?|track|platform|quai|binario|v[ií]a|spoor|tor|peron)\s*', '', 'i') AS ref) n
    WHERE st.mode IN ('train', 'metro', 'tram', 'funicular')
      AND (o.tags ->> 'public_transport' IN ('stop_position', 'platform')
           OR o.tags ->> 'railway' = 'platform')
),
best AS (
    SELECT DISTINCT ON (station_id, ref) station_id, ref, on_track, geom
    FROM refs
    -- Shaped like a track: "7", "112", "12a", "A", "M3". Leaves out the stop codes some tram and
    -- metro stops carry as ref ("41135", "275A") and words ("Entrée").
    WHERE ref ~ '^([0-9]{1,3}|[0-9]{1,2}[A-Za-z]|[A-Za-z]{1,2}[0-9]{0,2})$'
    ORDER BY station_id, ref, on_track DESC, geom <-> station_geom
)
UPDATE stations s SET tracks = t.tracks
FROM (
    SELECT station_id,
           jsonb_agg(jsonb_build_object('ref', ref, 'lat', round(ST_Y(geom)::numeric, 6),
                                        'lng', round(ST_X(geom)::numeric, 6), 'on_track', on_track)
                     ORDER BY length(ref), ref) AS tracks
    FROM best
    GROUP BY station_id
) t
WHERE s.station_id = t.station_id;


-- @step latin names
-- @python latin_names


-- @step search names
-- Every spelling to search on, one partition per mode so that a search reads its mode's
-- names only: bus stops are nine stations in ten. Each name is also prefixed with its city
-- ("Paris Gare de Lyon"), marked as such since it matches every station of the city.
CREATE TABLE station_names (
    station_id    integer NOT NULL,
    mode          text NOT NULL,
    name          text NOT NULL,
    city_prefixed boolean NOT NULL,
    folded        text GENERATED ALWAYS AS (search_fold(name)) STORED
) PARTITION BY LIST (mode);

DO $$
DECLARE
    m text;
BEGIN
    FOR m IN SELECT DISTINCT mode FROM stations LOOP
        EXECUTE format('CREATE TABLE %I PARTITION OF station_names FOR VALUES IN (%L)',
                       'station_names_' || m, m);
    END LOOP;
END $$;

INSERT INTO station_names (station_id, mode, name, city_prefixed)
SELECT DISTINCT s.station_id, s.mode, trim(part), false
FROM stations s,
     jsonb_each_text(s.names || jsonb_build_object('latin', s.latin)) AS n(k, v),
     regexp_split_to_table(n.v, ';') AS part
WHERE trim(part) <> '';

INSERT INTO station_names (station_id, mode, name, city_prefixed)
SELECT DISTINCT n.station_id, n.mode, c.city || ' ' || n.name, true
FROM station_names n
JOIN stations s USING (station_id)
CROSS JOIN LATERAL (VALUES (s.city ->> 'name'), (s.city ->> 'name:en')) AS c(city)
WHERE c.city IS NOT NULL AND n.folded NOT LIKE '%' || search_fold(c.city) || '%';

CREATE INDEX ON station_names USING gin (folded gin_trgm_ops);
CREATE INDEX ON station_names (folded text_pattern_ops);
CREATE INDEX ON station_names (station_id);

-- @step analyze
ANALYZE;
