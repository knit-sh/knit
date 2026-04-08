# =============================================================================
# OpenPBS Cluster Node Image
# Base: Rocky Linux 9
# Builds OpenPBS from source and sets up both server and MOM node roles.
# The same image is used for pbs-login (server) and pbs-compute* (MOM) nodes;
# the entrypoint script determines which role a container plays at runtime.
# =============================================================================

FROM rockylinux:9

# ---------------------------------------------------------------------------
# Build argument: PBS version to download from GitHub releases
# Override at build time: docker compose build --build-arg PBS_VERSION=24.06.0
# ---------------------------------------------------------------------------
ARG PBS_VERSION=23.06.06

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
# Development tools needed to compile OpenPBS from source
RUN dnf -y update && \
    dnf -y install epel-release && \
    dnf config-manager --set-enabled crb && \
    dnf -y install \
        gcc \
        gcc-c++ \
        make \
        libtool \
        autoconf \
        automake \
        openssl-devel \
        libxml2-devel \
        boost-devel \
        expat-devel \
        libedit-devel \
        libical-devel \
        hwloc-devel \
        postgresql-devel \
        postgresql-server \
        postgresql-contrib \
        python3-devel \
        python3-pip \
        swig \
        tcl-devel \
        tk-devel \
        libXt-devel \
        libX11-devel \
        perl \
        # Runtime / utility packages
        openssh-server \
        openssh-clients \
        wget \
        tar \
        gzip \
        sudo \
        which \
        hostname \
        net-tools \
        iproute \
        # MPI — MPICH from AppStream/EPEL
        mpich \
        mpich-devel \
    && dnf clean all

# ---------------------------------------------------------------------------
# Build and install OpenPBS from source
# ---------------------------------------------------------------------------
WORKDIR /tmp/pbsbuild

RUN wget -q "https://github.com/openpbs/openpbs/archive/refs/tags/v${PBS_VERSION}.tar.gz" \
        -O openpbs-${PBS_VERSION}.tar.gz && \
    tar -xzf openpbs-${PBS_VERSION}.tar.gz && \
    cd openpbs-${PBS_VERSION} && \
    # Generate the configure script from autoconf/automake templates
    ./autogen.sh && \
    # Configure: install everything under /opt/pbs
    # --with-pgsql-dir=/usr tells PBS where to find pg_ctl, initdb, etc.
    # (Rocky Linux 9 installs postgresql-server binaries to /usr/bin)
    ./configure --prefix=/opt/pbs --with-pgsql-dir=/usr && \
    # Parallel compile using all available cores
    make -j$(nproc) && \
    make install && \
    # pbs_postinstall sets up the /var/spool/pbs hierarchy and init-system
    # wrappers. In a container (no systemd) it may skip user/dir creation,
    # so we handle those explicitly below.
    /opt/pbs/libexec/pbs_postinstall || true && \
    # Clean up build artefacts to reduce image size
    cd / && rm -rf /tmp/pbsbuild

# pbs_postinstall does not reliably create the pbsdata user or the datastore
# directory inside a container (it expects systemd). Create them explicitly.
RUN id pbsdata &>/dev/null || \
        (groupadd -r pbsdata && \
         useradd -r -g pbsdata \
                 -d /var/spool/pbs/datastore \
                 -c "PBS Data Service User" \
                 -s /sbin/nologin pbsdata) && \
    mkdir -p /var/spool/pbs/datastore && \
    # pbs_postinstall writes "postgres" (not "pbsdata") to server_priv/db_user
    # when it detects the system postgresql-server package. The datastore owner
    # must match that value or pbs_dataservice refuses to start.
    chown postgres:postgres /var/spool/pbs/datastore && \
    chmod 700 /var/spool/pbs/datastore

# ---------------------------------------------------------------------------
# PATH — PBS binaries + MPICH binaries and libraries
# MPICH installs to /usr/lib64/mpich/ on Rocky Linux 9
# ---------------------------------------------------------------------------
ENV PATH="/opt/pbs/bin:/opt/pbs/sbin:/usr/lib64/mpich/bin:$PATH"
ENV LD_LIBRARY_PATH="/usr/lib64/mpich/lib:$LD_LIBRARY_PATH"

# ---------------------------------------------------------------------------
# Create hpcuser (UID/GID 1001) for job submission
# ---------------------------------------------------------------------------
RUN groupadd -g 1001 hpcuser && \
    useradd  -u 1001 -g 1001 -m -s /bin/bash hpcuser && \
    # Set a password so PAM's pam_unix account module doesn't treat the account
    # as locked (shadow '!!' means locked; a real password removes that).
    # SSH still uses public-key auth — PasswordAuthentication is disabled below.
    echo "hpcuser:hpcuser" | chpasswd && \
    # Allow hpcuser to run qsub / qstat without password via sudo (optional QoL)
    echo "hpcuser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/hpcuser

# ---------------------------------------------------------------------------
# SSH key setup (passwordless SSH for MPI / inter-node communication)
#
# NOTE: Embedding a shared keypair in the image is only acceptable for a
# learning/development environment — do NOT do this in production.
#
# We generate the keypair here so all containers share the same private key
# and each container's authorized_keys already contains the matching public
# key, enabling passwordless SSH between any pair of nodes.
# ---------------------------------------------------------------------------

# Generate host keys so sshd can start
RUN ssh-keygen -A

# Root SSH keypair
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh && \
    ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa && \
    cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys && \
    chmod 600 /root/.ssh/authorized_keys /root/.ssh/id_rsa

# hpcuser SSH keypair — reuse root's key so any node can SSH to any other
# node as either user (MPI jobs often run as hpcuser)
RUN mkdir -p /home/hpcuser/.ssh && \
    chmod 700 /home/hpcuser/.ssh && \
    cp /root/.ssh/id_rsa     /home/hpcuser/.ssh/id_rsa && \
    cp /root/.ssh/id_rsa.pub /home/hpcuser/.ssh/id_rsa.pub && \
    cat /home/hpcuser/.ssh/id_rsa.pub >> /home/hpcuser/.ssh/authorized_keys && \
    # Also trust root's key (PBS server SSHes in as root for some operations)
    cat /root/.ssh/id_rsa.pub >> /home/hpcuser/.ssh/authorized_keys && \
    chmod 600 /home/hpcuser/.ssh/authorized_keys \
              /home/hpcuser/.ssh/id_rsa && \
    chown -R hpcuser:hpcuser /home/hpcuser/.ssh

# SSH client config: disable strict host-key checking so containers can
# connect to each other without manual known_hosts management
RUN printf "Host *\n\
    StrictHostKeyChecking no\n\
    UserKnownHostsFile /dev/null\n\
    LogLevel ERROR\n" > /etc/ssh/ssh_config.d/cluster.conf && \
    # Also write the same config for hpcuser
    mkdir -p /home/hpcuser/.ssh && \
    cp /etc/ssh/ssh_config.d/cluster.conf /home/hpcuser/.ssh/config && \
    chown hpcuser:hpcuser /home/hpcuser/.ssh/config && \
    chmod 600 /home/hpcuser/.ssh/config

# Allow root login via SSH (needed for PBS inter-node communication)
RUN sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/'           /etc/ssh/sshd_config && \
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/'   /etc/ssh/sshd_config && \
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

# Replace the RHEL-generated /etc/pam.d/sshd with a minimal container-friendly
# version.  The default stack includes pam_selinux, pam_namespace, and
# pam_sepermit, which interact poorly with containerised environments and cause
# pam_acct_mgmt() to return PAM_PERM_DENIED even for valid accounts.
# pam_permit in the account phase unconditionally allows the account check,
# which is safe here because access control is already handled by SSH pubkeys.
RUN printf '%s\n' \
    '#%PAM-1.0' \
    'auth       sufficient   pam_unix.so try_first_pass nullok' \
    'auth       required     pam_deny.so' \
    'account    required     pam_permit.so' \
    'session    optional     pam_keyinit.so revoke' \
    'session    required     pam_limits.so' \
    'session    optional     pam_unix.so' \
    > /etc/pam.d/sshd

# ---------------------------------------------------------------------------
# /shared mount point — actual content is bind-mounted at runtime
# ---------------------------------------------------------------------------
RUN mkdir -p /shared

# ---------------------------------------------------------------------------
# Copy entrypoint scripts into the image
# ---------------------------------------------------------------------------
COPY scripts/entrypoint-server.sh   /entrypoint-server.sh
COPY scripts/entrypoint-mom.sh      /entrypoint-mom.sh
COPY scripts/configure-server.sh    /configure-server.sh

RUN chmod +x /entrypoint-server.sh \
             /entrypoint-mom.sh \
             /configure-server.sh

# Default command (overridden by each service in docker-compose.yml)
CMD ["/bin/bash"]
