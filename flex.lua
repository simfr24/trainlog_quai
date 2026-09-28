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
        or railway == 'subway_entrance'
        or tags.public_transport ~= nil
        or tags.highway == 'bus_stop'
        or tags.amenity == 'bus_station' or tags.amenity == 'ferry_terminal'
        or tags.aerialway == 'station'
end

function osm2pgsql.process_node(object)
    if is_stop(object.tags) then
        stops:insert({ tags = object.tags, geom = object:as_point() })
    end
end

function osm2pgsql.process_way(object)
    if is_stop(object.tags) then
        stops:insert({ tags = object.tags, geom = object:as_linestring():centroid() })
    end
end

function osm2pgsql.process_relation(object)
    local tags = object.tags
    local level = tonumber(tags.admin_level)
    if tags.boundary == 'administrative' then
        if level == 2 or level == 4 or (level and level >= 6 and level <= 8) then
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
