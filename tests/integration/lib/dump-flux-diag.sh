#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# dump-flux-diag.sh — Dump Flux overlay diagnostics after a failed bring-up.
#
# Usage:
#   dump-flux-diag.sh
#
# Run by the Makefile's cluster-up-flux target when wait-for-cluster.sh times
# out. The readiness probe only reports "the overlay did not form"; it cannot
# say why. This script prints the state that explains it: whether every broker
# process is running, whether the compute brokers reached the leader's overlay
# port, and what the leader broker itself logged.
#
# The flux integration overlay forms in a few seconds locally but has timed out
# on the GitHub Actions runner, so the failure is specific to that environment
# and cannot be reproduced by hand. This dump is the only way to see the real
# cause from a CI log.
#
# Every command is best-effort: a container that never started, or a broker that
# is not accepting commands, must not make the dump itself fail. The caller is
# responsible for the non-zero exit that fails the build.
# ------------------------------------------------------------------------------
set -u

log_in="flux-login"
workers="flux-compute1 flux-compute2"

section() {
    printf '\n----- %s -----\n' "$1"
}

printf '\n================ FLUX OVERLAY DIAGNOSTICS ================\n'
printf 'The readiness probe timed out; the broker overlay never formed.\n'

section "container status"
docker ps -a --filter 'name=flux-' \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>&1 || true

# Worker entrypoints log their wait for flux-login:8050 and any broker crash, so
# their container logs show whether a follower reached the leader at all.
for c in ${log_in} ${workers}; do
    section "docker logs ${c} (tail)"
    docker logs --tail 40 "${c}" 2>&1 || true
done

# The leader is single-user (hpcuser); flux commands must run as that user. The
# overlay status names each rank's state (full/partial/offline), dmesg carries
# the broker's own errors, and the interface list confirms the name the overlay
# binds to (system.toml binds by interface name).
section "flux overlay status (leader)"
docker exec --user hpcuser "${log_in}" flux overlay status 2>&1 || true

section "flux resource list (leader)"
docker exec --user hpcuser "${log_in}" flux resource list 2>&1 || true

section "flux dmesg (leader, tail)"
docker exec --user hpcuser "${log_in}" sh -c 'flux dmesg 2>&1 | tail -40' 2>&1 || true

section "leader network interfaces"
docker exec "${log_in}" sh -c 'ip -o -4 addr show 2>/dev/null || ls /sys/class/net' 2>&1 || true

printf '\n=========================================================\n'
