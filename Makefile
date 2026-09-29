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

# Fetches an extract if Geofabrik has a newer one, and keeps it only if it matches its
# checksum. An interrupted download stays behind as a truncated file that -N considers
# current, so a mismatch is downloaded again once before giving up.
define fetch
( mkdir -p downloads/$(dir $(1)) && cd downloads/$(dir $(1)) \
	&& wget -N -q --show-progress --progress=bar:force:noscroll \
		https://download.geofabrik.de/$(1)-latest.osm.pbf \
		https://download.geofabrik.de/$(1)-latest.osm.pbf.md5 \
	&& { md5sum -c --quiet $(notdir $(1))-latest.osm.pbf.md5 \
		|| { rm -f $(notdir $(1))-latest.osm.pbf \
			&& wget -q --show-progress --progress=bar:force:noscroll \
				https://download.geofabrik.de/$(1)-latest.osm.pbf \
			&& md5sum -c --quiet $(notdir $(1))-latest.osm.pbf.md5; }; } )
endef

download:
	@$(foreach region,$(REGIONS),$(call fetch,$(region)) &&) true

downloads/%-latest.osm.pbf:
	@$(call fetch,$*)

# Written under a temporary name and renamed once complete, so an interrupted or failed
# filter never leaves a file that make would take for a finished one. One line when each
# finishes: with -j, progress bars would overwrite each other.
filtered/%.osm.pbf: downloads/%-latest.osm.pbf stations.params
	@mkdir -p $(dir $@)
	@echo "filtering $*..."
	@start=$$(date +%s); \
		osmium tags-filter --no-progress --expressions=stations.params $< -f pbf -o $@.tmp --overwrite \
		&& mv $@.tmp $@ \
		&& echo "filtered $* in $$(( $$(date +%s) - start ))s, $$(du -h $@ | cut -f1)"

# Always merged afresh: the regions may have changed since the last run.
filtered.osm.pbf: $(FILTERED)
	osmium merge $^ -f pbf -o $@.tmp --overwrite && mv $@.tmp $@

import: filtered.osm.pbf
	docker compose run --rm --build import

build:
	docker compose run --rm --build import python3 /data/build.py --reuse

serve:
	docker compose up -d --build api

.PHONY: all download filtered.osm.pbf import build serve
