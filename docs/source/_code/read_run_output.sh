#!/bin/bash

# Read an app's recorded output back in the job body that launched it.
#
# `knit run` records the app's row in the app's own table and leaves two handles
# in the job body's shell: KNIT_LAST_RUN_UUID / KNIT_LAST_RUN_TABLE name that
# per-app row, so the body reads the metric with one direct lookup instead of
# parsing the app's stdout or walking the provenance graph. The generic
# KNIT_LAST_COMMAND_UUID / KNIT_LAST_COMMAND_TABLE name the last row any command
# recorded in this process --- after `knit run`, the "runs" row.
#
# Runnable in plain CI: the app is a shell stand-in launched with `--launcher
# none` (one local rank, no MPI), so no launcher or compiler is needed.

source knit.sh

knit_set_program_description "Read an app's recorded output via the run handle."

# START app
@app "train" "Train a model (a shell stand-in that records a metric)."
@with_optional "epochs:integer" "1" "Epochs to train."
@with_output   "accuracy:real" "Validation accuracy recorded by rank 0." --unset "0"
_train_app() {
    local epochs
    epochs=$(knit_get_parameter "epochs" "$@")

    # A real app would train across the launcher's ranks here. This stand-in just
    # records a deterministic metric so the example runs anywhere. Knit records
    # outputs from rank 0 only, so this writes one row however many ranks ran.
    local accuracy="0.9"
    printf 'trained for %s epoch(s): accuracy=%s\n' "${epochs}" "${accuracy}"
    knit_output "accuracy" "${accuracy}"
}
@done
# END app

# START job
@job "evaluate" "Launch the train app, then read back what it recorded."
_evaluate_job() {
    # Launch the app. One local rank is enough for this example; a real job would
    # derive --procs from its allocation (see "Launch an app from a job").
    knit run --launcher none --procs 1 --procs-per-node 1 -- train --epochs 3

    # KNIT_LAST_RUN_UUID / KNIT_LAST_RUN_TABLE name the row the app just recorded,
    # in the app's own table, so a single query reads the metric back.
    local accuracy
    accuracy=$(knit query sql --exec \
        "SELECT accuracy FROM ${KNIT_LAST_RUN_TABLE} WHERE id='${KNIT_LAST_RUN_UUID}'")
    printf 'the train app recorded accuracy=%s\n' "${accuracy}"

    # The generic handle names the dispatcher's own row instead: after knit run
    # that is the "runs" row (the launch itself), in the "runs" table.
    printf 'the launch is %s row %s\n' \
        "${KNIT_LAST_COMMAND_TABLE}" "${KNIT_LAST_COMMAND_UUID}"
}
@done
# END job

knit "$@"
