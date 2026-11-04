#!/bin/bash

# doc-check: source-only
#
# Tutorial snapshot --- PART III, Steps 6-7: a pilot job that drains the prepared
# sweep inside one allocation, written so that resubmitting the SAME pilot
# resumes a sweep a walltime kill cut short (reconcile -> reset -> drain).
#
# Source-only: a pilot starts the knit-pilotd daemon and submits real sub-jobs
# onto an allocation, which needs a scheduler and (to pack) more than one node,
# so check-docs only syntax-checks this file. Behavior is validated live by the
# pilot and job-reconcile integration tests.

source knit.sh

knit_set_program_description "Tune a CNN image classifier: drain a prepared sweep in a pilot."

# START pilot
# @with_pilot marks this job a pilot. Inside its body every `knit submit` --- here
# the ones `submit drain` issues --- targets the in-allocation knit-pilotd daemon
# over the pilot's own nodes, not the machine scheduler, so the prepared sweep
# packs onto this one allocation instead of queueing job by job. The pilot trains
# nothing itself, so it declares no setup; each drained `train` job still carries
# the --setup frozen into it at prepare time.
#
# To actually pack the allocation, the drain runs several jobs at once:
# --max-inflight is sized to the pilot's node count (one single-node `train` per
# node), read with knit_job_hostnames inside the allocation. A plain
# `submit drain` with no --max-inflight releases jobs one at a time, leaving every
# node but one idle.
#
# The body is a pure drainer, written to be re-runnable. Resubmitting the same
# pilot after a walltime kill resumes the sweep in three moves:
#   1. job reconcile --- a hard kill leaves jobs stuck in `running`/`submitting`;
#      reconcile asks the scheduler their true fate and corrects them to `killed`.
#   2. job reset --- move those `killed` jobs back to `prepared` so they re-run.
#   3. submit drain --- drain the still-`prepared` remainder of the sweep, N jobs
#      at a time, where N is the allocation's node count.
# On the first run reconcile and reset find nothing and are no-ops; on a resume
# they recover the interrupted jobs. The sweep's product is prepared once; this
# pilot just chews through it across as many walltime windows as it takes.
@job "sweep-pilot" "Drain a prepared sweep inside one pilot allocation."
@without_setup
@with_pilot
@with_optional "group:string" "grid" "Sweep group to drain."
_sweep_pilot_job() {
    local group nodes
    group="$(knit_get_parameter group "$@")"
    # One single-node `train` job per node: size the drain's concurrency to the
    # pilot's allocation so the whole allocation works at once.
    nodes="$(knit_job_hostnames | wc -l)"
    knit job reconcile --group "${group}"
    knit job reset     --group "${group}"
    knit submit drain  --group "${group}" --max-inflight "${nodes}"
}
@done
# END pilot

knit "$@"
