#!/usr/bin/env bash
# Integration test 28_query_extra.
#
# End-to-end exercise of the cross-platform query lens (`knit query --extra`)
# against a real, bootstrapped knit-graph and a live scheduler:
#
#   - bootstrap on this platform (named "alpha") builds knit-graph, then a job is
#     submitted and runs to completion, recording a jobs row;
#   - a SECOND single-platform database is fabricated beside the first by copying
#     the database and relabelling it as platform "beta" on a different
#     architecture (this stands in for the same experiment having run on another
#     machine, which the test harness cannot provide in one container);
#   - `knit query graph --extra <dir>` runs Cypher over the read-only lens
#     spanning both databases: the synthesized platform node and its "executed"
#     edge tag every row by the platform it ran on, and a `p.arch` filter selects
#     only the matching platform;
#   - `knit query sql --extra` is checked over the same lens (the platforms view
#     spans both databases).
#
# The lens is a read-time union: neither source database is merged or modified.
# This experiment is auto-discovered by the experiments/*/test.sh glob and runs
# under every backend (Slurm, PBS, Flux), so the lens is validated against each
# real scheduler's recorded database.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/28_query_extra/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/28-query-extra-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/28_query_extra/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap this platform as "alpha" and submit a job that runs to completion.
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-28" --platform alpha
SQLITE="${WORKDIR}/.knit/sqlite/bin/sqlite3"
export __ASSERT_SQLITE3="${SQLITE}"

check_exec ".knit/knit-graph/bin/knit-graph" \
    "bootstrap built the knit-graph binary"

alpha_uuid=$(./experiment.sh submit --wait -- work)
check_sqlite ".knit/knit.db" \
    "SELECT state FROM jobs WHERE id='${alpha_uuid}';" "completed" \
    "the alpha job ran to completion"

# --------------------------------------------------------------------------
# Fabricate the second platform's database beside the first: copy alpha's
# database, relabel it as platform "beta" on a different (simulated) arch, and
# give its job row a distinct id (a distinct run on another machine). Only the
# copy is touched; alpha's database is left untouched.
# --------------------------------------------------------------------------
BETA_DIR="${WORKDIR}/beta"
mkdir -p "${BETA_DIR}/.knit"
cp "${WORKDIR}/.knit/knit.db" "${BETA_DIR}/.knit/knit.db"
"${SQLITE}" "${BETA_DIR}/.knit/knit.db" \
    "UPDATE metadata SET value='beta'        WHERE key='__platform__';
     UPDATE metadata SET value='sim-aarch64' WHERE key='__arch__';
     UPDATE jobs      SET id='beta-job';"

# alpha keeps this container's real architecture; beta is the simulated one.
alpha_arch=$("${SQLITE}" "${WORKDIR}/.knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__arch__';")

# graph_lines / sql_lines <cypher-or-sql>: run one --extra query over the lens
# and return its stdout (results go to stdout, logs to stderr; strip any CR).
graph_lines() {
    ./experiment.sh query graph --extra "${BETA_DIR}" --exec "$1" 2>/dev/null \
        | tr -d '\r'
}
sql_lines() {
    ./experiment.sh query sql --extra "${BETA_DIR}" --exec "$1" 2>/dev/null \
        | tr -d '\r'
}

# --------------------------------------------------------------------------
# The platform node is available even WITHOUT --extra: a query over the single
# current database still resolves (p:platform), tagged with this platform.
# --------------------------------------------------------------------------
solo=$(./experiment.sh query graph --exec \
    "MATCH (p:platform)-[:executed]->(j:jobs) RETURN p.id" 2>/dev/null | tr -d '\r')
check_eq "${solo}" "alpha" \
    "query graph resolves (p:platform) without --extra, tagged with this platform"

# --------------------------------------------------------------------------
# The lens spans both databases: the platforms view has both platforms.
# --------------------------------------------------------------------------
platforms=$(sql_lines "SELECT id FROM platforms ORDER BY id;")
check_eq "${platforms}" "$(printf 'alpha\nbeta')" \
    "query sql --extra: the platforms view spans both databases"

# --------------------------------------------------------------------------
# A graph query tags every row by the platform it ran on, through the
# synthesized (p:platform)-[:executed]->(j:jobs) hop.
# --------------------------------------------------------------------------
tagged=$(graph_lines \
    "MATCH (p:platform)-[:executed]->(j:jobs) RETURN p.id ORDER BY p.id")
check_eq "${tagged}" "$(printf 'alpha\nbeta')" \
    "query graph --extra: results carry rows from both platforms"

# --------------------------------------------------------------------------
# A p.arch filter selects only the matching platform (beta is sim-aarch64;
# alpha is this container's real, different architecture).
# --------------------------------------------------------------------------
[[ "${alpha_arch}" != "sim-aarch64" ]] \
    || fail "the container arch collides with the simulated beta arch"

only_beta=$(graph_lines \
    "MATCH (p:platform)-[:executed]->(j:jobs) WHERE p.arch = 'sim-aarch64' RETURN p.id")
check_eq "${only_beta}" "beta" \
    "query graph --extra: a p.arch filter selects only the matching platform"

# The complementary filter selects only alpha (this container's real arch).
only_alpha=$(graph_lines \
    "MATCH (p:platform)-[:executed]->(j:jobs) WHERE p.arch = '${alpha_arch}' RETURN p.id")
check_eq "${only_alpha}" "alpha" \
    "query graph --extra: the complementary p.arch filter selects only alpha"

# --------------------------------------------------------------------------
# The source databases are read-only: neither was modified by the query.
# --------------------------------------------------------------------------
check_sqlite ".knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__platform__';" "alpha" \
    "the current database is unchanged by the lens query"
check_sqlite "${BETA_DIR}/.knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__platform__';" "beta" \
    "the extra database is unchanged by the lens query"

assert_summary
