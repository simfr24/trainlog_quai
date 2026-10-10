# quai

Public transport stations from OpenStreetMap: every stop in a filtered extract, grouped
into one station per mode, with its names in every language, its place and its lines.

    make -j4 all                                      # the world: download, filter, import, build, serve
    make all REGIONS=europe/france/ile-de-france      # one region, for trying things out
    make build                                        # rebuild from the last import
    make serve                                        # (re)start the API on http://localhost:5020

`REGIONS` are Geofabrik extract paths. Running `make all` again refreshes whatever Geofabrik
has updated. The import (osm2pgsql) loads the raw tables into Postgres's `raw` schema, which
stays between builds. The build runs in DuckDB, on every core, and publishes what the API
reads to the `live_build` schema, swapped in for `live` once complete, so the API
keeps answering from the previous build meanwhile.

Postgres serves, and builds the published tables' indexes, a connection each at once: it is
allowed a parallel worker per core (`QUAI_CORES`, the machine's count unless set), which
`make serve` applies, restarting the database when it changed; started by `docker compose`
alone, it gets 8.

Endpoints:

    /search?q=gare de lyon&mode=metro&lat=&lon=&limit=&lang=
    /station/train/Q800588?objects=1                      (a stored station_key, following redirects;
                                                          objects=1 adds osm_objects, its OSM objects with tags)
    /reverse?lat=48.84&lon=2.37&mode=metro&radius=1      (radius in km)
    /object/N/27371862                                    (stations containing an OSM object)
    /line?from=N27371862&to=N1234&mode=train&service=6033 (lines and services between two stations)
    POST /snap {mode, points: [{lat, lng}]}                (points moved onto the nearest stop position of the mode)

Every station has a `station_key`, unique within its mode and meant to be stored: its wikidata
item, else `UIC<uic_ref>`, else its representative OSM object (`N123`). When a rebuild loses a
key, `key_redirects` sends it to the station that took over most of its objects.

Each result has a `label`: the station's `name:<lang>` when `lang` is given and mapped, else
its own `name` where the reader's script is its script (北京南 for `zh` and `ja`), else
`latin`, its international Latin-script name (`int_name`, a Latin `name`, a mapped
romanisation, a BGN/PCGN transliteration or Pinyin; see latin.py). Its `city` and
`settlement` have a `label` chosen alike, and its `region` is given as its label. `matched` is the spelling the
query matched, which may be in another language than the label. `needs_place` says the name
does not tell where the station is ("Gare", "Gare de Lyon"), so that a client can prefix its
`city` ("Royan - Gare"); it is false where any name of an enclosing boundary is in it already.

Rail stations (train, metro, tram, funicular) carry their `tracks`, `[{ref, lat, lng, on_track}]`:
where a vehicle calling at that track stops. `on_track` is false where only a platform between
two tracks gives it.
