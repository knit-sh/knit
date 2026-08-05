#!/usr/bin/env bash
# Integration test experiment 11_query_graph.
#
# A minimal experiment whose provenance graph exercises every piece `knit query
# graph` needs to navigate end-to-end:
#
#   - a setup "env" consumed by a job via --setup, producing a "used_by" edge
#     (setup -> submission);
#   - a job "analyze" whose body launches the same command twice under distinct
#     `knit_as` aliases ("fast"/"slow"), so the two "call" edges to "step" carry
#     an alias property to tell them apart;
#   - the jobs/body table split (submit -> submit:analyze) and the command-name
#     <-> table-name map (the "submit" command owns the "jobs" table), which the
#     query resolves through knit query graph's live --names spec.
#
# The companion test.sh bootstraps (building knit-graph against the private
# sqlite), submits the job, then runs real Cypher queries against the recorded
# provenance.

source knit.sh

knit_set_program_description "knit query graph end-to-end integration test experiment."

# A setup consumed by the job (--setup), so a "used_by" edge is recorded.
knit_register_setup "env" __env_setup_fn "Prepare a trivial environment."
__env_setup_fn() {
    # Exported so it is captured into <setup>/.activate.sh and visible to the job.
    export ANALYZE_MARKER="env-built"
}
knit_done

# A plain recorded command the job body invokes twice, under distinct aliases.
# Each invocation records one row in the "step" table and one "call" edge.
knit_register __step_fn "step" "Record one labelled step."
knit_with_required "label:string" "A label identifying this step."
knit_with_table
__step_fn() {
    printf 'step: %s\n' "$(knit_get_parameter "label" "$@")"
}
knit_done

# A job whose body launches "step" twice under `knit_as` aliases, so the two
# call edges can be told apart by their alias in a query.
knit_register_job "analyze" __analyze_job_fn "Run two aliased steps."
__analyze_job_fn() {
    printf 'analyze marker: %s\n' "${ANALYZE_MARKER}"
    knit_as fast step --label quick
    knit_as slow step --label thorough
}
knit_done

knit "$@"
