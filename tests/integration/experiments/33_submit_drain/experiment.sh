#!/usr/bin/env bash
# Integration test experiment 33_submit_drain.
#
# Registers two self-contained jobs (no setup) used to exercise `submit drain`
# against the real cluster scheduler:
#   - "sim" only does arithmetic and records a result, so it runs fast anywhere.
#   - "flaky" returns a non-zero exit code when --mode fail, so its jobs row lands
#     in the "failed" lifecycle state — the signal `submit drain --stop-on-failure`
#     acts on (submit --wait does not report a body's non-zero exit; the state
#     does, via the compute-side after-callback).

source knit.sh

knit_set_program_description "submit drain integration test experiment."

knit_register_job "sim" __sim_job_fn "Run one trivial simulation."
knit_without_setup
knit_with_optional "n:integer"      "1"  "Number of steps to run."
knit_with_table
knit_with_output   "result:integer" "0"  "Twice the step count (a stand-in result)."
__sim_job_fn() {
    local n
    n=$(knit_get_parameter "n" "$@")
    knit_output "result" "$(( n * 2 ))"
    printf 'sim: n=%s result=%s\n' "${n}" "$(( n * 2 ))"
}
knit_done

knit_register_job "flaky" __flaky_job_fn "Succeed, or fail when --mode fail."
knit_without_setup
knit_with_optional "mode:string" "ok" "ok = succeed; fail = return a non-zero exit code."
__flaky_job_fn() {
    local mode
    mode=$(knit_get_parameter "mode" "$@")
    printf 'flaky: mode=%s\n' "${mode}"
    [[ "${mode}" == "fail" ]] && return 7
    return 0
}
knit_done

knit "$@"
