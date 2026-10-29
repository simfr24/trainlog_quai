# quai: public transport stations from OpenStreetMap, served by a small API.
#
#   make all                                       download, filter, import, build and serve
#   make all REGIONS=europe/france/ile-de-france   the same for one small region
#   make build                                     rebuild the stations from the last import
#   make serve                                     (re)start the API
#   make usage USAGE=usage.csv                     load Trainlog's station usage (usage.py)
#
# REGIONS are Geofabrik extract paths; the default covers the world. Downloads are only
# refreshed when Geofabrik has a newer file, and filtering runs in parallel with -j.

REGIONS ?= africa asia australia-oceania central-america europe north-america south-america
FILTERED := $(foreach region,$(REGIONS),filtered/$(region).osm.pbf)

# Postgres's parallel workers, one per core, and the background processes and connections
# that allows (docker-compose.yml): the build runs a connection per core at once.
export QUAI_CORES ?= $(shell nproc)
export QUAI_WORKERS ?= $(shell echo $$(($(QUAI_CORES) + 8)))
export QUAI_CONNECTIONS ?= $(shell echo $$((2 * $(QUAI_CORES) + 100)))

all:
	$(MAKE) import
	$(MAKE) serve

# Fetching and filtering the extracts is regions.py's: every region at once, a line each,
# filtering as many as -j allows. An extract is only downloaded again when Geofabrik has a
# newer one, and an interrupted download resumes.
download:
	python3 regions.py --download-only $(REGIONS)

# Always merged afresh: the regions may have changed since the last run. Regions overlap
# (Russia, Turkey, the Caucasus...) and Geofabrik cuts each on its own day, so an object
# edited in between is in two versions, which merge both keeps and osm2pgsql refuses:
# time-filter keeps each object's latest.
filtered.osm.pbf: stations.params
	python3 regions.py $(REGIONS)
	osmium merge $(FILTERED) -f pbf -o $@.merged.tmp --overwrite
	osmium time-filter -F pbf $@.merged.tmp -f pbf -o $@.tmp --overwrite && rm $@.merged.tmp && mv $@.tmp $@

# Trainlog's country shapes, which the build gives each station its country from.
countries.geojson:
	curl -fsSL -o $@.tmp https://trainlog.me/static/data/countries-filtered.geojson && mv $@.tmp $@

import: filtered.osm.pbf countries.geojson
	docker compose run --rm --build import

build: countries.geojson
	docker compose run --rm --build import python3 /data/build.py

serve:
	docker compose up -d --build db api

USAGE ?= usage.csv
usage:
	docker compose run --rm --build import python3 /data/usage.py /data/$(USAGE)

.PHONY: all download filtered.osm.pbf import build serve usage
