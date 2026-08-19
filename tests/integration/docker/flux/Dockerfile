# Flux learning cluster — single image used for all nodes (leader + workers).
#
# Base is fluxrm/flux-core:el9, the official Flux image on Rocky Linux 9. Flux
# is not packaged in EPEL 9, so this EL9 image is how a knit experiment gets a
# Rocky-9 base (the same OS family as the Slurm/PBS clusters) with flux-core,
# flux-security, and the built-in sched-simple scheduler already installed — no
# source build. The tag can be pinned at build time:
#   docker compose build --build-arg FLUX_TAG=el9-v0.88.0
ARG FLUX_TAG=el9
FROM fluxrm/flux-core:${FLUX_TAG}

# The base image runs as the unprivileged "fluxuser"; build steps need root.
USER root

# ---------------------------------------------------------------------------
# 1. System packages
#    - OpenMPI: an MPI that launches under `flux run` (OpenMPI's "pmix: flux"
#      MCA component bootstraps from the Flux PMI). Exposed via an Lmod module.
#    - MPICH: a second MPI put on PATH (section 1c) purely as a detection foil
#      for experiment 13. It proves that under a Flux scheduler `flux run` wins
#      the launcher auto-detection even when an MPI-native launcher is on PATH.
#      Nothing ever launches through it, so it needs no cross-node SSH wiring.
#    - Lmod: module system for the knit platform/profile tests. The base image
#      also ships environment-modules (Tcl). Both claim the "module" command
#      through the modules.sh alternative, and the Tcl one has the higher
#      priority, but it cannot read the .lua modulefiles the tests install. So
#      environment-modules is removed to leave Lmod as the only "module"
#      provider (as on the Slurm and PBS images), and modules.sh then resolves
#      to Lmod.
#    - cmake + xz: let the demo experiment adopt a system CMake as a Spack
#      external and let Spack extract .tar.xz sources.
#    - openssh: the broker overlay does NOT need SSH (brokers connect over a
#      ZeroMQ CURVE-secured TCP tree on port 8050, and the instance is single-
#      user). SSH is here only for the "laptop launcher" path (experiment 16),
#      where a setup supplies an MPI-native launcher (OpenMPI's mpirun) and the
#      machine declares no integrated launcher — that mpirun spans nodes over
#      SSH, the same as the Slurm and PBS images do for their module MPIs.
#    The overlay needs NO munge: it is single-user, so there is no cross-user
#    credential to broker.
# ---------------------------------------------------------------------------
RUN dnf -y update && \
    dnf -y install epel-release && \
    dnf config-manager --set-enabled crb && \
    dnf -y install \
        openmpi openmpi-devel \
        mpich mpich-devel \
        gcc gcc-c++ make \
        Lmod \
        which \
        hostname \
        git \
        tar \
        cmake \
        xz \
        openssh-server openssh-clients \
    && dnf -y remove environment-modules \
    && dnf clean all

# ---------------------------------------------------------------------------
# 1b. Make the packaged OpenMPI behave like a normal HPC MPI, so the same MPI
#     experiments run here as on the Slurm image (which builds OpenMPI from
#     source and therefore has neither of the two quirks below).
#
#   - pml = ob1: this cluster has no RDMA fabric (plain TCP over the bridge),
#     but the RPM OpenMPI prefers its UCX PML (priority 51). UCX over TCP-only
#     deadlocks in MPI_Finalize (opal_common_ucx del_procs) once several ranks
#     have exchanged enough data. Selecting the ob1 PML (TCP + shared memory) is
#     the standard configuration for a non-RDMA cluster.
#
#   - -DOMPI_SKIP_MPICXX in the compiler wrappers: the RPM OpenMPI is built with
#     the deprecated C++ bindings, so <mpi.h> pulls libmpi_cxx symbols into any
#     C++ translation unit. A C++ program that uses only the MPI C API (and links
#     CMake's MPI::MPI_C, which pulls libmpi but not libmpi_cxx) then fails to
#     link. Defining OMPI_SKIP_MPICXX in the wrapper flags keeps <mpi.h> to the C
#     API, as the source-built OpenMPI on the Slurm image does.
#
#   - orte_launch_agent = <abs path>/orted: the "laptop launcher" path
#     (experiment 16) runs mpirun outside any resource manager, so ORTE starts
#     orted on the compute nodes over SSH. This RPM is not built with
#     --enable-orterun-prefix-by-default, and mpirun is invoked by its PATH name
#     (not an absolute path), so ORTE cannot tell the remote shell where orted
#     is — the non-interactive SSH shell has no OpenMPI on PATH and the launch
#     fails with "orted: command not found". Naming orted by absolute path makes
#     the remote launch independent of the remote PATH. This affects only the
#     SSH launch path; runs that go through `flux run` (the other experiments)
#     do not use ORTE at all.
#
# The sysconfdir is arch-specific (/etc/openmpi-<arch>), so ask ompi_info for it;
# the wrapper data lives under the (arch-independent) install prefix.
# ---------------------------------------------------------------------------
RUN OMPI_BIN=/usr/lib64/openmpi/bin && \
    MCA_CONF="$("${OMPI_BIN}/ompi_info" --path sysconfdir | awk '{print $2}')/openmpi-mca-params.conf" && \
    printf '\n# knit test cluster: no RDMA fabric — use the TCP/shared-memory PML.\npml = ob1\nosc = ^ucx\n' >> "${MCA_CONF}" && \
    printf '\n# knit test cluster: name orted by absolute path so an SSH launch\n# (the laptop-launcher path) does not depend on the remote PATH.\norte_launch_agent = %s/orted\n' "${OMPI_BIN}" >> "${MCA_CONF}" && \
    for w in mpicc mpicxx mpic++ mpiCC; do \
        f="/usr/lib64/openmpi/share/openmpi/${w}-wrapper-data.txt"; \
        if [ -f "${f}" ]; then \
            sed -i 's/^compiler_flags=.*/compiler_flags= -DOMPI_SKIP_MPICXX/' "${f}"; \
        fi; \
    done

# ---------------------------------------------------------------------------
# 1c. Put MPICH on PATH as a launcher-detection foil (experiment 13).
#    MPICH installs to /usr/lib64/mpich on Rocky Linux 9. Prepending its bin to
#    PATH makes `mpirun`/`mpiexec` resolve to MPICH's Hydra on the login node, so
#    the launcher auto-detection has an MPI-native launcher to find — yet under a
#    Flux scheduler `flux run` still wins. OpenMPI stays OFF PATH (its module
#    prepends /usr/lib64/openmpi/bin, so a loaded openmpi module overrides this).
#    MPICH is a foil only; no experiment launches through it, so it needs none of
#    the SSH/orted wiring the OpenMPI path (section 1b, experiment 16) requires.
# ---------------------------------------------------------------------------
ENV PATH="/usr/lib64/mpich/bin:$PATH"
ENV LD_LIBRARY_PATH="/usr/lib64/mpich/lib:$LD_LIBRARY_PATH"

# ---------------------------------------------------------------------------
# 2. hpcuser (UID 1001) — the single user that owns the Flux instance on every
#    node. The UID must match across nodes so shared-filesystem ownership
#    resolves. (The base image already has "fluxuser" at UID 1002; 1001 is
#    free and matches the Slurm/PBS clusters.)
# ---------------------------------------------------------------------------
RUN useradd -u 1001 -m -s /bin/bash -c "HPC cluster user" hpcuser && \
    # A real password removes the shadow '!!' lock flag so PAM's pam_unix
    # account module does not treat hpcuser as locked. SSH uses public-key auth
    # only (PasswordAuthentication is disabled below).
    echo "hpcuser:hpcuser" | chpasswd

# ---------------------------------------------------------------------------
# 2b. Passwordless SSH for the MPI-native launcher path (experiment 16)
#    Only hpcuser needs SSH: the Flux instance and every MPI run are hpcuser.
#    A single keypair is generated at build time and installed as hpcuser's
#    authorized_keys so mpirun can start orted on the compute nodes without a
#    prompt. StrictHostKeyChecking is disabled so a first contact needs no
#    manual host-key approval.
#    WARNING: Not production-safe. A real deployment uses proper key management.
# ---------------------------------------------------------------------------
RUN ssh-keygen -t rsa -b 4096 -N "" -f /tmp/cluster_rsa && \
    mkdir -p /home/hpcuser/.ssh && \
    cp /tmp/cluster_rsa     /home/hpcuser/.ssh/id_rsa && \
    cp /tmp/cluster_rsa.pub /home/hpcuser/.ssh/authorized_keys && \
    chown -R hpcuser:hpcuser /home/hpcuser/.ssh && \
    chmod 700 /home/hpcuser/.ssh && \
    chmod 600 /home/hpcuser/.ssh/id_rsa /home/hpcuser/.ssh/authorized_keys && \
    rm /tmp/cluster_rsa /tmp/cluster_rsa.pub

# Disable StrictHostKeyChecking cluster-wide, generate the sshd host keys, and
# allow public-key (not password) logins.
RUN printf '%s\n' \
        'Host *' \
        '    StrictHostKeyChecking no' \
        '    UserKnownHostsFile /dev/null' \
        >> /etc/ssh/ssh_config && \
    ssh-keygen -A && \
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/'    /etc/ssh/sshd_config && \
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

# Replace RHEL's /etc/pam.d/sshd with a minimal container-friendly version.
# The default stack (pam_selinux, pam_namespace, pam_sepermit) makes
# pam_acct_mgmt() return PAM_PERM_DENIED in containers.
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
# 3. Shared CURVE certificate for the broker overlay
#    Generated once and baked into the image so it is byte-identical on every
#    node. Owned by hpcuser (the instance runs as hpcuser) and mode 0600 —
#    flux refuses a certificate that is readable by group or other.
#    WARNING: Not production-safe. A real deployment distributes the cert via
#    secrets management, not baked into an image.
# ---------------------------------------------------------------------------
RUN mkdir -p /etc/flux/system/conf.d && \
    flux keygen /etc/flux/system/curve.cert

# ---------------------------------------------------------------------------
# 4. Configuration and the knit profile
# ---------------------------------------------------------------------------
COPY conf/flux/system.toml /etc/flux/system/conf.d/system.toml

RUN chown -R hpcuser:hpcuser /etc/flux/system && \
    chmod 600 /etc/flux/system/curve.cert

# Lmod modulefiles (auto-discovered: /usr/share/modulefiles is on the default
# MODULEPATH) and the admin profile resolved by `knit bootstrap --profile flux`.
COPY conf/modulefiles/knit-marker.lua /usr/share/modulefiles/knit-marker.lua
COPY conf/modulefiles/openmpi.lua     /usr/share/modulefiles/openmpi.lua
COPY conf/knit/flux.json              /etc/knit/profiles/flux.json

# ---------------------------------------------------------------------------
# 5. Entrypoint scripts
# ---------------------------------------------------------------------------
COPY scripts/entrypoint-login.sh  /entrypoint-login.sh
COPY scripts/entrypoint-worker.sh /entrypoint-worker.sh
RUN chmod +x /entrypoint-login.sh /entrypoint-worker.sh

# ---------------------------------------------------------------------------
# 6. Environment
#    FLUX_F58_FORCE_ASCII makes flux print job ids with a plain "f" prefix
#    instead of the default Unicode "ƒ", so knit stores clean ASCII tokens.
# ---------------------------------------------------------------------------
ENV FLUX_F58_FORCE_ASCII=1

WORKDIR /home/hpcuser
