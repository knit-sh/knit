#!/bin/bash
# =============================================================================
# entrypoint-mom.sh — startup script for pbs-compute1 and pbs-compute2
#
# Responsibilities:
#   1. Start sshd (PBS server SSHes into MOM nodes to launch job prologs)
#   2. Write /etc/pbs.conf (MOM / execution role)
#   3. Write /var/spool/pbs/mom_priv/config (MOM-specific settings)
#   4. Start PBS daemons: pbs_comm, pbs_mom
#   5. Sleep forever to keep the container alive
#
# The hostname of this container (pbs-compute1 or pbs-compute2) is set by
# Docker Compose; pbs_mom registers itself with pbs_server on pbs-login.
# =============================================================================

set -e

NODE_NAME=$(hostname)
echo "=== [${NODE_NAME}] Starting OpenPBS MOM (execution) node ==="

# ---------------------------------------------------------------------------
# 1. Start SSH daemon
#    pbs_mom (and MPI launchers) SSH between nodes; sshd must be up before
#    the node can participate in multi-node jobs.
# ---------------------------------------------------------------------------
echo "[1/4] Starting sshd..."
/usr/sbin/sshd
echo "      sshd started."

# ---------------------------------------------------------------------------
# 2. Write /etc/pbs.conf for the MOM role
#
#    PBS_START_SERVER=0  — no server daemon on compute nodes
#    PBS_START_SCHED=0   — no scheduler on compute nodes
#    PBS_START_COMM=1    — communication layer (connects back to server)
#    PBS_START_MOM=1     — execution daemon runs here
# ---------------------------------------------------------------------------
echo "[2/4] Writing /etc/pbs.conf (MOM role)..."
cat > /etc/pbs.conf << EOF
PBS_SERVER=pbs-login
PBS_START_SERVER=0
PBS_START_SCHED=0
PBS_START_COMM=1
PBS_START_MOM=1
PBS_HOME=/var/spool/pbs
PBS_EXEC=/opt/pbs
EOF
echo "      /etc/pbs.conf written."

# ---------------------------------------------------------------------------
# 3. Write mom_priv/config
#
#    $clienthost  — the PBS server host that is allowed to send commands
#    $usecp       — directory copy rule: when PBS transfers output files
#                   whose path starts with *:/shared, it copies them to /shared
#                   on this node (works because /shared is a shared bind-mount)
# ---------------------------------------------------------------------------
echo "[3/4] Writing mom_priv/config..."
mkdir -p /var/spool/pbs/mom_priv
cat > /var/spool/pbs/mom_priv/config << 'EOF'
$clienthost pbs-login
$usecp *:/shared /shared
EOF
echo "      mom_priv/config written."

# ---------------------------------------------------------------------------
# 4. Start PBS MOM daemons
#
#    pbs_comm must start before pbs_mom so the communication channel to
#    pbs_server is established first.
# ---------------------------------------------------------------------------
echo "[4/4] Starting PBS MOM daemons..."

# Remove any stale lock files from a previous run
rm -f /var/spool/pbs/mom_priv/mom.lock /tmp/.comm* || true

echo "      Starting pbs_comm..."
/opt/pbs/sbin/pbs_comm &
sleep 2

echo "      Starting pbs_mom..."
/opt/pbs/sbin/pbs_mom || true
sleep 2

echo "      PBS MOM daemons started."
echo ""
echo "  [${NODE_NAME}] Ready to accept jobs from pbs-login."
echo "  Check status from pbs-login: pbsnodes -a"
echo ""

# ---------------------------------------------------------------------------
# Keep the container running
# ---------------------------------------------------------------------------
tail -f /dev/null
