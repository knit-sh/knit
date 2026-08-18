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
#    - Lmod: module system for the knit platform/profile tests.
#    - cmake + xz: let the demo experiment adopt a system CMake as a Spack
#      external and let Spack extract .tar.xz sources.
#    The overlay needs NO munge and NO sshd: brokers connect over a ZeroMQ
#    CURVE-secured TCP tree (port 8050), not SSH, and the instance is single-
#    user, so there is no cross-user credential to broker.
# ---------------------------------------------------------------------------
RUN dnf -y update && \
    dnf -y install epel-release && \
    dnf config-manager --set-enabled crb && \
    dnf -y install \
        openmpi openmpi-devel \
        gcc gcc-c++ make \
        Lmod \
        which \
        hostname \
        git \
        tar \
        cmake \
        xz \
    && dnf clean all

# ---------------------------------------------------------------------------
# 2. hpcuser (UID 1001) — the single user that owns the Flux instance on every
#    node. The UID must match across nodes so shared-filesystem ownership
#    resolves. (The base image already has "fluxuser" at UID 1002; 1001 is
#    free and matches the Slurm/PBS clusters.)
# ---------------------------------------------------------------------------
RUN useradd -u 1001 -m -s /bin/bash -c "HPC cluster user" hpcuser

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
