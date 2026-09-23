#!/usr/bin/env bash
# speed-check.sh
#
# Measure the wall time of "source knit.sh" -- the dominant cost of starting any
# knit command -- and fail if it exceeds a threshold. This guards against a
# registration-path regression (e.g. re-eagering a lazily-discovered subtree, or
# reintroducing forks on the load path).
#
# Run by the "Speed" GitHub workflow, and usable locally:
#
#   make                       # build knit.sh first
#   bash maint/speed-check.sh  # measure, gate at 300 ms
#   bash maint/speed-check.sh 250   # custom threshold in ms
#
# Configuration (all optional):
#   $1 or SPEED_THRESHOLD_MS   threshold in ms (default 300)
#   SPEED_ITERS                timed runs (default 50)
#   SPEED_WARMUP               discarded warm-up runs (default 5)
#
# The gate is the MEDIAN of the timed runs, which is robust to the occasional
# slow run on a shared CI runner while still moving on a real regression. Each
# run sources knit.sh in a fresh process (re-sourcing in one process would
# re-register commands and fail), so the measurement includes the same
# per-command process start-up a real invocation pays.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KNIT_SH="${ROOT}/knit.sh"

threshold_ms="${1:-${SPEED_THRESHOLD_MS:-300}}"
iters="${SPEED_ITERS:-50}"
warmup="${SPEED_WARMUP:-5}"

if [[ ! -f "${KNIT_SH}" ]]; then
    echo "speed-check: ${KNIT_SH} not found; run 'make' first." >&2
    exit 2
fi

# Warm the filesystem cache so the first timed run is not an outlier.
for (( i = 0; i < warmup; i++ )); do
    bash -c "source '${KNIT_SH}'" >/dev/null 2>&1
done

times_file="$(mktemp)"
trap 'rm -f "${times_file}"' EXIT

for (( i = 0; i < iters; i++ )); do
    start="$(date +%s.%N)"
    bash -c "source '${KNIT_SH}'" >/dev/null 2>&1
    end="$(date +%s.%N)"
    awk -v s="${start}" -v e="${end}" 'BEGIN { printf "%.3f\n", (e - s) * 1000 }' \
        >> "${times_file}"
done

# min / median / mean / max over the sorted timings.
read -r min median mean max < <(sort -n "${times_file}" | awk '
    { a[NR] = $1; sum += $1 }
    END {
        n = NR
        med = (n % 2) ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2
        printf "%.1f %.1f %.1f %.1f\n", a[1], med, sum / n, a[n]
    }')

printf 'source knit.sh over %d runs: min=%sms median=%sms mean=%sms max=%sms (threshold %sms)\n' \
    "${iters}" "${min}" "${median}" "${mean}" "${max}" "${threshold_ms}"

if awk -v m="${median}" -v t="${threshold_ms}" 'BEGIN { exit !(m > t) }'; then
    echo "::error::source knit.sh median ${median}ms exceeds ${threshold_ms}ms threshold"
    exit 1
fi

echo "OK: median ${median}ms is within the ${threshold_ms}ms threshold"
