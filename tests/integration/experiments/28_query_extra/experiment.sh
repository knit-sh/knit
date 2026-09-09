#!/usr/bin/env bash
# Integration test experiment 28_query_extra.
#
# A minimal experiment for the cross-platform query lens. It declares one job
# whose submission records a row in the framework "jobs" table; every recorded
# row is one "executed" hop from its platform node in the lens. The companion
# test.sh bootstraps this on one platform (alpha), fabricates a second
# single-platform database beside it (beta, on a different architecture), and
# runs `knit query graph --extra` and `knit query sql --extra` across both.

source knit.sh

knit_set_program_description "cross-platform query (--extra) integration test experiment."

# A trivial job. knit_register_job backs it with a table named after it, and its
# submission records a row in the "jobs" table, so no knit_with_table is needed.
knit_register_job "work" __work_fn "A trivial job that records a row."
__work_fn() {
    printf 'work done\n'
}
knit_done

knit "$@"
