KNIT_SOURCE = src/global.sh   \
              src/log.sh      \
              src/set.sh      \
              src/str.sh      \
              src/types.sh    \
              src/pushd.sh    \
              src/detect.sh   \
              src/local.sh    \
              src/cli.sh      \
              src/frame.sh    \
              src/profile.sh  \
              src/boostrap.sh \
              src/spack.sh    \
              src/sqlite.sh   \
              src/jq.sh       \
              src/db.sh       \
              src/metadata.sh \
              src/sched.sh    \
              src/sched_local.sh \
              src/setup.sh    \
              src/job.sh      \
              src/main.sh

KNIT_OUTPUT = knit.sh

PROFILE_JSONS := $(shell find src/profiles -name '*.json' | sort)

all: knit.sh

knit.sh: $(KNIT_SOURCE) $(PROFILE_JSONS)
	@echo "Concatenating files into $(KNIT_OUTPUT)..."
	@tmp=$$(mktemp); \
	echo 'declare -gA _KNIT_PROFILE_JSON' > "$$tmp"; \
	for f in $(PROFILE_JSONS); do \
		name=$$(basename "$$f" .json); \
		printf '_KNIT_PROFILE_JSON["%s"]=%s\n' \
			"$$name" "'$$(jq -c . "$$f")'" >> "$$tmp"; \
	done; \
	cat "$$tmp" $(KNIT_SOURCE) > $(KNIT_OUTPUT); \
	rm -f "$$tmp"
	@echo "Done. Created $(KNIT_OUTPUT)"

KNIT_TESTS := $(wildcard tests/test_*.sh)

.PHONY: check check-unit check-integration build-images
check: check-unit check-integration

check-unit: $(KNIT_TESTS) knit.sh
	@echo "Running unit tests..."
	bats $(KNIT_TESTS)
	@echo "Unit tests completed."

check-integration: knit.sh
	@echo "Running integration tests..."
	$(MAKE) -C tests/integration check-all
	@echo "Integration tests completed."

build-images:
	$(MAKE) -C tests/integration build-images

.PHONY: shellcheck
shellcheck:
	shellcheck $(KNIT_SOURCE)

.PHONY: doccheck
doccheck:
	@status=0; \
	for f in src/*.sh; do \
		bash maint/doccheck.sh "$$f" || status=1; \
	done; \
	exit $$status

.PHONY: coverage
coverage: $(KNIT_SOURCE) $(PROFILE_JSONS)
	@tmp=$$(mktemp); \
	echo 'declare -gA _KNIT_PROFILE_JSON' > "$$tmp"; \
	for f in $(PROFILE_JSONS); do \
		name=$$(basename "$$f" .json); \
		printf '_KNIT_PROFILE_JSON["%s"]=%s\n' \
			"$$name" "'$$(jq -c . "$$f")'" >> "$$tmp"; \
	done; \
	{ cat "$$tmp"; for f in $(KNIT_SOURCE); do echo "source $$f"; done; } > $(KNIT_OUTPUT); \
	rm -f "$$tmp"

DOCS_VENV := .docs-venv

# Create the Python virtual environment for building the documentation and
# install the required packages into it. The stamp file tracks completion so the
# environment is only rebuilt when docs/requirements.txt changes.
.PHONY: docs-env
docs-env: $(DOCS_VENV)/.installed

$(DOCS_VENV)/.installed: docs/requirements.txt
	@echo "Creating documentation virtual environment in $(DOCS_VENV)..."
	python3 -m venv $(DOCS_VENV)
	$(DOCS_VENV)/bin/pip install -r docs/requirements.txt
	@touch $@
	@echo "Done."

.PHONY: docs
docs: docs-env
	@echo "Generating Doxygen XML..."
	doxygen Doxyfile
	@echo "Generating Public/Private API pages..."
	python3 maint/gen-doc-api.py
	@echo "Building Sphinx documentation..."
	$(DOCS_VENV)/bin/sphinx-build -b html docs/source docs/build/html
	@echo "Done. Open docs/build/html/index.html"

.PHONY: docs-clean
docs-clean:
	@echo "Cleaning documentation..."
	rm -rf docs/build docs/doxygen
	@echo "Done."

.PHONY: clean
clean:
	@echo "Cleaning up..."
	rm -f $(KNIT_OUTPUT)
	@echo "Done."
