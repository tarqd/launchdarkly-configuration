# Regenerate SDKCONF's JSON Schema and defaults document from the CUE source, then verify.
#
# sdkconf.cue and defaults.cue are the only files here meant to be edited by hand.
# sdkconf.schema.json and defaults.json are generated; CI runs `make check` to confirm they
# match the CUE source.

.PHONY: all gen vet vectors example check clean

all: gen vectors example

gen: vet
	python3 gen.py

vet:
	cue vet ./...

vectors:
	python3 run-vectors.py

example:
	python3 validate.py ../examples/launchdarkly.yaml

# Fails if the generated artifacts are stale relative to the CUE source.
check: vet
	@cp sdkconf.schema.json /tmp/sdkconf.schema.json.bak
	@cp defaults.json /tmp/defaults.json.bak
	@python3 gen.py >/dev/null
	@diff -q /tmp/sdkconf.schema.json.bak sdkconf.schema.json \
		|| { echo "sdkconf.schema.json is stale; run 'make gen'"; exit 1; }
	@diff -q /tmp/defaults.json.bak defaults.json \
		|| { echo "defaults.json is stale; run 'make gen'"; exit 1; }
	@echo "generated artifacts are up to date"
	@$(MAKE) --no-print-directory vectors example

clean:
	rm -f sdkconf.schema.json defaults.json
