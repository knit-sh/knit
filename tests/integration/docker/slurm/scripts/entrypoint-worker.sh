#!/bin/bash
# =============================================================================
# entrypoint-worker.sh — runs on slurm-compute1 and slurm-compute2
#
# Responsibilities:
#   1. Start sshd (Slurm uses SSH for some inter-node operations)
#   2. Start munge (must be running before slurmd can authenticate)
#   3. Wait until the controller (slurm-login:6817) is reachable
#   4. Start slurmd (the Slurm node daemon)
#   5. Keep the container alive
# =============================================================================

set -e

echo "============================================================"
echo " Slurm worker starting on $(hostname)"
echo "============================================================"

# -----------------------------------------------------------------------------
# 1. SSH daemon
# -----------------------------------------------------------------------------
echo "[entrypoint] Starting sshd..."
/usr/sbin/sshd || true

# -----------------------------------------------------------------------------
# 2. Munge
# -----------------------------------------------------------------------------
echo "[entrypoint] Starting munge..."
mkdir -p /run/munge /var/log/munge /var/lib/munge
chown root:root /run/munge /var/log/munge /var/lib/munge /etc/munge /etc/munge/munge.key
chmod 0755 /run/munge
chmod 0700 /var/log/munge /var/lib/munge /etc/munge
chmod 0400 /etc/munge/munge.key
munged

echo "[entrypoint] Waiting for munge to initialize..."
sleep 2

if munge -n | unmunge > /dev/null 2>&1; then
    echo "[entrypoint] Munge OK"
else
    echo "[entrypoint] WARNING: munge self-test failed — check /var/log/munge/munged.log"
fi

# -----------------------------------------------------------------------------
# 3. Wait for the controller to be reachable on port 6817
#    We use bash's built-in /dev/tcp pseudo-device so we don't depend on
#    any particular version of nc/netcat being present.
#    The loop tries every 2 seconds for up to ~5 minutes (150 attempts).
# -----------------------------------------------------------------------------
echo "[entrypoint] Waiting for slurm-login:6817 to be reachable..."

MAX_ATTEMPTS=150
ATTEMPT=0

until bash -c "echo > /dev/tcp/slurm-login/6817" 2>/dev/null; do
    ATTEMPT=$((ATTEMPT + 1))
    if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
        echo "[entrypoint] ERROR: controller not reachable after $MAX_ATTEMPTS attempts. Exiting."
        exit 1
    fi
    echo "[entrypoint] Attempt $ATTEMPT/$MAX_ATTEMPTS — controller not yet reachable, retrying in 2s..."
    sleep 2
done

echo "[entrypoint] Controller is reachable."

# Give slurmctld a little extra time to finish its own startup sequence
# (state restoration, etc.) before we register this node.
sleep 2

# -----------------------------------------------------------------------------
# 4. Slurmd — the per-node Slurm daemon
#    -D keeps it in the foreground; & puts it in the shell background.
#    -N overrides the NodeName so slurmd registers with the correct hostname
#    as defined in slurm.conf (the container hostname is set to match, but
#    being explicit avoids surprises if /etc/hosts resolution is slow).
# -----------------------------------------------------------------------------
echo "[entrypoint] Starting slurmd..."

mkdir -p /var/log/slurm /var/run/slurm /var/spool/slurm/slurmd
chown -R slurm:slurm /var/log/slurm /var/run/slurm /var/spool/slurm

slurmd -D -N "$(hostname)" &
SLURMD_PID=$!
echo "[entrypoint] slurmd started (PID $SLURMD_PID) for node $(hostname)"

# -----------------------------------------------------------------------------
# 5. Keep container alive and stream slurmd log for easy debugging
#    Use tail -F (retry) so the container keeps running even if slurmd hasn't
#    created the log file yet.
# -----------------------------------------------------------------------------
echo "[entrypoint] Worker ready. Tailing logs (Ctrl-C to stop)..."
# Wait a moment, then print any early slurmd errors to help debugging
sleep 3
if ! kill -0 "$SLURMD_PID" 2>/dev/null; then
    echo "[entrypoint] ERROR: slurmd exited unexpectedly. Check the log:"
    cat /var/log/slurm/slurmd.log 2>/dev/null || echo "(no log file created)"
    exit 1
fi
# tail -F retries if the file doesn't exist yet
tail -F /var/log/slurm/slurmd.log 2>/dev/null || tail -f /dev/null
