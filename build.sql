-- Turns the raw osm2pgsql tables (stops, rels, boundaries) into one row per station and
-- mode, with its names, place and lines, ready to search.

-- @step setup
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE OR REPLACE FUNCTION fold(text) RETURNS text AS $$
    SELECT lower(public.unaccent('public.unaccent'::regdictionary, COALESCE($1, '')))
$$ LANGUAGE sql IMMUTABLE;

-- The station, stop or terminal itself, as opposed to its platforms and stop positions.
CREATE OR REPLACE FUNCTION is_primary_stop(tags jsonb) RETURNS boolean AS $$
    SELECT (tags ->> 'railway' IN ('station', 'halt', 'tram_stop')
            OR tags ->> 'highway' = 'bus_stop'
            OR tags ->> 'amenity' IN ('bus_station', 'ferry_terminal')
            OR tags ->> 'aerialway' = 'station'
            OR tags ->> 'public_transport' = 'station') IS TRUE
$$ LANGUAGE sql IMMUTABLE;

DROP TABLE IF EXISTS station_names, stations, station_objects, stop_modes, area_group, line_routes,
    rel_members, route_stops, boundary_parts;


-- @step relation members
CREATE TABLE rel_members AS
SELECT r.relation_id,
       r.tags ->> 'public_transport' = 'stop_area' AS is_stop_area,
       r.tags ->> 'route' AS route,
       e.member ->> 'type' AS osm_type,
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
    ('tram',      s.tags ->> 'railway' = 'tram_stop' OR s.tags ->> 'tram' = 'yes'),
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
           o.mode, o.key, fold(COALESCE(o.tags ->> 'name', area.tags ->> 'name')) AS name, o.geom
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
           WHERE k LIKE 'name:%'
              OR k IN ('name', 'int_name', 'alt_name', 'official_name', 'short_name', 'loc_name')
       ), '{}') AS names,
       g.wikidata,
       g.uic_ref,
       r.geom,
       g.objects || COALESCE(a.objects, '[]') AS objects,
       NULL::text AS country,
       NULL::text AS region,
       NULL::jsonb AS city,
       NULL::jsonb AS lines
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


-- @step boundary pieces
-- Boundaries cut into small pieces: a point-in-polygon test then touches a few hundred
-- vertices instead of a whole country's outline.
CREATE TABLE boundary_parts AS
SELECT relation_id, admin_level, tags, ST_Subdivide(geom, 256) AS geom
FROM boundaries;
CREATE INDEX ON boundary_parts USING gist (geom);

-- @step country, region, city
UPDATE stations s SET
    -- Falls back on the region's ISO3166-2 code ("FR-IDF"), for extracts that cut the
    -- country's own boundary.
    country = COALESCE(
        (SELECT upper(b.tags ->> 'ISO3166-1:alpha2') FROM boundary_parts b
         WHERE b.admin_level = 2 AND ST_Contains(b.geom, s.geom) LIMIT 1),
        (SELECT upper(left(b.tags ->> 'ISO3166-2', 2)) FROM boundary_parts b
         WHERE b.admin_level = 4 AND b.tags ? 'ISO3166-2' AND ST_Contains(b.geom, s.geom) LIMIT 1)
    ),
    region  = (SELECT b.tags ->> 'name' FROM boundary_parts b
               WHERE b.admin_level = 4 AND ST_Contains(b.geom, s.geom) LIMIT 1),
    city    = (SELECT jsonb_strip_nulls(jsonb_build_object(
                          'name', b.tags ->> 'name', 'name:en', b.tags ->> 'name:en'))
               FROM boundary_parts b
               WHERE b.admin_level BETWEEN 6 AND 8 AND ST_Contains(b.geom, s.geom)
               ORDER BY b.admin_level DESC LIMIT 1);


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


-- @step search names
-- Every spelling to search on, plus each prefixed with its city ("Paris Gare de Lyon").
CREATE TABLE station_names AS
SELECT DISTINCT s.station_id, trim(part) AS name
FROM stations s,
     jsonb_each_text(s.names) AS n(k, v),
     regexp_split_to_table(n.v, ';') AS part
WHERE trim(part) <> '';

INSERT INTO station_names
SELECT DISTINCT n.station_id, c.city || ' ' || n.name
FROM station_names n
JOIN stations s USING (station_id)
CROSS JOIN LATERAL (VALUES (s.city ->> 'name'), (s.city ->> 'name:en')) AS c(city)
WHERE c.city IS NOT NULL AND fold(n.name) NOT LIKE '%' || fold(c.city) || '%';

ALTER TABLE station_names ADD COLUMN folded text GENERATED ALWAYS AS (fold(name)) STORED;
CREATE INDEX ON station_names USING gin (folded gin_trgm_ops);
CREATE INDEX ON station_names (folded text_pattern_ops);
CREATE INDEX ON station_names (station_id);

-- @step analyze
ANALYZE;
