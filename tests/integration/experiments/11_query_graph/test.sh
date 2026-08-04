#!/usr/bin/env bash
# Integration test 11_query_graph.
#
# End-to-end exercise of `knit query` against a real, bootstrapped knit-graph:
#   - bootstrap builds knit-graph from its pinned release against the private,
#     from-source sqlite (real install with headers + libsqlite3);
#   - a setup is built and a job submitted with --setup (records a "used_by"
#     edge); the job body launches "step" twice under `knit_as` aliases
#     (records two "call" edges carrying an alias);
#   - `knit query graph --exec` runs real Cypher over the provenance, resolving
#     command-name <-> table-name labels through the live --names map (e.g. the
#     "submit" command owning the "jobs" table), traversing the "used_by" edge,
#     and telling the two aliased calls apart (both the inline property-map and
#     the WHERE spellings);
#   - `knit query sql --exec` and `knit query catalog` are smoke-tested against
#     the same DB.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/11_query_graph/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/11-query-graph-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/11_query_graph/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap. This builds knit-graph from its pinned release against the
# private from-source sqlite install (headers + libsqlite3).
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-11"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

check_exec ".knit/knit-graph/bin/knit-graph" \
    "bootstrap built the knit-graph binary"

# --------------------------------------------------------------------------
# Build the setup, then submit a job that consumes it. --wait blocks until the
# job has run to completion on a compute node.
# --------------------------------------------------------------------------
./experiment.sh setup --name envdir -- env
check_file "setups/envdir/.activate.sh" "setup produced .activate.sh"
check_file "setups/envdir/.setup.id" "setup recorded its row id in .setup.id"

uuid=$(./experiment.sh submit --setup envdir --wait -- analyze)

jobdir=$(find "${WORKDIR}/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
[[ -n "${jobdir}" ]] || fail "no job directory created under jobs"
check_eq "${uuid}" "$(basename "${jobdir}")" \
    "submit prints the job UUID (the job directory name)"

# --wait blocks until completion, but guard against output-flush lag.
for _ in $(seq 1 30); do
    [[ -s "${jobdir}/.stdout" ]] && break
    sleep 1
done

check_grep "analyze marker: env-built" "${jobdir}/.stdout" \
    "job body ran and inherited the setup's exported marker"

# --------------------------------------------------------------------------
# The recorded shape we will query:
#   used_by : (setup env) -> (submission = jobs.id, name submit:analyze)
#   call    : (jobs.id, submit) -> (body_id, submit:analyze)
#   call    : (body_id, submit:analyze) -> (step_id, step)  alias fast/slow
# --------------------------------------------------------------------------
setup_id=$(cat "${WORKDIR}/setups/envdir/.setup.id")

# graph_scalar <cypher>: run one query and normalise the single scalar result
# (knit query graph writes results to stdout, logs to stderr; strip any CR).
graph_scalar() {
    ./experiment.sh query graph --exec "$1" 2>/dev/null | tr -d '\r'
}

# 1. Name map through the override table: the "submit" *command* resolves to the
#    "jobs" table (and its edges' name "submit"); crossing the call edge to the
#    "analyze" body table returns the job name recorded on the submission.
check_eq "$(graph_scalar 'MATCH (j:submit)-[:call]->(a:analyze) RETURN j.job')" \
    "analyze" \
    "query resolves the submit->jobs name map and crosses to the body"

# 2. used_by edge: reach the submission from the setup and return the setup id.
#    The target keeps its recorded name (submit:analyze) but its columns are not
#    projected, so only the name predicate applies (no id join to the body).
# shellcheck disable=SC2016 # backticks are literal Cypher label quotes, not command substitution
check_eq "$(graph_scalar 'MATCH (s:`setup:env`)-[:used_by]->(a:analyze) RETURN s.id')" \
    "${setup_id}" \
    "query traverses the used_by edge from the setup to the job"

# 3. knit_as alias, inline relationship-property spelling (knit-graph lowers the
#    inline {alias:'...'} map to the same predicate as the WHERE form).
check_eq "$(graph_scalar "MATCH (a:analyze)-[{alias:'fast'}]->(st:step) RETURN st.label")" \
    "quick" \
    "query selects the 'fast' aliased call via an inline property map"

# 4. knit_as alias, WHERE spelling.
check_eq "$(graph_scalar "MATCH (a:analyze)-[e]->(st:step) WHERE e.alias = 'slow' RETURN st.label")" \
    "thorough" \
    "query selects the 'slow' aliased call via a WHERE clause"

# --------------------------------------------------------------------------
# knit query sql: read-only SQL over the same DB (knit's own read path).
# --------------------------------------------------------------------------
sql_out=$(./experiment.sh query sql --exec "SELECT job FROM jobs WHERE id='${uuid}';" \
    2>/dev/null | tr -d '\r')
check_eq "${sql_out}" "analyze" \
    "knit query sql reads the submission row from the jobs table"

# --------------------------------------------------------------------------
# knit query catalog: knit-graph introspects the real DB schema and knit
# annotates the jobs table with its owning command.
# --------------------------------------------------------------------------
./experiment.sh query catalog > "${WORKDIR}/catalog.out" 2>/dev/null \
    || fail "knit query catalog exited non-zero"
check_grep "jobs" "${WORKDIR}/catalog.out" \
    "knit query catalog lists the jobs table"
check_grep "command: submit" "${WORKDIR}/catalog.out" \
    "knit query catalog annotates jobs with its owning command"

assert_summary
