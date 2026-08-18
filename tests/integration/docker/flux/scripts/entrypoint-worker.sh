#!/bin/bash
# =============================================================================
# entrypoint-worker.sh — runs on flux-compute1 and flux-compute2 (broker
# followers, rank 1+)
#
# Responsibilities:
#   1. Prepare the broker rundir, owned by the instance user (hpcuser)
#   2. Wait until the leader's overlay port (flux-login:8050) is reachable
#   3. Start the follower broker as hpcuser; it attaches to the leader's overlay
#
# A follower learns its rank from its hostname's position in the bootstrap
# `hosts` list and does not run an initial program. The same broker command line
# is used on every node; only rank 0 runs the initial program.
# =============================================================================

set -e

echo "============================================================"
echo " Flux worker starting on $(hostname)"
echo "============================================================"

# -----------------------------------------------------------------------------
# 1. Broker rundir (owned by the instance user)
# -----------------------------------------------------------------------------
echo "[entrypoint] Preparing broker rundir..."
mkdir -p /run/flux
chown hpcuser:hpcuser /run/flux

# sshd lets the "laptop launcher" path (experiment 16) run OpenMPI's mpirun
# across nodes over SSH. mpirun starts orted on this worker over SSH; the
# broker overlay itself does not use SSH.
echo "[entrypoint] Starting sshd..."
/usr/sbin/sshd || true

# -----------------------------------------------------------------------------
# 2. Wait for the leader's overlay port
#    Uses bash's built-in /dev/tcp so it does not depend on nc being present.
#    The loop tries every 2 seconds for up to ~5 minutes (150 attempts).
# -----------------------------------------------------------------------------
echo "[entrypoint] Waiting for flux-login:8050 to be reachable..."

MAX_ATTEMPTS=150
ATTEMPT=0

until bash -c "echo > /dev/tcp/flux-login/8050" 2>/dev/null; do
    ATTEMPT=$((ATTEMPT + 1))
    if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
        echo "[entrypoint] ERROR: leader not reachable after $MAX_ATTEMPTS attempts. Exiting."
        exit 1
    fi
    echo "[entrypoint] Attempt $ATTEMPT/$MAX_ATTEMPTS — leader not yet reachable, retrying in 2s..."
    sleep 2
done

echo "[entrypoint] Leader is reachable."

# -----------------------------------------------------------------------------
# 3. Follower broker
# -----------------------------------------------------------------------------
echo "[entrypoint] Starting follower broker..."
exec runuser -u hpcuser -- \
    flux broker \
        --config-path=/etc/flux/system/conf.d \
        -Srundir=/run/flux \
        sleep inf
