#!/usr/bin/env bash
# Integration test 08_job_hostnames.
#
# Verifies knit_job_hostnames against a real scheduler allocation:
#   - submit --nodes 2 --wait runs the "hosts" job on two compute nodes
#   - the job body prints knit_job_hostnames in four forms (default / --separator
#     / --json / --raw), each inside "=== <name> ===" markers, captured to
#     <jobdir>/.stdout
#   - the default form lists both allocated compute nodes, once each
#   - --separator and --json render that same deduplicated list
#   - --raw carries the backend's verbatim hostfile entries (>= the deduplicated
#     count), whose unique hostnames match the default list
#   - the job's row in the "jobs" table records the deduplicated hostnames,
#     comma-separated, written compute-side when the job started
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/08_job_hostnames/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/08-job-hostnames-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/08_job_hostnames/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap + setup
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-08"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

./experiment.sh setup --name env -- env
check_file "setups/env/.activate.sh" "setup produced .activate.sh"

# --------------------------------------------------------------------------
# Detect the scheduler so assertions match the backend knit auto-detects.
# --------------------------------------------------------------------------
if command -v sbatch >/dev/null 2>&1; then
    NODE_PREFIX="slurm-compute"
elif command -v qsub >/dev/null 2>&1; then
    NODE_PREFIX="pbs-compute"
elif command -v flux >/dev/null 2>&1; then
    NODE_PREFIX="flux-compute"
else
    fail "no supported scheduler (sbatch/qsub/flux) found on the login node"
fi

# --------------------------------------------------------------------------
# Submit across two nodes and block until completion.
# --------------------------------------------------------------------------
uuid=$(./experiment.sh submit --setup env --nodes 2 --wait -- hosts)

jobdir=$(find "${WORKDIR}/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
[[ -n "${jobdir}" ]] || fail "no job directory created under jobs"
check_eq "${uuid}" "$(basename "${jobdir}")" \
    "submit prints the job UUID (the job directory name)"

# --wait blocks until completion, but guard against output-flush lag.
for _ in $(seq 1 30); do
    [[ -s "${jobdir}/.stdout" ]] && grep -q '=== end ===' "${jobdir}/.stdout" \
        && break
    sleep 1
done

check_file "${jobdir}/.stdout" "job stdout captured"
check_sqlite ".knit/knit.db" \
    "SELECT state FROM jobs WHERE id='${uuid}';" \
    "completed" \
    "jobs row advanced to completed after the --wait job finished"

# --------------------------------------------------------------------------
# Extract the lines of one "=== <name> ===" section from the job stdout.
# --------------------------------------------------------------------------
section() {
    awk -v want="$1" '
        /^=== / {
            cur = $0
            sub(/^=== /, "", cur)
            sub(/ ===$/, "", cur)
            insec = (cur == want)
            next
        }
        insec { print }
    ' "${jobdir}/.stdout"
}

# --------------------------------------------------------------------------
# default form: both compute nodes, deduplicated, one per line.
# --------------------------------------------------------------------------
mapfile -t defaults < <(section default)
check_eq "${#defaults[@]}" "2" "default form lists two allocated nodes"

for h in "${defaults[@]}"; do
    case "${h}" in
        "${NODE_PREFIX}"*) ;;
        *) fail "default host \"${h}\" is not a ${NODE_PREFIX} node" ;;
    esac
done

distinct=$(printf '%s\n' "${defaults[@]}" | sort -u | wc -l)
check_eq "${distinct}" "2" "default form's two nodes are distinct"

# --------------------------------------------------------------------------
# --separator renders the same deduplicated list joined by the separator.
# --------------------------------------------------------------------------
csv=$(section csv)
expected_csv=$(IFS='|'; printf '%s' "${defaults[*]}")
check_eq "${csv}" "${expected_csv}" "--separator joins the deduplicated hosts"

# --------------------------------------------------------------------------
# --json renders the same list as a JSON array of strings.
# --------------------------------------------------------------------------
json=$(section json)
expected_json="[\"${defaults[0]}\",\"${defaults[1]}\"]"
check_eq "${json}" "${expected_json}" "--json is the array of deduplicated hosts"

# --------------------------------------------------------------------------
# --raw carries the verbatim hostfile entries: at least as many as the
# deduplicated list, all on compute nodes, and the same unique set.
# --------------------------------------------------------------------------
mapfile -t raws < <(section raw)
[[ "${#raws[@]}" -ge "${#defaults[@]}" ]] \
    || fail "raw form has fewer lines (${#raws[@]}) than the deduplicated list (${#defaults[@]})"
__assert_pass "raw form has at least as many entries as the deduplicated list"

for r in "${raws[@]}"; do
    base="${r%%:*}"
    base="${base%% *}"
    case "${base}" in
        "${NODE_PREFIX}"*) ;;
        *) fail "raw host \"${r}\" is not a ${NODE_PREFIX} node" ;;
    esac
done

raw_unique=$(printf '%s\n' "${raws[@]}" | sed 's/[: ].*$//' | sort -u)
def_unique=$(printf '%s\n' "${defaults[@]}" | sort -u)
check_eq "${raw_unique}" "${def_unique}" \
    "raw form's unique hosts match the deduplicated list"

# --------------------------------------------------------------------------
# --select 1:1 prints exactly the second host of the deduplicated list.
# --------------------------------------------------------------------------
mapfile -t selected < <(section select)
check_eq "${#selected[@]}" "1" "--select 1:1 prints exactly one host"
check_eq "${selected[0]}" "${defaults[1]}" \
    "--select 1:1 prints the second deduplicated host"

# --------------------------------------------------------------------------
# The job's row records the allocated nodes: hostnames is the deduplicated
# host list joined by commas (recorded compute-side when the job started).
# --------------------------------------------------------------------------
expected_hostnames=$(IFS=','; printf '%s' "${defaults[*]}")
check_sqlite ".knit/knit.db" \
    "SELECT hostnames FROM jobs WHERE id='${uuid}';" \
    "${expected_hostnames}" \
    "jobs row records the comma-separated deduplicated hostnames"

assert_summary
