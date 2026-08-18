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
              src/boostrap.sh \
              src/profile.sh  \
              src/sqlite.sh   \
              src/jq.sh       \
              src/graph.sh    \
              src/prov.sh     \
              src/db.sh       \
              src/spack.sh    \
              src/metadata.sh \
              src/sched.sh    \
              src/sched_local.sh \
              src/sched_none.sh \
              src/sched_slurm.sh \
              src/sched_pbs.sh \
              src/sched_flux.sh \
              src/launch.sh   \
              src/launch_none.sh \
              src/launch_openmpi.sh \
              src/launch_mpich.sh \
              src/launch_slurm.sh \
              src/launch_pbs.sh \
              src/launch_pals.sh \
              src/setup.sh    \
              src/resource.sh \
              src/job.sh      \
              src/job_cli.sh  \
              src/app.sh      \
              src/describe.sh \
              src/ai.sh       \
              src/query.sh    \
              src/main.sh

KNIT_OUTPUT = knit.sh

all: knit.sh

knit.sh: $(KNIT_SOURCE)
	@echo "Concatenating files into $(KNIT_OUTPUT)..."
	@cat $(KNIT_SOURCE) > $(KNIT_OUTPUT)
# Optional version stamp: `make VERSION=1.2.3` rewrites the KNIT_VERSION line in
# the generated knit.sh. With no VERSION (dev builds, CI, tests) the placeholder
# committed in src/main.sh is kept. The release workflow passes the git tag here.
ifneq ($(VERSION),)
	@sed -i 's|^declare -gxr KNIT_VERSION=.*|declare -gxr KNIT_VERSION=$(VERSION)|' $(KNIT_OUTPUT)
	@echo "Stamped KNIT_VERSION=$(VERSION)"
endif
	@echo "Done. Created $(KNIT_OUTPUT)"

KNIT_TESTS := $(wildcard tests/test_*.sh)

# Live AI tests live under tests/ai/ and are excluded from KNIT_TESTS above
# (that glob is non-recursive). They talk to a real LLM served by Ollama, so
# they are kept out of `make check` and run on demand via `make check-ai`.
KNIT_AI_TESTS := $(wildcard tests/ai/test_*.sh)

.PHONY: check check-unit check-integration build-images
check: check-unit check-integration

# Number of parallel bats jobs: honour NPROC if set, otherwise fall back to the
# number of processing units reported by nproc.
BATS_JOBS := $(if $(NPROC),$(NPROC),$(shell nproc))

# The unit tests are themselves run in parallel (bats -j), so this target must
# not be split across sub-makes.
.NOTPARALLEL: check-unit

check-unit: $(KNIT_TESTS) knit.sh
	@echo "Running unit tests with $(BATS_JOBS) parallel jobs..."
	bats -j $(BATS_JOBS) $(KNIT_TESTS)
	@echo "Unit tests completed."

check-integration: knit.sh
	@echo "Running integration tests..."
	$(MAKE) -C tests/integration check-all
	@echo "Integration tests completed."

build-images:
	$(MAKE) -C tests/integration build-images

# Live AI tests against a real LLM (Ollama). Opt-in and standalone: not part of
# `make check`. Start Ollama and pull the model first, then:
#   export KNIT_AI_LIVE=1 OLLAMA_API_KEY=ollama
#   make check-ai
# Without KNIT_AI_LIVE=1 or a reachable server, every test skips cleanly.
.PHONY: check-ai
check-ai: knit.sh
	@echo "Running live AI tests..."
	bats $(KNIT_AI_TESTS)
	@echo "Live AI tests completed."

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
coverage: $(KNIT_SOURCE)
	@{ \
		echo '__knit_cov_dir="$$(cd "$$(dirname "$${BASH_SOURCE[0]}")" && pwd)"'; \
		for f in $(KNIT_SOURCE); do echo "source \"\$$__knit_cov_dir/$$f\""; done; \
	} > $(KNIT_OUTPUT)

DOCS_VENV := docs/.venv

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
	@echo "Generating Stitch Guide pages..."
	python3 maint/gen-stitch-guide.py
	@echo "Building Sphinx documentation..."
	$(DOCS_VENV)/bin/sphinx-build -b html docs/source docs/build/html
	@echo "Done. Open docs/build/html/index.html"

# Exercise every documentation code example (docs/source/_code/*.sh) end to end
# on the local backend and validate that all literalinclude regions referenced
# by the Sphinx sources resolve. Kept separate from check-unit: it runs shipped
# example experiments, not the bats suite.
.PHONY: check-docs
check-docs: knit.sh
	@bash maint/check-docs.sh

# Assemble the full public website into web/build/site: the landing page at the
# site root and the Sphinx documentation under docs/. This is what gets deployed
# to knit.sh; open web/build/site/index.html to preview it exactly as served.
.PHONY: web
web: docs
	@echo "Assembling website into web/build/site..."
	rm -rf web/build/site
	mkdir -p web/build/site
	# Copy every top-level entry of web/ except the build directory, following
	# symlinks (-L) so the logo symlink becomes a real file in the artifact.
	find web -mindepth 1 -maxdepth 1 ! -name build ! -name README.md \
		-exec cp -rL {} web/build/site/ \;
	# Overwrite the copied index.html with one whose code snippets are extracted
	# from the tested doc samples and highlighted in the brand palette. Uses the
	# docs venv (built by the `docs` prerequisite) since it ships Pygments.
	$(DOCS_VENV)/bin/python maint/build-landing.py
	# The Sphinx documentation is served under /docs.
	mkdir -p web/build/site/docs
	cp -r docs/build/html/. web/build/site/docs/
	@echo "Done. Open web/build/site/index.html"

.PHONY: docs-clean
docs-clean:
	@echo "Cleaning documentation..."
	rm -rf docs/build docs/doxygen web/build
	@echo "Done."

.PHONY: clean
clean:
	@echo "Cleaning up..."
	rm -f $(KNIT_OUTPUT)
	@echo "Done."
