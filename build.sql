-- Turns the raw osm2pgsql tables (stops, rels, boundaries) into one row per station and
-- mode, with its names, place and lines, ready to search.
--
-- Runs in the `build` schema, which build.py swaps in for `live` once complete. Extensions
-- and functions live in public, which is not swapped.

-- @step setup
CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA public;
CREATE EXTENSION IF NOT EXISTS unaccent SCHEMA public;
CREATE EXTENSION IF NOT EXISTS btree_gist SCHEMA public;

-- The functions are PARALLEL SAFE, as otherwise any query calling one runs on a single core.

CREATE OR REPLACE FUNCTION public.fold(text) RETURNS text AS $$
    SELECT lower(public.unaccent('public.unaccent'::regdictionary, COALESCE($1, '')))
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- What names and queries are compared on: folded, apostrophes dropped and other punctuation
-- turned into single spaces, so "St. Gallen" is "st gallen" and "Lyon-Part-Dieu" has the
-- word "part". A separate function from fold(), which the live tables were built with.
CREATE OR REPLACE FUNCTION public.search_fold(text) RETURNS text AS $$
    SELECT trim(regexp_replace(
        regexp_replace(public.fold($1), '[''’]', '', 'g'),
        '[^[:alnum:]]+', ' ', 'g'))
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- A name without its quay: "Olav Kyrres gate (J)" is quay J of Olav Kyrres gate, as Norway
-- names its stops, and "Royan - Gare (Quai C)" quay C of Royan - Gare. The quay becomes one
-- of the station's tracks.
CREATE OR REPLACE FUNCTION public.without_quay(text) RETURNS text AS $$
    SELECT regexp_replace($1,
        '\s+\((?:(?:[Qq]uai|[Qq]uay|[Bb]ay|[Ss]tand|[Vv]oie|[Pp]latform|[Pp]lateforme)\s+)?([A-Z]{1,2}[0-9]{0,2}|[0-9]{1,2}[A-Z]?)\)$', '')
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- A name without the line or mode it ends with: "Charles de Gaulle — Étoile (Métro 6)",
-- "(RER A)", "(Ligne 1)", "(Tram T2)", "(U-Bahn)". One station mapped once per line, which
-- the merge (merge nearby duplicates) makes one again.
CREATE OR REPLACE FUNCTION public.without_line(text) RETURNS text AS $$
    SELECT regexp_replace($1,
        '\s*[(\[](?:m[ée]tro|rer|tram(?:way)?|ligne|line|linie|lijn|linea|línea|u-?bahn|s-?bahn|'
        'stadtbahn|subway|bus|trolleybus)\y[^)\]]*[)\]]\s*$', '', 'i')
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION public.quay_of(text) RETURNS text AS $$
    SELECT substring($1 FROM
        '\s\((?:(?:[Qq]uai|[Qq]uay|[Bb]ay|[Ss]tand|[Vv]oie|[Pp]latform|[Pp]lateforme)\s+)?([A-Z]{1,2}[0-9]{0,2}|[0-9]{1,2}[A-Z]?)\)$')
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- The code of a stop named only as a quay: "B3", "C11", "35", "Quai n°10", "Bay 12". Such a
-- stop is a quay of the station around it (Oslo bussterminal's, Agen's), not a station.
CREATE OR REPLACE FUNCTION public.quay_code(text) RETURNS text AS $$
    SELECT (regexp_match($1,
        '^(?:(?:[Qq]uai|[Qq]uay|[Bb]ay|[Ss]tand|[Vv]oie|[Pp]latform|[Pp]lateforme|[Pp]erron|'
        '[Bb]ahnsteig|[Aa]ndén|[Bb]inario|[Ss]por|[Ll]aituri)\s*(?:n[°o]\.?\s*)?)?'
        '([A-Z]{1,2}[0-9]{0,2}|[0-9]{1,3}[A-Z]?)$'))[1]
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION public.is_quay_code(text) RETURNS boolean AS $$
    SELECT quay_code($1) IS NOT NULL
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- The station, stop or terminal itself, as opposed to its platforms and stop positions.
CREATE OR REPLACE FUNCTION public.is_primary_stop(tags jsonb) RETURNS boolean AS $$
    SELECT (tags ->> 'railway' IN ('station', 'halt', 'tram_stop')
            OR tags ->> 'highway' = 'bus_stop'
            OR tags ->> 'amenity' IN ('bus_station', 'ferry_terminal')
            OR tags ->> 'aerialway' = 'station'
            OR tags ->> 'public_transport' = 'station') IS TRUE
       AND NOT is_quay_code(tags ->> 'name')
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- osm2pgsql indexes these by position only; /line looks routes and stops up by id.
CREATE INDEX IF NOT EXISTS stops_osm_id_idx ON stops (osm_type, osm_id);
CREATE INDEX IF NOT EXISTS rels_relation_id_idx ON rels (relation_id);

DROP TABLE IF EXISTS platform_stops, key_redirects, station_names, stations, station_objects, stop_modes, area_group, line_routes,
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
CREATE UNLOGGED TABLE area_group AS
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
CREATE UNLOGGED TABLE stop_modes AS
SELECT s.osm_type, s.osm_id, m.mode
FROM stops s
CROSS JOIN LATERAL (VALUES
    -- train=yes on a metro station (Paris's Gare d'Austerlitz, Bérault) is mapper noise: the
    -- trains stop at the station beside it. Tram-trains (station=light_rail) keep it.
    ('train',     s.tags ->> 'railway' IN ('station', 'halt')
                  AND COALESCE(s.tags ->> 'station', 'train') = 'train'
                  OR s.tags ->> 'train' = 'yes'
                  AND COALESCE(s.tags ->> 'station', '') NOT IN ('subway', 'monorail')),
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
CREATE UNLOGGED TABLE station_objects AS
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
-- Not its entrances, which say nothing about where trains stop.
INSERT INTO station_objects
SELECT DISTINCT a.mode, a.key, s.osm_type, s.osm_id, s.tags, s.geom, false
FROM (SELECT DISTINCT mode, key FROM station_objects WHERE key LIKE 'A%') a
JOIN area_group ag ON ag.group_id = CASE WHEN a.key LIKE 'A%' THEN substr(a.key, 2)::bigint END
JOIN rel_members rm ON rm.relation_id = ag.relation_id
JOIN stops s ON s.osm_type = rm.osm_type AND s.osm_id = rm.osm_id
WHERE NOT EXISTS (SELECT 1 FROM stop_modes sm WHERE sm.osm_type = s.osm_type AND sm.osm_id = s.osm_id)
  AND COALESCE(s.tags ->> 'railway', '') NOT IN ('subway_entrance', 'train_station_entrance')
  AND NOT s.tags ? 'entrance';
CREATE INDEX ON station_objects (mode, key);
CREATE INDEX ON station_objects (osm_type, osm_id);

-- @step merge nearby duplicates
-- One station is often several same-named groups close together: a bus stop per side of
-- the street, a quay each ("(E)", "(F)"), one with its town and one without ("Royan - Gare",
-- "Gare"), one per line ("Charles de Gaulle — Étoile (Métro 1)", "(Métro 6)"), or two station
-- nodes with no shared stop_area. Clustered within 400m, on an equirectangular projection so
-- that is metres at any latitude.
ALTER TABLE station_objects ADD COLUMN source_key text;
UPDATE station_objects SET source_key = key;

WITH named AS (
    SELECT DISTINCT ON (o.mode, o.key)
           o.mode, o.key,
           -- Without a leading place either ("Royan - Gare (Quai C)" beside "Gare"): only
           -- stops of one mode within 400m are compared.
           search_fold(regexp_replace(
               without_line(without_quay(COALESCE(o.tags ->> 'name', area.tags ->> 'name'))),
               '^.+?\s+-\s+', '')) AS name,
           o.geom
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
ANALYZE station_objects;
-- Found into a table first: a query creating one runs on all cores, an UPDATE on one.
CREATE UNLOGGED TABLE stray_stations AS
WITH strays AS (
    SELECT DISTINCT ON (o.mode, o.key) o.mode, o.key, o.geom
    FROM station_objects o
    WHERE NOT EXISTS (
        SELECT 1 FROM station_objects p WHERE p.mode = o.mode AND p.key = o.key AND p.is_primary
    )
)
SELECT st.mode, st.key, n.key AS station_key
FROM strays st
CROSS JOIN LATERAL (
    SELECT p.key, p.geom
    FROM station_objects p
    WHERE p.mode = st.mode AND p.is_primary
    ORDER BY p.geom <-> st.geom
    LIMIT 1
) n
WHERE ST_DWithin(n.geom::geography, st.geom::geography, 400);
UPDATE station_objects o SET key = n.station_key
FROM stray_stations n
WHERE o.mode = n.mode AND o.key = n.key;
DROP TABLE stray_stations;

-- @step bus stations
-- A bus station and the stops around it are one station, whatever their names ("Gare SNCF"
-- beside "Gare Routière Agen"): each bus stop group within 80m of a bus station joins the
-- nearest. 80m keeps the stops across the street ("Gare - Carnot") apart.
WITH bus_stations AS (
    SELECT DISTINCT ON (key) key, geom
    FROM station_objects
    WHERE mode = 'bus' AND is_primary AND tags ->> 'amenity' = 'bus_station'
    ORDER BY key, osm_type, osm_id
),
absorbed AS (
    SELECT DISTINCT ON (g.key) g.key, b.key AS into_key
    FROM bus_stations b
    JOIN station_objects g
      ON g.mode = 'bus' AND g.is_primary AND g.key <> b.key
     AND g.geom && ST_Expand(b.geom, 0.002)
     AND ST_DWithin(g.geom::geography, b.geom::geography, 80)
    WHERE NOT EXISTS (SELECT 1 FROM bus_stations x WHERE x.key = g.key)
    ORDER BY g.key, ST_Distance(g.geom, b.geom)
)
UPDATE station_objects o SET key = a.into_key
FROM absorbed a
WHERE o.mode = 'bus' AND o.key = a.key;


-- @step stations
CREATE UNLOGGED TABLE stations AS
WITH rep AS (
    SELECT DISTINCT ON (mode, key) mode, key, osm_type, osm_id, tags, geom
    FROM station_objects
    WHERE is_primary
    -- A bus station over the stops it gathers; one named as the station, not one of its lines.
    ORDER BY mode, key, (tags ->> 'amenity' = 'bus_station') IS TRUE DESC, (tags ? 'name') DESC,
             (tags ->> 'name' IS DISTINCT FROM without_line(tags ->> 'name')),
             osm_type, osm_id
),
grouped AS (
    SELECT mode, key,
           jsonb_agg(jsonb_build_array(osm_type, osm_id)) AS objects,
           max(tags ->> 'wikidata') AS wikidata,
           max(tags ->> 'uic_ref') AS uic_ref,
           count(DISTINCT source_key) > 1 AS merged
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
       -- A station merged from several, not named after one of their lines.
       CASE WHEN g.merged THEN without_line(without_quay(COALESCE(r.tags ->> 'name', area.tags ->> 'name')))
            ELSE without_quay(COALESCE(r.tags ->> 'name', area.tags ->> 'name')) END AS name,
       COALESCE((
           SELECT jsonb_object_agg(k, without_quay(v))
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
       NULL::boolean AS city_override,
       NULL::jsonb AS lines,
       NULL::jsonb AS tracks,
       NULL::text AS station_key,
       NULL::float8 AS weight,
       NULL::text AS latin,
       NULL::bigint[] AS boundary_ids,
       NULL::text AS line_name,
       NULL::text AS ski_area,
       NULL::text AS lift_end,
       NULL::jsonb AS settlement,
       NULL::boolean AS needs_place
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


-- @step lift ends
-- A named lift with no named station mapped at an end (Tråstølheisen): a station there, known by
-- the lift's name and which end it is (lift_end: lower at its first node, upper at its last,
-- lifts being mapped uphill); Trainlog writes the end in the user's language. Not where
-- another way of the same lift goes on (a joint), nor for funiculars, whose tracks come in
-- pieces.
INSERT INTO stations (station_id, mode, key, osm_type, osm_id, name, names, geom, objects,
                      station_key, line_name, lift_end)
SELECT (SELECT max(station_id) FROM stations) + row_number() OVER (ORDER BY e.way_id, e.lift_end),
       'aerialway', 'L' || e.way_id || e.lift_end, 'W', e.way_id, e.name,
       jsonb_build_object('name', e.name), e.geom,
       jsonb_build_array(jsonb_build_array('W', e.way_id)),
       'W' || e.way_id || ':' || e.lift_end, e.name, e.lift_end
FROM (
    SELECT w.way_id, w.name, v.lift_end, v.geom
    FROM line_ways w
    CROSS JOIN LATERAL (VALUES ('lower', ST_StartPoint(w.geom)),
                               ('upper', ST_EndPoint(w.geom))) AS v(lift_end, geom)
    WHERE w.kind = 'aerialway'
) e
WHERE NOT EXISTS (
        -- A station mapped without a name (Romsdalsgondolen's) is none: it cannot be one
        -- of quai's, which are named.
        SELECT 1 FROM station_objects o
        WHERE o.mode = 'aerialway' AND o.is_primary AND o.tags ? 'name'
          AND o.geom && ST_Expand(e.geom, 0.002)
          AND ST_DWithin(o.geom::geography, e.geom::geography, 60))
  AND NOT EXISTS (
        SELECT 1 FROM line_ways other
        WHERE other.kind = 'aerialway' AND other.way_id <> e.way_id AND other.name = e.name
          AND other.geom && ST_Expand(e.geom, 0.0005)
          AND ST_DWithin(other.geom::geography, e.geom::geography, 5));


-- @step station keys
-- The key Trainlog stores, unique within the mode: the wikidata item, else the UIC code,
-- else the representative object. The first two survive OSM remapping a station's objects;
-- key_redirects (see build.py) covers the rest. A lift's end has its own already.
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
        WHERE k.key IS NOT NULL AND s.station_key IS NULL
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
CREATE UNLOGGED TABLE boundary_parts AS
SELECT relation_id, admin_level, tags, ST_Subdivide(geom, 256) AS geom
FROM boundaries;
CREATE INDEX ON boundary_parts USING gist (geom);

-- @step city overrides
-- @python load_city_overrides


-- @step country, region, city
-- One lookup per station for every level at once. The country falls back on the region's
-- ISO3166-2 code ("FR-IDF"), for extracts that cut the country's own boundary. The city is
-- the smallest boundary places.csv names (city_overrides), else the lowest municipality.
-- Found into a table first, on all cores, then set in one pass.
CREATE UNLOGGED TABLE station_places AS
    SELECT s.station_id,
           max(upper(b.tags ->> 'ISO3166-1:alpha2')) FILTER (WHERE b.admin_level = 2) AS country,
           max(upper(left(b.tags ->> 'ISO3166-2', 2))) FILTER (WHERE b.admin_level = 4)
               AS region_country,
           max(b.tags ->> 'name') FILTER (WHERE b.admin_level = 4) AS region,
           COALESCE(
               (array_agg(jsonb_strip_nulls(jsonb_build_object(
                    'name', COALESCE(co.name, b.tags ->> 'name'),
                    'name:en', COALESCE(co.name_en, co.name, b.tags ->> 'name:en')))
                    ORDER BY b.admin_level DESC) FILTER (WHERE co.relation_id IS NOT NULL))[1],
               (array_agg(jsonb_strip_nulls(jsonb_build_object(
                    'name', b.tags ->> 'name', 'name:en', b.tags ->> 'name:en'))
                    ORDER BY b.admin_level DESC) FILTER (WHERE b.admin_level BETWEEN 6 AND 8))[1]
           ) AS city,
           -- The city is one places.csv names (London, not Camden): a name's prefix then.
           bool_or(co.relation_id IS NOT NULL) AS city_override,
           array_agg(DISTINCT b.relation_id)
               FILTER (WHERE b.admin_level BETWEEN 4 AND 8 OR co.relation_id IS NOT NULL)
               AS boundary_ids
    FROM stations s
    JOIN boundary_parts b ON ST_Contains(b.geom, s.geom)
    LEFT JOIN city_overrides co ON co.relation_id = b.relation_id
    GROUP BY s.station_id;
UPDATE stations s SET
    country = COALESCE(p.country, p.region_country),
    region  = p.region,
    city    = p.city,
    city_override = p.city_override,
    boundary_ids = p.boundary_ids
FROM station_places p
WHERE s.station_id = p.station_id;
DROP TABLE station_places;


-- @step settlements
-- The town, village or hamlet a station is at (Åndalsnes, in Rauma kommune), which people
-- know it by better than its municipality: searched on, shown, and put before a name that
-- needs a place. Of the places within their kind's reach (a city 8km, a town 4km, a village
-- 2km, a hamlet 800m), so that a station by a village is in it however large its
-- municipality: first those in the station's own municipality, as Gare de Dax is in Dax
-- though Saint-Paul-lès-Dax, over the commune's edge, is nearer; then a city, whose hamlets
-- are its neighbourhoods (Fyllingsdalen terminal is in Bergen, not Sælen); then the nearest
-- relative to its reach. Not suburbs or districts:
-- Paris's stations are in Paris, not Bercy.
-- A municipality is the lowest boundary of levels 6 to 8 (Camden, in London: Euston is in
-- Camden Town, which helps tell it apart, though its prefix is London's, city_override).
-- Every one each place is in, found once.
CREATE UNLOGGED TABLE muni_levels AS
SELECT relation_id, admin_level FROM boundaries WHERE admin_level BETWEEN 6 AND 8;
CREATE INDEX ON muni_levels (relation_id);
CREATE UNLOGGED TABLE place_munis AS
SELECT DISTINCT pl.node_id, b.relation_id
FROM places pl
JOIN boundary_parts b ON ST_Contains(b.geom, pl.geom)
JOIN muni_levels ml ON ml.relation_id = b.relation_id;
CREATE INDEX ON place_munis (node_id, relation_id);
ANALYZE muni_levels;
ANALYZE place_munis;
CREATE UNLOGGED TABLE station_settlements AS
SELECT s.station_id, p.settlement
FROM stations s
LEFT JOIN LATERAL (
    SELECT ml.relation_id
    FROM unnest(s.boundary_ids) AS bid
    JOIN muni_levels ml ON ml.relation_id = bid
    ORDER BY ml.admin_level DESC
    LIMIT 1
) muni ON true
CROSS JOIN LATERAL (
    SELECT jsonb_strip_nulls(jsonb_build_object(
               'name', near.tags ->> 'name', 'name:en', near.tags ->> 'name:en', 'place', near.place))
               AS settlement
    FROM (
        SELECT pl.node_id, pl.place, pl.tags,
               ST_DistanceSphere(pl.geom, s.geom) / CASE pl.place
                   WHEN 'city' THEN 8000 WHEN 'town' THEN 4000 WHEN 'village' THEN 2000 ELSE 800
               END AS reach
        FROM places pl
        WHERE pl.geom && ST_Expand(s.geom, 0.15)
        ORDER BY pl.geom <-> s.geom
        LIMIT 16
    ) near
    LEFT JOIN place_munis pm ON pm.node_id = near.node_id AND pm.relation_id = muni.relation_id
    WHERE near.reach <= 1
    ORDER BY pm.node_id IS NOT NULL DESC,
             near.place = 'city' DESC,
             near.reach
    LIMIT 1
) p;
UPDATE stations s SET settlement = x.settlement
FROM station_settlements x
WHERE s.station_id = x.station_id;
DROP TABLE station_settlements, place_munis, muni_levels;


-- @step station lines
-- Each line calling at the station, at the middle of its stop positions there (else of its
-- platforms): between its own tracks, as the line says which platforms but not which
-- direction. Never on_track: one stop position is as often one direction mapped as a
-- terminus.
WITH line_objects AS (
    SELECT DISTINCT ON (st.station_id, lr.tags ->> 'ref', o.osm_type, o.osm_id)
           st.station_id,
           lr.tags ->> 'ref' AS ref,
           lr.tags ->> 'colour' AS colour,
           o.geom,
           (o.tags ->> 'public_transport' = 'stop_position') IS TRUE AS is_stop_position
    FROM stations st
    JOIN station_objects o ON o.mode = st.mode AND o.key = st.key
    JOIN rel_members rm ON rm.osm_type = o.osm_type AND rm.osm_id = o.osm_id
    JOIN line_routes lr ON lr.relation_id = rm.relation_id AND lr.mode = st.mode
    ORDER BY st.station_id, lr.tags ->> 'ref', o.osm_type, o.osm_id
),
line_points AS (
    SELECT station_id, ref, max(colour) AS colour,
           ST_Centroid(COALESCE(ST_Collect(geom) FILTER (WHERE is_stop_position), ST_Collect(geom))) AS geom
    FROM line_objects
    GROUP BY station_id, ref
)
UPDATE stations s SET lines = l.lines
FROM (
    SELECT station_id,
           jsonb_agg(jsonb_build_object('ref', ref, 'colour', colour,
                                        'lat', ST_Y(geom), 'lng', ST_X(geom))
                     ORDER BY length(ref), ref) AS lines
    FROM line_points
    GROUP BY station_id
) l
WHERE s.station_id = l.station_id;


-- @step platform stop positions
-- A platform numbered for one track, whose stop position on that track is unnumbered (Myrdal's
-- "2"): its track can sit on the stop position. Only when unambiguous: each is the other's
-- nearest, within 30m, with the platform's next stop position at least half as far again.
-- Not a "1;2" island platform, which cannot say which of its two stop positions is which.
CREATE UNLOGGED TABLE platform_stops AS
WITH platforms AS (
    SELECT st.station_id, o.osm_type, o.osm_id, o.geom
    FROM stations st
    JOIN station_objects o ON o.mode = st.mode AND o.key = st.key
    WHERE st.mode IN ('train', 'metro', 'tram', 'funicular')
      AND (o.tags ->> 'public_transport' = 'platform' OR o.tags ->> 'railway' = 'platform')
      AND COALESCE(o.tags ->> 'railway:track_ref', o.tags ->> 'local_ref', o.tags ->> 'ref') ~ '^[^;]+$'
),
stops AS (
    SELECT st.station_id, o.osm_type, o.osm_id, o.geom
    FROM stations st
    JOIN station_objects o ON o.mode = st.mode AND o.key = st.key
    WHERE st.mode IN ('train', 'metro', 'tram', 'funicular')
      AND o.tags ->> 'public_transport' = 'stop_position'
      AND NOT o.tags ?| array['railway:track_ref', 'local_ref', 'ref']
),
pairs AS (
    SELECT p.station_id, p.osm_type, p.osm_id, s.geom AS stop_geom,
           ST_Distance(p.geom::geography, s.geom::geography) AS d,
           row_number() OVER (PARTITION BY p.station_id, p.osm_type, p.osm_id ORDER BY p.geom <-> s.geom) AS for_platform,
           row_number() OVER (PARTITION BY s.station_id, s.osm_type, s.osm_id ORDER BY p.geom <-> s.geom) AS for_stop
    FROM platforms p
    JOIN stops s USING (station_id)
)
SELECT a.station_id, a.osm_type, a.osm_id, a.stop_geom
FROM pairs a
LEFT JOIN pairs b ON b.station_id = a.station_id AND b.osm_type = a.osm_type AND b.osm_id = a.osm_id
                 AND b.for_platform = 2
WHERE a.for_platform = 1 AND a.for_stop = 1 AND a.d <= 30 AND (b.d IS NULL OR b.d >= 1.5 * a.d);
CREATE INDEX ON platform_stops (station_id, osm_type, osm_id);


-- @step station tracks
-- Where a vehicle calling at a given track stops, as timetables give their tracks (a bus
-- station's or a stop's quays alike): [{ref, lat, lng, on_track}]. A stop position sits on the track itself; a platform
-- ("1;3") sits between its tracks, so it only stands in for a track with no stop position.
WITH refs AS (
    SELECT st.station_id, n.ref,
           (o.tags ->> 'public_transport' = 'stop_position' OR ps.station_id IS NOT NULL) IS TRUE AS on_track,
           COALESCE(ps.stop_geom, o.geom) AS geom, st.geom AS station_geom
    FROM stations st
    JOIN station_objects o ON o.mode = st.mode AND o.key = st.key
    LEFT JOIN platform_stops ps
      ON ps.station_id = st.station_id AND ps.osm_type = o.osm_type AND ps.osm_id = o.osm_id
    CROSS JOIN LATERAL regexp_split_to_table(
        COALESCE(o.tags ->> 'railway:track_ref', o.tags ->> 'local_ref',
                 quay_code(o.tags ->> 'name'),
                 quay_of(o.tags ->> 'name'),
                 -- A bus or ferry stop's ref is its network's stop code ("5" at Agen - Gare
                 -- SNCF), not a quay: their quays are local_ref, or in their names.
                 CASE WHEN st.mode NOT IN ('bus', 'ferry') THEN o.tags ->> 'ref' END), ';') AS r
    -- "Voie 2", "Gleis 7": the track is the part after the word.
    CROSS JOIN LATERAL (SELECT regexp_replace(trim(r),
        '^(voie|gleis|gl\.?|track|platform|quai|binario|v[ií]a|spoor|tor|peron)\s*', '', 'i') AS ref) n
    WHERE st.mode IN ('train', 'metro', 'tram', 'funicular', 'bus', 'ferry')
      AND (o.tags ->> 'public_transport' IN ('stop_position', 'platform')
           OR o.tags ->> 'railway' = 'platform' OR o.tags ->> 'highway' = 'bus_stop')
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


-- @step lift lines
-- The line an aerialway or funicular station is on, by the name people know it under
-- (Fløibanen, Ulriksbanen): the named line passing within 60m of it, when only one does. A
-- ski area's hub where several lifts meet gets none.
UPDATE stations s SET line_name = l.name
FROM (
    SELECT st.station_id, min(w.name) AS name
    FROM stations st
    JOIN line_ways w
      ON w.kind = st.mode
     AND w.geom && ST_Expand(st.geom, 0.002)
     AND ST_DWithin(w.geom::geography, st.geom::geography, 60)
    WHERE st.mode IN ('aerialway', 'funicular')
    GROUP BY st.station_id
    HAVING count(DISTINCT w.name) = 1
) l
WHERE s.station_id = l.station_id;

-- Where several pass, the one named as the station: Val Louron's Ardounes and Tuco run side by
-- side, 6m apart, each station named as its own lift.
UPDATE stations s SET line_name = l.name
FROM (
    SELECT DISTINCT ON (st.station_id) st.station_id, w.name
    FROM stations st
    JOIN line_ways w
      ON w.kind = st.mode
     AND w.geom && ST_Expand(st.geom, 0.002)
     AND ST_DWithin(w.geom::geography, st.geom::geography, 60)
     AND search_fold(w.name) = search_fold(st.name)
    WHERE st.mode IN ('aerialway', 'funicular') AND st.line_name IS NULL
    ORDER BY st.station_id, w.geom <-> st.geom
) l
WHERE s.station_id = l.station_id;

-- A lift's two stations named alike (Val Thorens's "Boismint" at both ends): told apart as its
-- lower and upper ends, by which end of the line each is nearer, as for the ends no station
-- is mapped at (lift_end).
UPDATE stations s SET lift_end = CASE
        WHEN ST_Distance(s.geom, ST_StartPoint(w.geom)) <= ST_Distance(s.geom, ST_EndPoint(w.geom))
        THEN 'lower' ELSE 'upper' END
FROM line_ways w
WHERE s.mode = 'aerialway' AND s.lift_end IS NULL
  AND w.kind = 'aerialway' AND w.name = s.line_name
  AND w.geom && ST_Expand(s.geom, 0.002)
  AND ST_DWithin(w.geom::geography, s.geom::geography, 60)
  AND EXISTS (SELECT 1 FROM stations twin
              WHERE twin.mode = s.mode AND twin.station_id <> s.station_id
                AND twin.line_name = s.line_name
                AND search_fold(twin.name) = search_fold(s.name)
                AND ST_DWithin(twin.geom::geography, s.geom::geography, 10000));

-- A station named as its lift ("Voss Gondol"), on a lift whose other end has no station
-- mapped and so gets one (lift ends): marked as its end too, so that the two read alike.
UPDATE stations s SET lift_end = CASE
        WHEN ST_Distance(s.geom, ST_StartPoint(w.geom)) <= ST_Distance(s.geom, ST_EndPoint(w.geom))
        THEN 'lower' ELSE 'upper' END
FROM line_ways w
WHERE s.mode = 'aerialway' AND s.lift_end IS NULL
  AND w.kind = 'aerialway' AND w.name = s.line_name
  AND search_fold(s.name) = search_fold(s.line_name)
  AND w.geom && ST_Expand(s.geom, 0.002)
  AND ST_DWithin(w.geom::geography, s.geom::geography, 60)
  AND EXISTS (SELECT 1 FROM stations added
              WHERE added.mode = 'aerialway' AND added.osm_type = 'W'
                AND added.osm_id = w.way_id AND added.lift_end IS NOT NULL);

-- A lift's or funicular's station on its line: OSM puts it in its building, off the cable
-- (Voss Gondol, 30m away), where a router cannot find the lift. Moved to the nearest point
-- of its line.
UPDATE stations s SET geom = ST_ClosestPoint(w.geom, s.geom)
FROM line_ways w
WHERE s.mode IN ('aerialway', 'funicular')
  AND w.kind = s.mode AND w.name = s.line_name
  AND w.geom && ST_Expand(s.geom, 0.002)
  AND ST_DWithin(w.geom::geography, s.geom::geography, 60);


-- The ski area an aerialway or funicular station is in (Val Thorens), which its lifts go by
-- more than any one of them. One per lift, so that both its ends say the same: the smallest
-- named area containing the middle of the station's line. A station on no known line: the
-- smallest area within 100m of it.
UPDATE stations s SET ski_area = a.name
FROM (
    SELECT DISTINCT ON (st.station_id) st.station_id, ski.name
    FROM stations st
    JOIN line_ways w
      ON w.kind = st.mode AND w.name = st.line_name
     AND w.geom && ST_Expand(st.geom, 0.002)
     AND ST_DWithin(w.geom::geography, st.geom::geography, 60)
    JOIN ski_areas ski ON ST_Contains(ski.geom, ST_LineInterpolatePoint(w.geom, 0.5))
    WHERE st.mode IN ('aerialway', 'funicular')
    ORDER BY st.station_id, ST_Area(ski.geom)
) a
WHERE s.station_id = a.station_id;

UPDATE stations s SET ski_area = a.name
FROM (
    SELECT DISTINCT ON (st.station_id) st.station_id, ski.name
    FROM stations st
    JOIN ski_areas ski
      ON ski.geom && ST_Expand(st.geom, 0.003)
     AND ST_DWithin(ski.geom::geography, st.geom::geography, 100)
    WHERE st.mode IN ('aerialway', 'funicular') AND st.line_name IS NULL
    ORDER BY st.station_id, ST_Area(ski.geom)
) a
WHERE s.station_id = a.station_id;


-- @step latin names
-- @python latin_names


-- @step place names
-- Whether a station's name needs its city to make sense: "Gare" in Royan is "Royan - Gare";
-- not when the name is the only one of its kind (below), nor when the name (or its Latin form)
-- already says where it is, in any language and at any level from municipality to region:
-- Brussels-Luxembourg sits in Ixelles, but says Brussels. A boundary's names count whole,
-- split where bilingual ("Ixelles - Elsene"), and without generic words, so that "Région de
-- Bruxelles-Capitale" says "bruxelles". "臺北" is the start of "臺北市".
CREATE UNLOGGED TABLE boundary_names AS
SELECT DISTINCT relation_id, name
FROM (
    SELECT b.relation_id, search_fold(trim(part)) AS full_name,
           trim(regexp_replace(regexp_replace(search_fold(trim(part)),
               '\m(region|regione|capital|capitale|hoofdstedelijk|gewest|district|city|'
               'ville|of|de|du|des|la|le|the|metropolitan|greater|gemeinde|stadt|kreis|landkreis|'
               'oblast|raion|rayon|okrug|province|provincia|prefecture|municipality|municipio|'
               'commune|county|kommune|fylke)\M', '', 'g'), '\s+', ' ', 'g')) AS bare_name
    FROM boundaries b
    LEFT JOIN city_overrides co USING (relation_id),
         jsonb_each_text(b.tags || jsonb_strip_nulls(jsonb_build_object(
             'override', co.name, 'override:en', co.name_en))) AS t(k, v),
         regexp_split_to_table(t.v, '\s+-\s+|\s*/\s*|;') AS part
    WHERE (b.admin_level BETWEEN 4 AND 8 OR co.relation_id IS NOT NULL)
      AND (t.k = 'name' OR t.k ~ '^name:[a-z]{2,3}$' OR t.k LIKE 'override%'
           OR t.k IN ('int_name', 'alt_name', 'official_name', 'short_name'))
) n,
-- "臺北市" without its last character is "臺北": a single non-Latin word less its suffix.
LATERAL (VALUES (full_name), (bare_name),
                (CASE WHEN full_name !~ '[ a-z]' AND length(full_name) >= 3
                      THEN left(full_name, -1) END)) AS v(name)
WHERE length(name) >= 2;
CREATE INDEX ON boundary_names (relation_id, name);
ANALYZE boundary_names;

-- Every run of up to five consecutive words of the given names: what a boundary name, itself
-- up to a few words, is compared to, as an exact match.
-- A name folded as search_fold, but with an apostrophe a word break: "Cœur d'Orly" is
-- "coeur d orly", in which Orly's name is a word. search_fold drops them, for "oconnell" to
-- find O'Connell, which would hide the place in every French elision ("coeur dorly").
CREATE OR REPLACE FUNCTION public.elision_fold(text) RETURNS text AS $$
    SELECT trim(regexp_replace(public.fold($1), '[^[:alnum:]]+', ' ', 'g'))
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION public.word_runs(VARIADIC names text[]) RETURNS SETOF text AS $$
    SELECT array_to_string(w[i:j], ' ')
    FROM unnest(names) AS t(name),
         regexp_split_to_array(t.name, ' ') AS w,
         generate_series(1, array_length(w, 1)) AS i,
         generate_series(i, least(i + 4, array_length(w, 1))) AS j
    WHERE t.name <> ''
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Every run of every station against the names of its boundaries, as one join: computed
-- first, as joining a function per station makes a lookup per station.
CREATE UNLOGGED TABLE station_runs AS
SELECT st.station_id, bid, run
FROM stations st,
     unnest(st.boundary_ids) AS bid,
     word_runs(search_fold(st.name), search_fold(st.latin), elision_fold(st.name)) AS run
WHERE st.city IS NOT NULL OR st.settlement IS NOT NULL;
ANALYZE station_runs;

UPDATE stations SET needs_place = city IS NOT NULL OR settlement IS NOT NULL;
UPDATE stations s SET needs_place = false
FROM (
    SELECT DISTINCT sr.station_id
    FROM station_runs sr
    JOIN boundary_names bn ON bn.relation_id = sr.bid AND bn.name = sr.run
) said
WHERE s.station_id = said.station_id;
DROP TABLE station_runs;

-- Nor where the name is that of a town, village or hamlet near it: "Åndalsnes" at Åndalsnes,
-- a stop named after its hamlet even where another village is nearer and so its settlement.
-- Found into a table first, on all cores.
CREATE UNLOGGED TABLE named_after_places AS
SELECT s.station_id
FROM stations s
WHERE s.needs_place
  AND EXISTS (
      SELECT 1
      FROM places pl, word_runs(search_fold(s.name), search_fold(s.latin), elision_fold(s.name)) AS run
      WHERE pl.geom && ST_Expand(s.geom, 0.06)
        AND ST_DWithin(pl.geom::geography, s.geom::geography, 3000)
        AND run IN (search_fold(pl.tags ->> 'name'), search_fold(pl.tags ->> 'name:en')));
UPDATE stations s SET needs_place = false
FROM named_after_places n
WHERE s.station_id = n.station_id;
DROP TABLE named_after_places;

-- And for a train station, ferry terminal or funicular, only where the name alone is
-- ambiguous: another of the mode in the country has it. A name of its own needs no place,
-- however large the municipality it falls in: Myrdal, not "Aurland - Myrdal"; Frekhaug kai,
-- not "Alver - Frekhaug kai". Bus, tram and metro stops are local, their names said within a
-- town ("Mairie", "Château"), and so are aerialway stations ("Bergstation"): they keep it.
UPDATE stations s SET needs_place = false
FROM (
    SELECT station_id
    FROM (SELECT station_id,
                 count(*) OVER (PARTITION BY mode, country, search_fold(name)) AS same_name
          FROM stations) named
    WHERE same_name = 1
) unique_name
WHERE s.station_id = unique_name.station_id AND s.needs_place
  AND s.mode IN ('train', 'ferry', 'funicular');


-- @step search names
-- Every spelling to search on, one partition per mode so that a search reads its mode's
-- names only: bus stops are nine stations in ten. Each name is also prefixed with its city
-- ("Paris Gare de Lyon"), marked as such since it matches every station of the city, and with
-- the place it starts with (folded), which a search must name whole to list the place's
-- stations: "bergen" lists Bergen's, "central" not Central Bedfordshire's.
CREATE TABLE station_names (
    station_id    integer NOT NULL,
    mode          text NOT NULL,
    name          text NOT NULL,
    city_prefixed boolean NOT NULL,
    place         text,
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

-- A lift's or funicular's line or ski area with each of its names: "fløibanen" finds Fløyen,
-- "val thorens" its lifts.
INSERT INTO station_names (station_id, mode, name, city_prefixed)
SELECT DISTINCT n.station_id, n.mode, p.prefix || ' ' || n.name, false
FROM station_names n
JOIN stations s USING (station_id)
CROSS JOIN LATERAL (VALUES (s.line_name), (s.ski_area)) AS p(prefix)
WHERE p.prefix IS NOT NULL AND NOT n.city_prefixed
  AND n.folded NOT LIKE '%' || search_fold(p.prefix) || '%';

-- The names of the other stops gathered into a station too: "agen gare sncf" finds the bus
-- station whose stop that is.
INSERT INTO station_names (station_id, mode, name, city_prefixed)
SELECT DISTINCT st.station_id, st.mode, without_quay(o.tags ->> 'name'), false
FROM stations st
JOIN station_objects o ON o.mode = st.mode AND o.key = st.key
WHERE o.is_primary AND o.tags ? 'name' AND NOT is_quay_code(o.tags ->> 'name')
  AND NOT EXISTS (SELECT 1 FROM station_names n
                  WHERE n.mode = st.mode AND n.station_id = st.station_id
                    AND n.name = without_quay(o.tags ->> 'name'));

-- Both ways round, as people type either: "villeneuve bordeneuve", "bordeneuve villeneuve".
INSERT INTO station_names (station_id, mode, name, city_prefixed, place)
SELECT DISTINCT n.station_id, n.mode, v.name, true, v.place
FROM station_names n
JOIN stations s USING (station_id)
CROSS JOIN LATERAL (VALUES (s.city ->> 'name'), (s.city ->> 'name:en'),
                           (s.settlement ->> 'name'), (s.settlement ->> 'name:en')) AS c(city)
CROSS JOIN LATERAL (VALUES (c.city || ' ' || n.name, search_fold(c.city)),
                           (n.name || ' ' || c.city, NULL)) AS v(name, place)
WHERE c.city IS NOT NULL AND n.folded NOT LIKE '%' || search_fold(c.city) || '%';

CREATE INDEX ON station_names USING gin (folded gin_trgm_ops);
CREATE INDEX ON station_names (folded text_pattern_ops);
CREATE INDEX ON station_names (station_id);

-- @step analyze
ANALYZE;
