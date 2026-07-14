#!/usr/bin/env bash
#
# coverage-shard.sh <shard-index> <shard-count>
#
# Print the list of bats test files (one per line) assigned to shard
# <shard-index> (1-based) out of <shard-count> total shards. Files are
# balanced across shards by their number of @test cases using a greedy
# longest-processing-time (LPT) partition: files are sorted by test count
# descending and each is placed in the currently least-loaded shard. This
# keeps the per-shard test count close to even, which matters because the
# coverage matrix's wall-clock is the slowest shard.
#
# The partition is deterministic (stable sort on the test count), so a given
# (file set, shard-count) always yields the same assignment.
#
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <shard-index> <shard-count>" >&2
    exit 2
fi

index=$1
count=$2

if ! [[ "${index}" =~ ^[0-9]+$ && "${count}" =~ ^[0-9]+$ ]] \
    || (( index < 1 || count < 1 || index > count )); then
    echo "error: invalid shard index/count: ${index}/${count}" >&2
    exit 2
fi

# Change to the repository root so the tests/ glob is stable regardless of the
# caller's working directory.
cd "$(dirname "$0")/.."

# Collect "<test-count>\t<path>" for every test file, sorted by count
# descending (stable, so ties keep glob/alphabetical order -> deterministic).
mapfile -t sorted < <(
    for f in tests/test_*.sh; do
        n=$(grep -c '^@test' "${f}" || true)
        printf '%s\t%s\n' "${n}" "${f}"
    done | sort -s -rn -k1,1
)

# Greedy LPT assignment.
declare -a load assigned
for (( i = 0; i < count; i++ )); do
    load[i]=0
    assigned[i]=""
done

for line in "${sorted[@]}"; do
    n=${line%%$'\t'*}
    f=${line#*$'\t'}
    min=0
    for (( i = 1; i < count; i++ )); do
        if (( load[i] < load[min] )); then
            min=$i
        fi
    done
    load[min]=$(( load[min] + n ))
    assigned[min]+="${f}"$'\n'
done

# Emit this shard's files (printf %s keeps the trailing newline count exact;
# an empty shard prints nothing).
printf '%s' "${assigned[$(( index - 1 ))]}"
