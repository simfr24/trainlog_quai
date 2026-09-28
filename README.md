# quai

Public transport stations from OpenStreetMap: every stop in a filtered extract, grouped
into one station per mode, with its names in every language, its place and its lines.

    make import     # download, filter and load (Île-de-France by default)
    make serve      # API on http://localhost:5020

    make import PBF=../trainlog_routing/world/europe-latest.osm.pbf    # a real build

Endpoints:

    /search?q=gare de lyon&mode=metro&lat=&lon=&limit=
    /reverse?lat=48.84&lon=2.37&mode=metro&radius=1      (radius in km)
    /object/N/27371862                                    (stations containing an OSM object)
    /line?from=N27371862&to=N1234&mode=train&ref=A        (lines between two stations, with their stops)
