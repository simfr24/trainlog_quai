# quai

Public transport stations from OpenStreetMap: every stop in a filtered extract, grouped
into one station per mode, with its names in every language, its place and its lines.

    make -j4 all                                      # the world: download, filter, import, build, serve
    make all REGIONS=europe/france/ile-de-france      # one region, for trying things out
    make build                                        # rebuild from the last import
    make serve                                        # (re)start the API on http://localhost:5020

`REGIONS` are Geofabrik extract paths. Running `make all` again refreshes whatever Geofabrik
has updated. Each build is made in the `build` schema and swapped in for `live` once
complete, so the API keeps answering from the previous build meanwhile.

Endpoints:

    /search?q=gare de lyon&mode=metro&lat=&lon=&limit=
    /reverse?lat=48.84&lon=2.37&mode=metro&radius=1      (radius in km)
    /object/N/27371862                                    (stations containing an OSM object)
    /line?from=N27371862&to=N1234&mode=train&service=6033 (lines and services between two stations)
