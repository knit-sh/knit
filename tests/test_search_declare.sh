#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit
}

# A declared --domain is recorded verbatim (not parsed) at registration time;
# the full parse and type x kind validation happen later, on demand, in the
# parameter-space accessors. These tests cover only the recording and the cheap
# declaration-time checks.

# ---------- storage: the raw descriptor + log flag ----------

@test "an optional parameter records a range domain verbatim" {
    knit_register "sd_range" knit_empty "A command."
    knit_with_optional "layers:integer" "4" "depth" --domain '[2..12]'
    knit_done
    [ "${_KNIT_CMD_sd_range_2_layers_domain}" = "[2..12]" ]
    [ "${_KNIT_CMD_sd_range_2_layers_domain_log}" = "false" ]
}

@test "a range domain with a step is recorded verbatim" {
    knit_register "sd_step" knit_empty "A command."
    knit_with_optional "n:integer" "0" "count" --domain '[0..10:2]'
    knit_done
    [ "${_KNIT_CMD_sd_step_2_n_domain}" = "[0..10:2]" ]
}

@test "a real range records the --log hint" {
    knit_register "sd_log" knit_empty "A command."
    knit_with_optional "lr:real" "0.01" "rate" --domain '[1e-5..1.0]' --log
    knit_done
    [ "${_KNIT_CMD_sd_log_2_lr_domain}" = "[1e-5..1.0]" ]
    [ "${_KNIT_CMD_sd_log_2_lr_domain_log}" = "true" ]
}

@test "a list domain is recorded verbatim" {
    knit_register "sd_list" knit_empty "A command."
    knit_with_optional "batch:integer" "32" "size" --domain '{16,32,64,128}'
    knit_done
    [ "${_KNIT_CMD_sd_list_2_batch_domain}" = "{16,32,64,128}" ]
}

@test "a glob domain is recorded verbatim" {
    knit_register "sd_glob" knit_empty "A command."
    knit_with_optional "input:string" "" "file" --domain '@glob:data/*.txt'
    knit_done
    [ "${_KNIT_CMD_sd_glob_2_input_domain}" = "@glob:data/*.txt" ]
}

@test "a required parameter can carry a domain" {
    knit_register "sd_req" knit_empty "A command."
    knit_with_required "layers:integer" "depth" --domain '[2..12]'
    knit_done
    [ "${_KNIT_CMD_sd_req_2_layers_domain}" = "[2..12]" ]
}

@test "a parameter with no --domain records no domain field" {
    knit_register "sd_none" knit_empty "A command."
    knit_with_optional "plain:string" "x" "a plain parameter"
    knit_done
    [ ! -v _KNIT_CMD_sd_none_2_plain_domain ]
    [ ! -v _KNIT_CMD_sd_none_2_plain_domain_log ]
}

# A type x kind mismatch is NOT caught at declaration (deferred to the accessor);
# the token is still recorded verbatim.
@test "a range on a string parameter is recorded, not rejected, at declaration" {
    knit_register "sd_defer" knit_empty "A command."
    knit_with_optional "name:string" "x" "a name" --domain '[1..9]'
    knit_done
    [ "${_KNIT_CMD_sd_defer_2_name_domain}" = "[1..9]" ]
}

# ---------- declaration-time rejection (cheap checks only) ----------

@test "a non-descriptor token is rejected by the shape check" {
    knit_register "sd_bad1" knit_empty "A command."
    run knit_with_optional "n:integer" "0" "count" --domain 'plain'
    [ "$status" -eq 1 ]
}

@test "an empty braces token is rejected by the shape check" {
    knit_register "sd_bad2" knit_empty "A command."
    run knit_with_optional "n:integer" "0" "count" --domain '{}'
    [ "$status" -eq 1 ]
}

@test "--log without --domain is fatal" {
    knit_register "sd_bad3" knit_empty "A command."
    run knit_with_optional "lr:real" "0.01" "rate" --log
    [ "$status" -eq 1 ]
}

@test "an unknown declaration option is still rejected" {
    knit_register "sd_bad4" knit_empty "A command."
    run knit_with_optional "n:integer" "0" "count" --bogus x
    [ "$status" -eq 1 ]
}

# ---------- domain coexists with --when ----------

@test "a parameter can carry both --when and --domain" {
    knit_register "sd_when" knit_empty "A command."
    knit_with_flag "tune" "enable tuning"
    knit_with_optional "lr:real" "0.01" "rate" --when '.tune == true' --domain '[1e-5..1.0]' --log
    knit_done
    [ "${_KNIT_CMD_sd_when_2_lr_domain}" = "[1e-5..1.0]" ]
    [ "${_KNIT_CMD_sd_when_2_lr_domain_log}" = "true" ]
    [ "${_KNIT_CMD_sd_when_2_lr_when_raw}" = '.tune == true' ]
}
