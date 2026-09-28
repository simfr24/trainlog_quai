# quai: a filtered OSM extract loaded into PostGIS and served by a small API.
# PBF defaults to a small regional extract; point it at a larger file for a real build.
PBF ?= ile-de-france-latest.osm.pbf
PBF_URL ?= https://download.geofabrik.de/europe/france/ile-de-france-latest.osm.pbf

$(PBF):
	wget -N -q --show-progress $(PBF_URL)

filtered.osm.pbf: $(PBF) stations.params
	osmium tags-filter --expressions=stations.params $(PBF) -o $@ --overwrite

import: filtered.osm.pbf
	docker compose run --rm --build import

# Rebuild the stations from the already imported raw tables, after a build.sql change.
build:
	docker compose run --rm --build import python3 /data/build.py

serve:
	docker compose up -d --build api

.PHONY: import build serve
