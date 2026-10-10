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

# Kept between runs: re-downloading the world every time is what -N exists to avoid.
.PRECIOUS: downloads/%-latest.osm.pbf filtered/%.osm.pbf

all: download
	$(MAKE) import
	$(MAKE) serve

# Fetches an extract if Geofabrik has a newer one, and keeps it only if it matches its
# checksum. An interrupted download stays behind as a truncated file that -N considers
# current, so a mismatch is downloaded again once before giving up. A progress bar alone,
# else a line per file: with -j, the jobs' bars and lines would overwrite each other.
WGET_PROGRESS = $(if $(filter-out -j1,$(filter -j%,$(MAKEFLAGS))),-nv,-q --show-progress --progress=bar:force:noscroll)
define fetch
( mkdir -p downloads/$(dir $(1)) && cd downloads/$(dir $(1)) \
	&& wget -N $(WGET_PROGRESS) \
		https://download.geofabrik.de/$(1)-latest.osm.pbf \
		https://download.geofabrik.de/$(1)-latest.osm.pbf.md5 \
	&& { md5sum -c --quiet $(notdir $(1))-latest.osm.pbf.md5 \
		|| { rm -f $(notdir $(1))-latest.osm.pbf \
			&& wget $(WGET_PROGRESS) \
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
