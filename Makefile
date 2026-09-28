# quai: public transport stations from OpenStreetMap, served by a small API.
#
#   make all                                       download, filter, import, build and serve
#   make all REGIONS=europe/france/ile-de-france   the same for one small region
#   make build                                     rebuild the stations from the last import
#   make serve                                     (re)start the API
#
# REGIONS are Geofabrik extract paths; the default covers the world. Downloads are only
# refreshed when Geofabrik has a newer file, and filtering runs in parallel with -j.

REGIONS ?= africa asia australia-oceania central-america europe north-america south-america
FILTERED := $(foreach region,$(REGIONS),filtered/$(region).osm.pbf)

# Kept between runs: re-downloading the world every time is what -N exists to avoid.
.PRECIOUS: downloads/%-latest.osm.pbf filtered/%.osm.pbf

all: download
	$(MAKE) import
	$(MAKE) serve

# Refreshes every extract Geofabrik has updated; missing ones are fetched by the rule below.
download:
	@for region in $(REGIONS); do \
		mkdir -p downloads/$$(dirname $$region); \
		wget -N -q --show-progress -P downloads/$$(dirname $$region) \
			https://download.geofabrik.de/$$region-latest.osm.pbf || exit 1; \
	done

downloads/%-latest.osm.pbf:
	@mkdir -p $(dir $@)
	wget -N -q --show-progress -P $(dir $@) https://download.geofabrik.de/$*-latest.osm.pbf

filtered/%.osm.pbf: downloads/%-latest.osm.pbf stations.params
	@mkdir -p $(dir $@)
	osmium tags-filter --expressions=stations.params $< -o $@ --overwrite

# Always merged afresh: the regions may have changed since the last run.
filtered.osm.pbf: $(FILTERED)
	osmium merge $^ -o $@ --overwrite

import: filtered.osm.pbf
	docker compose run --rm --build import

build:
	docker compose run --rm --build import python3 /data/build.py --reuse

serve:
	docker compose up -d --build api

.PHONY: all download filtered.osm.pbf import build serve
