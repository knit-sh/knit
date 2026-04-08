#!/bin/bash
# =============================================================================
# configure-server.sh — PBS server initial configuration (PBS 23+)
# =============================================================================

set -e

echo "  [configure-server] Waiting for pbs_server to become responsive..."

MAX_WAIT=60
ELAPSED=0
INTERVAL=3

until /opt/pbs/bin/qmgr -c "print server" > /dev/null 2>&1; do
    if [ $ELAPSED -ge $MAX_WAIT ]; then
        echo "  [configure-server] ERROR: pbs_server did not become ready within ${MAX_WAIT}s."
        exit 1
    fi
    echo "  [configure-server] pbs_server not ready yet, retrying in ${INTERVAL}s... (${ELAPSED}s elapsed)"
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

echo "  [configure-server] pbs_server is ready. Applying configuration..."

# ---------------------------------------------------------------------------
# Server attributes
# ---------------------------------------------------------------------------
/opt/pbs/bin/qmgr -c "set server scheduling = True"
/opt/pbs/bin/qmgr -c "set server log_events = 511"
/opt/pbs/bin/qmgr -c "set server mail_from = adm"
/opt/pbs/bin/qmgr -c "set server query_other_jobs = True"
/opt/pbs/bin/qmgr -c "set server resources_default.ncpus = 1"
/opt/pbs/bin/qmgr -c "set server resources_default.walltime = 01:00:00"

# ---------------------------------------------------------------------------
# Default queue — must be created before setting server default_queue
# ---------------------------------------------------------------------------
/opt/pbs/bin/qmgr -c "create queue workq" 2>/dev/null || true   # no-op on restart
/opt/pbs/bin/qmgr -c "set queue workq queue_type = Execution"
/opt/pbs/bin/qmgr -c "set queue workq enabled = True"
/opt/pbs/bin/qmgr -c "set queue workq started = True"
/opt/pbs/bin/qmgr -c "set server default_queue = workq"

# ---------------------------------------------------------------------------
# Register compute nodes
# PBS 23 uses resources_available.ncpus; the old "np" attribute is gone.
# ---------------------------------------------------------------------------
/opt/pbs/bin/qmgr -c "create node pbs-compute1" 2>/dev/null || true
/opt/pbs/bin/qmgr -c "set node pbs-compute1 resources_available.ncpus = 2"

/opt/pbs/bin/qmgr -c "create node pbs-compute2" 2>/dev/null || true
/opt/pbs/bin/qmgr -c "set node pbs-compute2 resources_available.ncpus = 2"

echo "  [configure-server] Configuration applied successfully."
echo "  [configure-server] Run 'pbsnodes -a' to verify node registration."
