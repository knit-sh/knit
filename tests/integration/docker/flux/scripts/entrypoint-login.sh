#!/bin/bash
# =============================================================================
# entrypoint-login.sh — runs on flux-login (broker rank 0 / leader + login node)
#
# Responsibilities:
#   1. Prepare shared filesystem directories
#   2. Prepare the broker rundir, owned by the instance user (hpcuser)
#   3. Start the leader broker as hpcuser; its initial program blocks so the
#      instance stays up and the compute brokers can attach
#
# The broker learns it is rank 0 from the position of this container's hostname
# (flux-login) in the bootstrap `hosts` list. Tests run here via
# `docker exec --user hpcuser flux-login`, connecting through FLUX_URI
# (local:///run/flux/local-0, set in docker-compose.yml).
# =============================================================================

set -e

echo "============================================================"
echo " Flux leader (rank 0) starting on $(hostname)"
echo "============================================================"

# -----------------------------------------------------------------------------
# 1. Shared directory layout
#    /shared is bind-mounted from the host (./shared in this cluster's dir).
# -----------------------------------------------------------------------------
# sshd lets the "laptop launcher" path (experiment 16) run OpenMPI's mpirun
# across nodes over SSH. It is not used by the broker overlay, which connects
# over its own CURVE-secured TCP tree.
echo "[entrypoint] Starting sshd..."
/usr/sbin/sshd || true

echo "[entrypoint] Setting up /shared directories..."
mkdir -p /shared/jobs /shared/home /shared/runs || true
# sticky-bit + world-writable so all users can create directories there
chmod 1777 /shared/jobs /shared/runs || true

# -----------------------------------------------------------------------------
# 2. Broker rundir
#    The instance runs as hpcuser, so hpcuser must own the rundir where the
#    broker creates its sockets (/run/flux/local-<rank>).
# -----------------------------------------------------------------------------
echo "[entrypoint] Preparing broker rundir..."
mkdir -p /run/flux
chown hpcuser:hpcuser /run/flux

# -----------------------------------------------------------------------------
# 3. Leader broker
#    Started as hpcuser via runuser (the entrypoint itself runs as root to set
#    up the dirs above). The initial program `sleep inf` runs only on rank 0
#    and keeps the instance alive for the lifetime of the container.
# -----------------------------------------------------------------------------
echo "[entrypoint] Starting leader broker..."
exec runuser -u hpcuser -- \
    flux broker \
        --config-path=/etc/flux/system/conf.d \
        -Srundir=/run/flux \
        sleep inf
