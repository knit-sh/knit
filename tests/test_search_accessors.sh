#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit
    _KNIT_JQ_EXE="jq"
}

# ---------- knit_parameter_type ----------

@test "knit_parameter_type reads a declared type" {
    knit_register "pa_type" knit_empty "A command."
    knit_with_optional "n:integer" "0" "count"
    knit_done
    local t
    knit_parameter_type t "pa_type" "n"
    [ "$t" = "integer" ]
}

@test "knit_parameter_type normalizes the parameter name" {
    knit_register "pa_norm" knit_empty "A command."
    knit_with_optional "batch-size:integer" "0" "size"
    knit_done
    local t
    knit_parameter_type t "pa_norm" "batch-size"
    [ "$t" = "integer" ]
    knit_parameter_type t "pa_norm" "batch_size"
    [ "$t" = "integer" ]
}

@test "knit_parameter_type returns 1 for an unknown parameter" {
    knit_register "pa_unk" knit_empty "A command."
    knit_done
    local t
    run knit_parameter_type t "pa_unk" "nope"
    [ "$status" -eq 1 ]
}

# ---------- knit_command_parameters ----------

@test "knit_command_parameters lists required, optional, then flags in order" {
    knit_register "pa_list" knit_empty "A command."
    knit_with_required "a:integer" "first"
    knit_with_optional "b:string" "x" "second"
    knit_with_flag "c" "third"
    knit_done
    local params
    knit_command_parameters params "pa_list"
    [ "${#params[@]}" -eq 3 ]
    [ "${params[0]}" = "a" ]
    [ "${params[1]}" = "b" ]
    [ "${params[2]}" = "c" ]
}

@test "knit_command_parameters is empty for a command with no parameters" {
    knit_register "pa_empty" knit_empty "A command."
    knit_done
    local params
    knit_command_parameters params "pa_empty"
    [ "${#params[@]}" -eq 0 ]
}

# ---------- knit_parameter_space: structured read ----------

@test "read a range domain structured" {
    knit_register "pa_range" knit_empty "A command."
    knit_with_optional "layers:integer" "4" "depth" --domain '[2..12:2]'
    knit_done
    local kind type lo hi values step log glob
    knit_parameter_space kind type lo hi values step log glob "pa_range" "layers"
    [ "$kind" = "range" ]
    [ "$type" = "integer" ]
    [ "$lo" = "2" ]
    [ "$hi" = "12" ]
    [ "$step" = "2" ]
    [ "$log" = "false" ]
    [ "${#values[@]}" -eq 0 ]
}

@test "read a real range with the log hint" {
    knit_register "pa_real" knit_empty "A command."
    knit_with_optional "lr:real" "0.01" "rate" --domain '[1e-5..1.0]' --log
    knit_done
    local kind type lo hi values step log glob
    knit_parameter_space kind type lo hi values step log glob "pa_real" "lr"
    [ "$kind" = "range" ]
    [ "$type" = "real" ]
    [ "$lo" = "1e-5" ]
    [ "$hi" = "1.0" ]
    [ "$log" = "true" ]
}

@test "read a list domain structured" {
    knit_register "pa_listd" knit_empty "A command."
    knit_with_optional "batch:integer" "32" "size" --domain '{16,32,64,128}'
    knit_done
    local kind type lo hi values step log glob
    knit_parameter_space kind type lo hi values step log glob "pa_listd" "batch"
    [ "$kind" = "list" ]
    [ "${#values[@]}" -eq 4 ]
    [ "${values[0]}" = "16" ]
    [ "${values[3]}" = "128" ]
}

@test "read a glob domain structured" {
    knit_register "pa_glob" knit_empty "A command."
    knit_with_optional "input:string" "" "file" --domain '@glob:data/*.txt'
    knit_done
    local kind type lo hi values step log glob
    knit_parameter_space kind type lo hi values step log glob "pa_glob" "input"
    [ "$kind" = "glob" ]
    [ "$type" = "string" ]
    [ "$glob" = "data/*.txt" ]
}

@test "a parameter with no domain returns status 1 and clears outputs" {
    knit_register "pa_nospace" knit_empty "A command."
    knit_with_optional "plain:string" "x" "no domain"
    knit_done
    local kind type lo hi values step log glob
    kind="stale"
    run knit_parameter_space kind type lo hi values step log glob "pa_nospace" "plain"
    [ "$status" -eq 1 ]
    # In-process (not via run) so the nameref clears are observable:
    knit_parameter_space kind type lo hi values step log glob "pa_nospace" "plain" || true
    [ "$kind" = "" ]
}

# ---------- knit_parameter_space: deferred validation surfaces here ----------

@test "an invalid declared domain is caught on read, not at declaration" {
    knit_register "pa_bad" knit_empty "A command."
    # Recorded verbatim at declaration (a range on a string parameter):
    knit_with_optional "name:string" "x" "a name" --domain '[1..9]'
    knit_done
    local kind type lo hi values step log glob
    run knit_parameter_space kind type lo hi values step log glob "pa_bad" "name"
    [ "$status" -eq 1 ]
}

# ---------- knit_parameter_space_json ----------

@test "json read of a range domain" {
    knit_test_require_jq
    knit_register "pj_range" knit_empty "A command."
    knit_with_optional "lr:real" "0.01" "rate" --domain '[1e-5..1.0]' --log
    knit_done
    local out
    out="$(knit_parameter_space_json "pj_range" "lr")"
    [ "$(jq -r '.kind' <<<"$out")" = "range" ]
    [ "$(jq -r '.type' <<<"$out")" = "real" ]
    [ "$(jq -r '.lo' <<<"$out")" = "1e-5" ]
    [ "$(jq -r '.log' <<<"$out")" = "true" ]
    [ "$(jq -r '.values | length' <<<"$out")" = "0" ]
}

@test "json read of a list domain" {
    knit_test_require_jq
    knit_register "pj_list" knit_empty "A command."
    knit_with_optional "batch:integer" "32" "size" --domain '{16,32,64}'
    knit_done
    local out
    out="$(knit_parameter_space_json "pj_list" "batch")"
    [ "$(jq -r '.kind' <<<"$out")" = "list" ]
    [ "$(jq -r '.values | join(",")' <<<"$out")" = "16,32,64" ]
}

@test "json read of a parameter with no domain is null" {
    knit_test_require_jq
    knit_register "pj_none" knit_empty "A command."
    knit_with_optional "plain:string" "x" "no domain"
    knit_done
    local out
    out="$(knit_parameter_space_json "pj_none" "plain")"
    [ "$out" = "null" ]
}

# ---------- knit_search_parse_token ----------

@test "knit_search_parse_token parses a list token" {
    local -A desc
    local -a vals
    knit_search_parse_token desc vals '{a,b,c}'
    [ "${desc[kind]}" = "list" ]
    [ "${#vals[@]}" -eq 3 ]
    [ "${vals[0]}" = "a" ]
    [ "${vals[2]}" = "c" ]
}

@test "knit_search_parse_token parses a range token" {
    local -A desc
    local -a vals
    knit_search_parse_token desc vals '[1..10:2]'
    [ "${desc[kind]}" = "range" ]
    [ "${desc[lo]}" = "1" ]
    [ "${desc[hi]}" = "10" ]
    [ "${desc[step]}" = "2" ]
}

@test "knit_search_parse_token parses a range without step" {
    local -A desc
    local -a vals
    knit_search_parse_token desc vals '[0.1..1.0]'
    [ "${desc[kind]}" = "range" ]
    [ "${desc[lo]}" = "0.1" ]
    [ "${desc[hi]}" = "1.0" ]
    [ "${desc[step]}" = "" ]
}

@test "knit_search_parse_token parses a glob token" {
    local -A desc
    local -a vals
    knit_search_parse_token desc vals '@glob:data/*.txt'
    [ "${desc[kind]}" = "glob" ]
    [ "${desc[glob]}" = "data/*.txt" ]
}

@test "knit_search_parse_token fatals on an unknown token" {
    local -A desc
    local -a vals
    run knit_search_parse_token desc vals 'notatoken'
    [ "$status" -ne 0 ]
}

# ---------- knit_search_resolve_target ----------

@test "knit_search_resolve_target resolves a submit downstream" {
    knit_register "submit__1__myjob" knit_empty "A job."
    knit_done
    local m d t
    knit_search_resolve_target m d t submit -- myjob --n 4
    [ "$m" = "submit__1__myjob" ]
    [ "$d" = "submit" ]
    [ "$t" = "myjob" ]
}

@test "knit_search_resolve_target resolves a run downstream" {
    knit_register "run__1__myapp" knit_empty "An app."
    knit_done
    local m d t
    knit_search_resolve_target m d t run -- myapp --procs 4
    [ "$m" = "run__1__myapp" ]
    [ "$d" = "run" ]
    [ "$t" = "myapp" ]
}

@test "knit_search_resolve_target resolves a bare command" {
    knit_register "mybare" knit_empty "A command."
    knit_done
    local m d t
    knit_search_resolve_target m d t mybare --x 1
    [ "$m" = "mybare" ]
    [ "$d" = "mybare" ]
    [ "$t" = "mybare" ]
}

@test "knit_search_resolve_target is empty for submit with no inner --" {
    local m d t
    knit_search_resolve_target m d t submit --nodes 4
    [ "$m" = "" ]
    [ "$d" = "submit" ]
    [ "$t" = "" ]
}

# ---------- knit_output_type ----------

@test "knit_output_type reads a declared output type" {
    knit_register "ot_cmd" knit_empty "A command."
    knit_with_output "val-loss:real" "" "the loss"
    knit_done
    local t
    knit_output_type t "ot_cmd" "val_loss"
    [ "$t" = "real" ]
}

@test "knit_output_type normalizes hyphens and underscores" {
    knit_register "ot_norm" knit_empty "A command."
    knit_with_output "best-acc:real" "" "accuracy"
    knit_done
    local t
    knit_output_type t "ot_norm" "best-acc"
    [ "$t" = "real" ]
    knit_output_type t "ot_norm" "best_acc"
    [ "$t" = "real" ]
}

@test "knit_output_type returns 1 for an unknown output" {
    knit_register "ot_unk" knit_empty "A command."
    knit_done
    local t
    run knit_output_type t "ot_unk" "nope"
    [ "$status" -eq 1 ]
}
