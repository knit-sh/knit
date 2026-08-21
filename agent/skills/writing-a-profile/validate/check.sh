#!/usr/bin/env bash
# Check rank placement from a completed knit "validate" job.
#
# Usage: check.sh <job-uuid> [expected-procs] [expected-nodes]
#        (defaults: procs=4, nodes=2)
#
# Reads jobs/<job-uuid>/.stdout -- the per-rank lines the hello app produced --
# and asserts the placement a correct profile must deliver:
#
#   * exactly <procs> rank lines
#   * ranks distinct and covering 0..procs-1
#   * every rank agrees the MPI world size == procs
#   * ranks spread across <nodes> distinct hosts
#
# Prints PASS/FAIL per check and exits non-zero if any check fails, so the skill
# can treat a profile as validated only on a clean exit.
set -uo pipefail

uuid="${1:?usage: check.sh <job-uuid> [expected-procs] [expected-nodes]}"
want_procs="${2:-4}"
want_nodes="${3:-2}"

stdout="jobs/${uuid}/.stdout"

fail=0
pass() { printf 'PASS  %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; fail=1; }

# Give the captured stdout a moment to flush all rank lines.
for _ in $(seq 1 30); do
    if [[ -f "${stdout}" ]] &&
       [[ "$(grep -c '^RANK=' "${stdout}" 2>/dev/null || true)" -ge "${want_procs}" ]]; then
        break
    fi
    sleep 1
done

if [[ ! -f "${stdout}" ]]; then
    bad "job stdout ${stdout} not found (did the job run with --wait?)"
    exit 1
fi

# Extract one field (RANK / SIZE / HOST) from every rank line.
field() { sed -n 's/.*\b'"$2"'=\([^ ]*\).*/\1/p' "$1"; }

mapfile -t ranks < <(field "${stdout}" RANK | sort -n)
if [[ "${#ranks[@]}" -eq "${want_procs}" ]]; then
    pass "produced ${want_procs} rank lines"
else
    bad "expected ${want_procs} rank lines, got ${#ranks[@]}"
fi

want_seq="$(seq 0 $((want_procs - 1)) | tr '\n' ' ' | sed 's/ $//')"
got_seq="$(printf '%s\n' "${ranks[@]}" | tr '\n' ' ' | sed 's/ $//')"
if [[ "${got_seq}" == "${want_seq}" ]]; then
    pass "ranks distinct and cover [0,${want_procs})"
else
    bad "ranks not distinct/complete: got [${got_seq}], want [${want_seq}]"
fi

mapfile -t sizes < <(field "${stdout}" SIZE | sort -u)
if [[ "${#sizes[@]}" -eq 1 && "${sizes[0]}" == "${want_procs}" ]]; then
    pass "every rank agrees world size == ${want_procs}"
else
    bad "world size disagreement or wrong value: [${sizes[*]}]"
fi

# Strip any domain suffix so short and FQDN host forms compare equal.
mapfile -t hosts < <(field "${stdout}" HOST | sed 's/\..*//' | sort -u)
if [[ "${#hosts[@]}" -eq "${want_nodes}" ]]; then
    pass "ranks spread across ${want_nodes} node(s): ${hosts[*]}"
else
    bad "expected ${want_nodes} distinct host(s), got ${#hosts[@]}: ${hosts[*]}"
fi

if [[ "${fail}" -eq 0 ]]; then
    printf '\nProfile validation PASSED: build, submit, launch, and placement all correct.\n'
else
    printf '\nProfile validation FAILED: see the FAIL lines above.\n'
fi
exit "${fail}"
