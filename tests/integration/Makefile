SLURM_COMPOSE = docker/slurm/docker-compose.yml
PBS_COMPOSE   = docker/pbs/docker-compose.yml
FLUX_COMPOSE  = docker/flux/docker-compose.yml

# Relative path from inside the container to this directory.
INTEGRATION_DIR = /shared/knit/tests/integration

# All test drivers, sorted so they run in order.
EXPERIMENTS := $(sort $(wildcard experiments/*/test.sh))

.PHONY: check-slurm check-pbs check-flux check-all build-images build-slurm build-pbs build-flux
.PHONY: cluster-up-slurm cluster-down-slurm
.PHONY: cluster-up-pbs cluster-down-pbs
.PHONY: cluster-up-flux cluster-down-flux
.PHONY: run-slurm run-pbs run-flux

# ---------------------------------------------------------------------------
# Image build (separated so CI can cache/pre-build before the test step)
#
# Per-cluster targets are the source of truth; build-images builds both. These
# only ever build locally — no target pushes to a registry (see lib/provision-
# image.sh and the publish workflow for the ghcr.io path).
# ---------------------------------------------------------------------------

build-slurm:
	docker compose -f $(SLURM_COMPOSE) build

build-pbs:
	docker compose -f $(PBS_COMPOSE) build

build-flux:
	docker compose -f $(FLUX_COMPOSE) build

build-images: build-slurm build-pbs build-flux

# ---------------------------------------------------------------------------
# Full cycles
# ---------------------------------------------------------------------------

check-slurm: cluster-up-slurm run-slurm cluster-down-slurm

check-pbs: cluster-up-pbs run-pbs cluster-down-pbs

check-flux: cluster-up-flux run-flux cluster-down-flux

check-all: check-slurm check-pbs check-flux

# ---------------------------------------------------------------------------
# Cluster lifecycle
# ---------------------------------------------------------------------------

cluster-up-slurm:
	docker compose -f $(SLURM_COMPOSE) up -d
	docker exec slurm-login \
	    bash $(INTEGRATION_DIR)/lib/wait-for-cluster.sh slurm

cluster-down-slurm:
	docker compose -f $(SLURM_COMPOSE) down -v

cluster-up-pbs:
	docker compose -f $(PBS_COMPOSE) up -d
	docker exec pbs-login \
	    bash $(INTEGRATION_DIR)/lib/wait-for-cluster.sh pbs

cluster-down-pbs:
	docker compose -f $(PBS_COMPOSE) down -v

cluster-up-flux:
	docker compose -f $(FLUX_COMPOSE) up -d
	# The Flux instance is owned by hpcuser (single-user instance), so the
	# readiness probe must run as hpcuser — root is an unauthorized guest.
	docker exec --user hpcuser flux-login \
	    bash $(INTEGRATION_DIR)/lib/wait-for-cluster.sh flux

cluster-down-flux:
	docker compose -f $(FLUX_COMPOSE) down -v

# ---------------------------------------------------------------------------
# Run experiments
# ---------------------------------------------------------------------------

# GITHUB_TOKEN, when set on the host, is forwarded into the container so knit's
# spack provisioning authenticates its api.github.com calls and does not hit the
# shared anonymous rate limit (60 requests/hour/address). "docker exec -e
# GITHUB_TOKEN" (no value) passes the variable through only when it is present,
# so a local run without a token behaves exactly as before.
run-slurm:
	@failed=0; \
	for t in $(EXPERIMENTS); do \
	    printf '\n=== %s (slurm) ===\n' "$$t"; \
	    docker exec -e GITHUB_TOKEN --user hpcuser slurm-login \
	        bash $(INTEGRATION_DIR)/$$t \
	    || { printf 'FAIL: %s\n' "$$t"; failed=1; }; \
	done; \
	exit $$failed

run-pbs:
	@failed=0; \
	for t in $(EXPERIMENTS); do \
	    printf '\n=== %s (pbs) ===\n' "$$t"; \
	    docker exec -e GITHUB_TOKEN --user hpcuser pbs-login \
	        bash $(INTEGRATION_DIR)/$$t \
	    || { printf 'FAIL: %s\n' "$$t"; failed=1; }; \
	done; \
	exit $$failed

run-flux:
	@failed=0; \
	for t in $(EXPERIMENTS); do \
	    printf '\n=== %s (flux) ===\n' "$$t"; \
	    docker exec -e GITHUB_TOKEN --user hpcuser flux-login \
	        bash $(INTEGRATION_DIR)/$$t \
	    || { printf 'FAIL: %s\n' "$$t"; failed=1; }; \
	done; \
	exit $$failed
