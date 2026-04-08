#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# wait-for-cluster.sh — Poll until the job manager is ready to accept commands.
#
# Usage:
#   wait-for-cluster.sh slurm|pbs
#
# Exits 0 when the cluster is ready, 1 if the timeout is reached.
# This script is run inside the login container (via docker exec) by the
# integration test Makefile after `docker compose up`.
# ------------------------------------------------------------------------------
set -euo pipefail

TYPE="${1:-}"
case "${TYPE}" in
    slurm) READY_CMD="sinfo" ;;
    pbs)   READY_CMD="pbsnodes -a" ;;
    *)
        printf 'Usage: %s slurm|pbs\n' "$(basename "$0")" >&2
        exit 1
        ;;
esac

TIMEOUT=120
INTERVAL=3
elapsed=0

printf 'Waiting for %s cluster (timeout %ds)...\n' "${TYPE}" "${TIMEOUT}"
while ! ${READY_CMD} &>/dev/null; do
    if (( elapsed >= TIMEOUT )); then
        printf 'Timed out waiting for %s cluster after %ds.\n' "${TYPE}" "${TIMEOUT}" >&2
        exit 1
    fi
    sleep "${INTERVAL}"
    elapsed=$(( elapsed + INTERVAL ))
done
printf '%s cluster ready after %ds.\n' "${TYPE}" "${elapsed}"
