-- osm2pgsql flex style: raw stops, stop_area and route relations, and admin boundaries.
-- build.sql turns these into stations.

local stops = osm2pgsql.define_table({
    name = 'stops',
    ids = { type = 'any', type_column = 'osm_type', id_column = 'osm_id' },
    columns = {
        { column = 'tags', type = 'jsonb' },
        { column = 'geom', type = 'point', projection = 4326, not_null = true },
    },
})

-- Named lifts and funiculars: their stations are known by the line (Fløibanen's Fløyen).
local line_ways = osm2pgsql.define_way_table('line_ways', {
    { column = 'kind', type = 'text', not_null = true },
    { column = 'name', type = 'text', not_null = true },
    { column = 'geom', type = 'linestring', projection = 4326, not_null = true },
})

-- Named ski areas: their lifts' stations are known by the area (Val Thorens).
local ski_areas = osm2pgsql.define_table({
    name = 'ski_areas',
    ids = { type = 'any', type_column = 'osm_type', id_column = 'osm_id' },
    columns = {
        { column = 'name', type = 'text', not_null = true },
        { column = 'geom', type = 'multipolygon', projection = 4326, not_null = true },
    },
})

-- Towns, villages and hamlets: where a station is, as people say it (Åndalsnes, not Rauma).
local places = osm2pgsql.define_node_table('places', {
    { column = 'place', type = 'text', not_null = true },
    { column = 'tags', type = 'jsonb' },
    { column = 'geom', type = 'point', projection = 4326, not_null = true },
})

local SETTLEMENTS = { city = true, town = true, village = true, hamlet = true }

local rels = osm2pgsql.define_relation_table('rels', {
    { column = 'tags', type = 'jsonb' },
    { column = 'members', type = 'jsonb' },
})

local boundaries = osm2pgsql.define_relation_table('boundaries', {
    { column = 'admin_level', type = 'int' },
    { column = 'tags', type = 'jsonb' },
    { column = 'geom', type = 'multipolygon', projection = 4326, not_null = true },
})

local function is_stop(tags)
    local railway = tags.railway
    return railway == 'station' or railway == 'halt' or railway == 'tram_stop'
        or tags.public_transport ~= nil
        or tags.highway == 'bus_stop'
        or tags.amenity == 'bus_station' or tags.amenity == 'ferry_terminal'
        or tags.aerialway == 'station'
end

function osm2pgsql.process_node(object)
    if is_stop(object.tags) then
        stops:insert({ tags = object.tags, geom = object:as_point() })
    end
    if SETTLEMENTS[object.tags.place] and object.tags.name then
        places:insert({ place = object.tags.place, tags = object.tags, geom = object:as_point() })
    end
end

function osm2pgsql.process_way(object)
    local tags = object.tags
    if is_stop(tags) then
        stops:insert({ tags = tags, geom = object:as_linestring():centroid() })
    end
    local lift = tags.aerialway and tags.aerialway ~= 'station' and tags.aerialway ~= 'pylon'
        and tags.aerialway ~= 'goods'
    if tags.name and (lift or tags.railway == 'funicular') then
        line_ways:insert({ kind = lift and 'aerialway' or 'funicular', name = tags.name,
                           geom = object:as_linestring() })
    end
    if tags.landuse == 'winter_sports' and tags.name and object.is_closed then
        ski_areas:insert({ name = tags.name, geom = object:as_polygon() })
    end
end

function osm2pgsql.process_relation(object)
    local tags = object.tags
    if tags.landuse == 'winter_sports' and tags.name and tags.type == 'multipolygon' then
        ski_areas:insert({ name = tags.name, geom = object:as_multipolygon() })
        return
    end
    local level = tonumber(tags.admin_level)
    if tags.boundary == 'administrative' then
        if level == 2 or (level and level >= 4 and level <= 8) then
            boundaries:insert({ admin_level = level, tags = tags, geom = object:as_multipolygon() })
        end
        return
    end

    local stop_area = tags.public_transport == 'stop_area'
    if not stop_area and not tags.route then
        return
    end
    local members = {}
    for _, member in ipairs(object.members) do
        -- A route's only useful members are its stops; its ways are the whole track.
        if stop_area or member.type == 'n' then
            members[#members + 1] = { type = string.upper(member.type), ref = member.ref, role = member.role }
        end
    end
    if #members > 0 then
        rels:insert({ tags = tags, members = members })
    end
end
