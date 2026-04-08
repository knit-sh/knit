#!/bin/bash
# =============================================================================
# entrypoint-controller.sh — runs on slurm-login (the controller / login node)
#
# Responsibilities:
#   1. Start sshd (so users can SSH in and nodes can communicate)
#   2. Prepare shared filesystem directories
#   3. Start munge (authentication daemon)
#   4. Start slurmctld (the Slurm central controller)
#   5. Print initial cluster status
#   6. Keep the container alive
# =============================================================================

set -e

echo "============================================================"
echo " Slurm controller starting on $(hostname)"
echo "============================================================"

# -----------------------------------------------------------------------------
# 1. SSH daemon
# -----------------------------------------------------------------------------
echo "[entrypoint] Starting sshd..."
/usr/sbin/sshd || true   # sshd may already be running on restart; that's fine

# -----------------------------------------------------------------------------
# 2. Shared directory layout
#    /shared is bind-mounted from the host (./shared in the project root).
#    We create subdirs here so the host directory is bootstrapped automatically
#    when the controller starts, even on a fresh checkout.
# -----------------------------------------------------------------------------
echo "[entrypoint] Setting up /shared directories..."
mkdir -p /shared/jobs /shared/home /shared/runs || true

# sticky-bit + world-writable so all users can create directories there
chmod 1777 /shared/jobs /shared/runs || true

# -----------------------------------------------------------------------------
# 3. Munge — inter-node authentication
#    The munge key was baked into the image at build time, so every container
#    shares the same key without any runtime key distribution step.
# -----------------------------------------------------------------------------
echo "[entrypoint] Starting munge..."
# munged runs as root — dirs and key must be owned by root with restricted perms
mkdir -p /run/munge /var/log/munge /var/lib/munge
chown root:root /run/munge /var/log/munge /var/lib/munge /etc/munge /etc/munge/munge.key
chmod 0755 /run/munge
chmod 0700 /var/log/munge /var/lib/munge /etc/munge
chmod 0400 /etc/munge/munge.key
munged

echo "[entrypoint] Waiting for munge to initialize..."
sleep 2

# Quick sanity check — if munge can't encrypt/decrypt a credential the rest
# of Slurm will fail with confusing authentication errors.
if munge -n | unmunge > /dev/null 2>&1; then
    echo "[entrypoint] Munge OK"
else
    echo "[entrypoint] WARNING: munge self-test failed — check /var/log/munge/munged.log"
fi

# -----------------------------------------------------------------------------
# 4. Slurmctld — the central Slurm controller
#    -D runs it in "foreground" mode (it won't fork into the background on its
#    own).  We add & to put it in the shell's background so this script can
#    continue.
# -----------------------------------------------------------------------------
echo "[entrypoint] Starting slurmctld..."

# Ensure log/run/spool dirs exist and are owned by slurm
mkdir -p /var/log/slurm /var/run/slurm /var/spool/slurm/slurmd
chown -R slurm:slurm /var/log/slurm /var/run/slurm /var/spool/slurm

slurmctld -D &
SLURMCTLD_PID=$!
echo "[entrypoint] slurmctld started (PID $SLURMCTLD_PID)"

# Give slurmctld a moment to write its PID file and open its port before we
# try to query it.
echo "[entrypoint] Waiting for slurmctld to become ready..."
sleep 5

# -----------------------------------------------------------------------------
# 5. Print initial cluster status
#    Nodes will show as DOWN/UNKNOWN until the compute containers start and
#    their slurmd daemons connect back to the controller.
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Cluster status (nodes may still be registering)"
echo "============================================================"
sinfo        || true
echo ""
scontrol show nodes || true
echo "============================================================"
echo ""
echo "Tips:"
echo "  docker exec -it slurm-login bash"
echo "  su - hpcuser"
echo "  sbatch /shared/jobs/01_hello.sh"
echo "  squeue"
echo "============================================================"

# -----------------------------------------------------------------------------
# 6. Keep container alive
#    tail -f /dev/null blocks forever without consuming CPU, allowing Docker
#    to keep the container running while slurmctld runs in the background.
# -----------------------------------------------------------------------------
echo "[entrypoint] Controller ready. Tailing logs (Ctrl-C to stop)..."
tail -f /var/log/slurm/slurmctld.log
