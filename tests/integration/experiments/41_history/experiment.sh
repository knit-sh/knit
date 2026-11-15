#!/usr/bin/env bash
# Integration test experiment 41_history.
#
# Exercises `knit history show` end to end on a real scheduler. The point is to
# confirm that the history records exactly the top-level commands the *user*
# invoked and nothing the work spun off:
#
#   - a setup "env" (built on the login node);
#   - a plain command "note";
#   - a job "greetjob" submitted with `knit submit --wait`.
#
# The job runs on a compute node in a separate process, with the submitter's
# provenance context carried across the scheduler boundary (KNIT_SOURCE_ID), so
# the job body is a *non-root* invocation and must NOT appear in the history --
# only the login-side `submit` does. Likewise the dispatched `setup:env` body
# runs in-process under the `setup` dispatcher and is excluded.
#
# The driver (test.sh) runs the session, asserts the recorded __history__ rows
# are exactly setup/note/submit in order, and replays the `--format bash` output.

source knit.sh

knit_set_program_description "history show integration test experiment."

knit_register_setup "env" __env_setup_fn "Prepare a trivial environment."
__env_setup_fn() {
    knit_setup_env_set GREETING "hello-from-setup"
}
knit_done

# A plain top-level command: a root invocation recorded in the history.
knit_register "note" __note_fn "Record a short note."
knit_with_optional "text:string" "hi" "The note text."
__note_fn() {
    printf 'note: %s\n' "$(knit_get_parameter "text" "$@")"
}
knit_done

# A job whose compute-side body is a non-root invocation (it carries the
# submitter's KNIT_SOURCE_ID), so it must be absent from the history.
knit_register_job "greetjob" __greetjob_fn "Print the setup greeting from a job."
__greetjob_fn() {
    printf 'job says: %s\n' "${GREETING}"
}
knit_done

knit "$@"
