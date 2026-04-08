#!/bin/bash
# =============================================================================
# entrypoint-server.sh — startup script for the pbs-login (server) node
# =============================================================================

set -e

echo "=== [pbs-login] Starting OpenPBS server node ==="

# ---------------------------------------------------------------------------
# Export PBS/PostgreSQL environment early.
# pbs_db_env sets PGSQL_BIN (path to pg_ctl, initdb, psql, etc.) which
# LIBDB needs when pbs_server calls into the PBS database layer.
# We set PBS_EXEC here so pbs_db_env doesn't need /etc/pbs.conf to be
# written first.
# ---------------------------------------------------------------------------
export PBS_EXEC=/opt/pbs
export PBS_HOME=/var/spool/pbs
. /opt/pbs/libexec/pbs_db_env

# ---------------------------------------------------------------------------
# 1. Start SSH daemon
# ---------------------------------------------------------------------------
echo "[1/6] Starting sshd..."
/usr/sbin/sshd
echo "      sshd started."

# ---------------------------------------------------------------------------
# 2. Shared directory setup
# ---------------------------------------------------------------------------
echo "[2/6] Setting up /shared directories..."
mkdir -p /shared/jobs /shared/home /shared/runs
chmod 1777 /shared/jobs /shared/runs
echo "      /shared ready."

# ---------------------------------------------------------------------------
# 3. Write /etc/pbs.conf for the server role
# ---------------------------------------------------------------------------
echo "[3/6] Writing /etc/pbs.conf (server role)..."
cat > /etc/pbs.conf << 'EOF'
PBS_SERVER=pbs-login
PBS_START_SERVER=1
PBS_START_SCHED=1
PBS_START_COMM=1
PBS_START_MOM=0
PBS_HOME=/var/spool/pbs
PBS_EXEC=/opt/pbs
PBS_DATA_SERVICE_HOST=localhost
PBS_DATA_SERVICE_PORT=15007
EOF
echo "      /etc/pbs.conf written."

# ---------------------------------------------------------------------------
# 4. Start PBS daemons
# ---------------------------------------------------------------------------
echo "[4/6] Starting PBS daemons..."

# Clean up stale lock files from a previous crashed run
rm -f /var/spool/pbs/server_priv/server.lock \
      /var/spool/pbs/sched_priv/sched.lock    \
      /tmp/.comm* 2>/dev/null || true

echo "      Starting pbs_comm..."
/opt/pbs/sbin/pbs_comm &
sleep 2

# ---------------------------------------------------------------------------
# PostgreSQL / PBS datastore initialisation
#
# On Rocky Linux 9 with a system PostgreSQL (not the bundled one), PBS's
# own pbs_dataservice wrapper cannot auto-initialise the cluster.  We do it
# manually:
#
#   First run:
#     a) initdb — create the PostgreSQL cluster
#     b) Append PBS-specific settings to postgresql.conf
#     c) Create /var/run/postgresql (standard RHEL socket dir; PBS looks here)
#     d) Start PostgreSQL
#     e) Create the pbs_datastore database
#     f) Touch pbs_opaque — LIBDB reads this file before connecting; an empty
#        file makes it attempt the connection with an empty password, which
#        PostgreSQL accepts under trust auth.
#
#   Subsequent runs (PG_VERSION already exists):
#     Just start PostgreSQL and recreate the runtime socket directory.
# ---------------------------------------------------------------------------
echo "      Initializing PBS datastore..."

mkdir -p /var/run/postgresql
chown postgres:postgres /var/run/postgresql
chmod 775 /var/run/postgresql

if [ ! -f /var/spool/pbs/datastore/PG_VERSION ]; then
    echo "         First run: running initdb..."
    su -s /bin/bash postgres -c \
        "initdb -D /var/spool/pbs/datastore -U postgres \
         --auth-local=trust --auth-host=trust \
         --encoding=UTF8 --locale=C"

    echo "         Appending PBS settings to postgresql.conf..."
    cat >> /var/spool/pbs/datastore/postgresql.conf << 'PGCONF'
# --- PBS overrides ---
port                    = 15007
listen_addresses        = '*'
unix_socket_directories = '/var/run/postgresql'
shared_buffers          = 32MB
huge_pages              = off
PGCONF
fi

echo "         Starting PostgreSQL..."
su -s /bin/bash postgres -c \
    "pg_ctl -D /var/spool/pbs/datastore \
            -l /var/spool/pbs/datastore/pbs_datasvc.log start" || {
    echo "!!! PostgreSQL failed to start. Log output:";
    cat /var/spool/pbs/datastore/pbs_datasvc.log 2>/dev/null;
    exit 1; }
sleep 4

# Create the pbs_datastore database if it doesn't exist yet
su -s /bin/bash postgres -c \
    "psql -h /var/run/postgresql -p 15007 -U postgres \
          -tc \"SELECT 1 FROM pg_database WHERE datname='pbs_datastore'\" \
    | grep -q 1 || createdb -h /var/run/postgresql -p 15007 -U postgres pbs_datastore" 2>&1 || true

# Ensure pbs_opaque exists — even an empty file lets LIBDB attempt a
# connection (trust auth accepts any password, including empty).
if [ ! -f /var/spool/pbs/server_priv/pbs_opaque ]; then
    touch /var/spool/pbs/server_priv/pbs_opaque
    chmod 600 /var/spool/pbs/server_priv/pbs_opaque
fi

# Apply the PBS database schema if not yet present.
# pbs_server's internal pbs_status_db() connects to pbs_datastore and
# queries pbs.info to check readiness.  Without the schema the query fails
# and the server enters an infinite "PBS dataservice not running" retry loop.
echo "      Applying PBS database schema..."
su -s /bin/bash postgres -c \
    "psql -h /var/run/postgresql -p 15007 -U postgres -d pbs_datastore \
          -c 'SELECT 1 FROM pbs.info LIMIT 1' 2>/dev/null" \
    && echo "         Schema already present, skipping." \
    || su -s /bin/bash postgres -c \
           "psql -h /var/run/postgresql -p 15007 -U postgres -d pbs_datastore \
                 -f /opt/pbs/libexec/pbs_db_schema.sql 2>&1"

echo "      Starting pbs_server..."
# -t create initialises the PBS schema on the very first run;
# on subsequent runs it is a no-op when the DB already has the schema.
/opt/pbs/sbin/pbs_server -t create || true
sleep 5

echo "      Starting pbs_sched..."
/opt/pbs/sbin/pbs_sched || true
sleep 2

echo "      PBS daemons started."

# ---------------------------------------------------------------------------
# 5. Configure queues, resources, and compute nodes
# ---------------------------------------------------------------------------
echo "[5/6] Configuring PBS server (queues, nodes)..."
/configure-server.sh || echo "      WARNING: configure-server.sh had errors (see above). PBS is still running."
echo "      PBS server configured."

# ---------------------------------------------------------------------------
# 6. Keep the container alive
# ---------------------------------------------------------------------------
echo "[6/6] Server node ready."
echo ""
echo "  Connect:   docker exec -it pbs-login bash"
echo "  Switch to: su - hpcuser"
echo "  Submit:    qsub /shared/jobs/01_hello.pbs"
echo ""
tail -f /dev/null
