SLURM_COMPOSE = docker/slurm/docker-compose.yml
PBS_COMPOSE   = docker/pbs/docker-compose.yml

# Relative path from inside the container to this directory.
INTEGRATION_DIR = /shared/knit/tests/integration

# All test drivers, sorted so they run in order.
EXPERIMENTS := $(sort $(wildcard experiments/*/test.sh))

.PHONY: check-slurm check-pbs check-all build-images
.PHONY: cluster-up-slurm cluster-down-slurm
.PHONY: cluster-up-pbs cluster-down-pbs
.PHONY: run-slurm run-pbs

# ---------------------------------------------------------------------------
# Image build (separated so CI can cache/pre-build before the test step)
# ---------------------------------------------------------------------------

build-images:
	docker compose -f $(SLURM_COMPOSE) build
	docker compose -f $(PBS_COMPOSE) build

# ---------------------------------------------------------------------------
# Full cycles
# ---------------------------------------------------------------------------

check-slurm: cluster-up-slurm run-slurm cluster-down-slurm

check-pbs: cluster-up-pbs run-pbs cluster-down-pbs

check-all: check-slurm check-pbs

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

# ---------------------------------------------------------------------------
# Run experiments
# ---------------------------------------------------------------------------

run-slurm:
	@failed=0; \
	for t in $(EXPERIMENTS); do \
	    printf '\n=== %s (slurm) ===\n' "$$t"; \
	    docker exec --user hpcuser slurm-login \
	        bash $(INTEGRATION_DIR)/$$t \
	    || { printf 'FAIL: %s\n' "$$t"; failed=1; }; \
	done; \
	exit $$failed

run-pbs:
	@failed=0; \
	for t in $(EXPERIMENTS); do \
	    printf '\n=== %s (pbs) ===\n' "$$t"; \
	    docker exec --user hpcuser pbs-login \
	        bash $(INTEGRATION_DIR)/$$t \
	    || { printf 'FAIL: %s\n' "$$t"; failed=1; }; \
	done; \
	exit $$failed
