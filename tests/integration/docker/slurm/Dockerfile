# Slurm learning cluster — single image used for all nodes (controller + workers)
# Build arg lets you pin a specific Slurm version at build time.
#
# Usage:
#   docker compose build                              # uses default version
#   docker compose build --build-arg SLURM_VERSION=24.05.4

FROM rockylinux:9

ARG SLURM_VERSION=24.05.4
ARG OPENMPI_VERSION=4.1.6

# ---------------------------------------------------------------------------
# 1. System packages
#    - Build tools for compiling Slurm from source
#    - munge for authentication between nodes
#    - openssh for inter-node communication
#    - nc (nmap-ncat) used in entrypoint scripts to wait for the controller
# ---------------------------------------------------------------------------
RUN dnf -y update && \
    dnf -y install epel-release && \
    dnf config-manager --set-enabled crb && \
    dnf -y install \
        gcc gcc-c++ make \
        munge munge-devel munge-libs \
        pam-devel \
        python3 \
        openssl-devel \
        perl \
        readline-devel \
        hwloc-devel \
        numactl-devel \
        openssh-server openssh-clients \
        wget \
        tar \
        bzip2 \
        which \
        hostname \
        # PMIx — process-management interface used by both Slurm and OpenMPI
        # pmix-devel is in CRB (already enabled above)
        pmix \
        pmix-devel \
    && dnf clean all

# ---------------------------------------------------------------------------
# 2. Create system users with consistent UIDs across all containers
#    - slurm  (UID 995): system account that owns Slurm daemons/files
#    - hpcuser (UID 1001): unprivileged user for job submission
#    UIDs must match on every node so that shared-filesystem file ownership
#    resolves correctly.
# ---------------------------------------------------------------------------
RUN useradd -r -u 995 -d /var/lib/slurm -s /bin/bash -c "Slurm daemon" slurm && \
    useradd -u 1001 -m -s /bin/bash -c "HPC cluster user" hpcuser && \
    # Set a password so PAM's pam_unix account module doesn't treat hpcuser as
    # locked (shadow '!!' = locked; a real password removes that flag).
    # SSH still uses public-key auth — PasswordAuthentication is disabled below.
    echo "hpcuser:hpcuser" | chpasswd

# ---------------------------------------------------------------------------
# 3. Build and install Slurm from source
# ---------------------------------------------------------------------------
WORKDIR /tmp

RUN wget -q https://download.schedmd.com/slurm/slurm-${SLURM_VERSION}.tar.bz2 && \
    tar xf slurm-${SLURM_VERSION}.tar.bz2 && \
    cd slurm-${SLURM_VERSION} && \
    ./configure \
        --prefix=/usr \
        --sysconfdir=/etc/slurm \
        --with-pam_dir=/usr/lib64/security \
        --with-pmix=/usr \
    && make -j$(nproc) && \
    make install && \
    cd /tmp && \
    rm -rf slurm-${SLURM_VERSION} slurm-${SLURM_VERSION}.tar.bz2

# ---------------------------------------------------------------------------
# 4. Build OpenMPI from source with PMIx support
#
# The RPM-packaged OpenMPI is not compiled with PMIx, so `srun` cannot act
# as its process manager.  Building from source with --with-pmix allows:
#
#   srun ./mpi_hello          ← Slurm launches and bootstraps via PMIx
#   mpirun -np N ./mpi_hello  ← OpenMPI launcher, also PMIx-aware under Slurm
#
# Both Slurm and OpenMPI link against the same system PMIx library (pmix-devel)
# so they share the same wire protocol.
# ---------------------------------------------------------------------------
RUN wget -q "https://download.open-mpi.org/release/open-mpi/v4.1/openmpi-${OPENMPI_VERSION}.tar.bz2" && \
    tar xf openmpi-${OPENMPI_VERSION}.tar.bz2 && \
    cd openmpi-${OPENMPI_VERSION} && \
    ./configure \
        --prefix=/usr/local \
        --with-pmix=/usr \
    && make -j$(nproc) && \
    make install && \
    ldconfig && \
    cd /tmp && \
    rm -rf openmpi-${OPENMPI_VERSION} openmpi-${OPENMPI_VERSION}.tar.bz2

RUN mkdir -p \
        /var/spool/slurm/slurmd \
        /var/log/slurm \
        /var/run/slurm \
        /etc/slurm \
        /var/lib/slurm && \
    chown -R slurm:slurm \
        /var/spool/slurm \
        /var/log/slurm \
        /var/run/slurm \
        /var/lib/slurm

# ---------------------------------------------------------------------------
# 5. Munge key — baked into the image so every container shares the same key
#    WARNING: Not production-safe. In production, distribute the key securely
#    via secrets management (e.g. Docker secrets, Vault, etc.).
# ---------------------------------------------------------------------------
RUN dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key && \
    chown munge:munge /etc/munge/munge.key && \
    chmod 400 /etc/munge/munge.key

# ---------------------------------------------------------------------------
# 6. Passwordless SSH between nodes
#    A single keypair is generated at build time and installed as
#    authorized_keys for both root and hpcuser.  StrictHostKeyChecking is
#    disabled so nodes can SSH each other without manual host-key approval.
#    WARNING: Not production-safe. In production use proper key management.
# ---------------------------------------------------------------------------
RUN ssh-keygen -t rsa -b 4096 -N "" -f /tmp/cluster_rsa && \
    # root
    mkdir -p /root/.ssh && \
    cp /tmp/cluster_rsa   /root/.ssh/id_rsa && \
    cp /tmp/cluster_rsa.pub /root/.ssh/authorized_keys && \
    chmod 700 /root/.ssh && \
    chmod 600 /root/.ssh/id_rsa /root/.ssh/authorized_keys && \
    # hpcuser
    mkdir -p /home/hpcuser/.ssh && \
    cp /tmp/cluster_rsa   /home/hpcuser/.ssh/id_rsa && \
    cp /tmp/cluster_rsa.pub /home/hpcuser/.ssh/authorized_keys && \
    chown -R hpcuser:hpcuser /home/hpcuser/.ssh && \
    chmod 700 /home/hpcuser/.ssh && \
    chmod 600 /home/hpcuser/.ssh/id_rsa /home/hpcuser/.ssh/authorized_keys && \
    rm /tmp/cluster_rsa /tmp/cluster_rsa.pub

# Disable StrictHostKeyChecking cluster-wide
RUN echo "Host *" >> /etc/ssh/ssh_config && \
    echo "    StrictHostKeyChecking no" >> /etc/ssh/ssh_config && \
    echo "    UserKnownHostsFile /dev/null" >> /etc/ssh/ssh_config

# Generate SSH host keys for sshd
RUN ssh-keygen -A

RUN sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/'             /etc/ssh/sshd_config && \
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/'     /etc/ssh/sshd_config && \
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/'   /etc/ssh/sshd_config

# Replace RHEL's /etc/pam.d/sshd with a minimal container-friendly version.
# The default stack (pam_selinux, pam_namespace, pam_sepermit) causes
# pam_acct_mgmt() to return PAM_PERM_DENIED in containerised environments.
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
# 7. Slurm configuration files
# ---------------------------------------------------------------------------
COPY conf/slurm.conf  /etc/slurm/slurm.conf
COPY conf/cgroup.conf /etc/slurm/cgroup.conf

RUN chown slurm:slurm /etc/slurm/slurm.conf /etc/slurm/cgroup.conf

# ---------------------------------------------------------------------------
# 8. Entrypoint scripts
# ---------------------------------------------------------------------------
COPY scripts/entrypoint-controller.sh /entrypoint-controller.sh
COPY scripts/entrypoint-worker.sh     /entrypoint-worker.sh
RUN chmod +x /entrypoint-controller.sh /entrypoint-worker.sh

# ---------------------------------------------------------------------------
# 9. Environment
# ---------------------------------------------------------------------------
ENV SLURM_CONF=/etc/slurm/slurm.conf
# OpenMPI built from source installs to /usr/local
ENV PATH="/usr/local/bin:$PATH"
ENV LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"

WORKDIR /home/hpcuser
