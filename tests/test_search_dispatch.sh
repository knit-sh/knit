#!/usr/bin/env bats

# search-core M7: shared dispatcher support reused by both proposer commands
# (knit sweep, knit ax optimize): the --group label (recorded on the parent row
# and forwarded into a job trial's submit line) and the "Which parameters vary"
# fill resolution (--fill default|sweep + per-parameter @sweep/@default, explicit
# always winning).

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    unset KNIT_JOB_PREFIX KNIT_RUN_ID KNIT_SOURCE_ID KNIT_SOURCE_COMMAND
    _KNIT_RECORDING_SUPPRESSED=""
    _knit_prov_create_table
}

teardown() {
    knit_test_db_teardown
}

# ---------- fill resolution: precedence ----------

@test "an explicit value wins over every policy" {
    local r
    knit_search_resolve_fill r sweep explicit true;  [ "${r}" = "explicit" ]
    knit_search_resolve_fill r default explicit false; [ "${r}" = "explicit" ]
}

@test "@sweep varies regardless of --fill" {
    local r
    knit_search_resolve_fill r default sweep true; [ "${r}" = "sweep" ]
    knit_search_resolve_fill r sweep sweep true;   [ "${r}" = "sweep" ]
}

@test "@default fixes regardless of --fill" {
    local r
    knit_search_resolve_fill r sweep default true;   [ "${r}" = "default" ]
    knit_search_resolve_fill r default default true;  [ "${r}" = "default" ]
}

@test "an unspecified parameter follows --fill when it has a domain" {
    local r
    knit_search_resolve_fill r sweep unspecified true;   [ "${r}" = "sweep" ]
    knit_search_resolve_fill r default unspecified true;  [ "${r}" = "default" ]
}

@test "a parameter with no declared domain stays at its default under either policy" {
    local r
    knit_search_resolve_fill r sweep unspecified false;   [ "${r}" = "default" ]
    knit_search_resolve_fill r default unspecified false;  [ "${r}" = "default" ]
}

@test "fill resolution rejects a bad --fill policy" {
    run knit_search_resolve_fill r bogus unspecified true
    [ "$status" -eq 1 ]
    [[ "$output" == *"--fill"* ]]
}

@test "fill resolution rejects an unknown token classification" {
    run knit_search_resolve_fill r sweep bogus true
    [ "$status" -eq 1 ]
    [[ "$output" == *"token"* ]]
}

# ---------- group forwarding into the downstream line ----------

@test "the group is inserted into a submit line among the submit options" {
    local -a line=( submit --nodes 2 -- montecarlo --samples 1000 )
    knit_search_group_forward line demo
    [ "${line[*]}" = "submit --group demo --nodes 2 -- montecarlo --samples 1000" ]
}

@test "the group is inserted into a prepare line among the submit options" {
    local -a line=( prepare --nodes 2 -- montecarlo --samples 1000 )
    knit_search_group_forward line demo
    [ "${line[*]}" = "prepare --group demo --nodes 2 -- montecarlo --samples 1000" ]
}

@test "a run or bare line is left unchanged (group lives on the parent row only)" {
    local -a runline=( run --procs 4 -- mcrank )
    knit_search_group_forward runline demo
    [ "${runline[*]}" = "run --procs 4 -- mcrank" ]

    local -a bare=( montecarlo --samples 1000 )
    knit_search_group_forward bare demo
    [ "${bare[*]}" = "montecarlo --samples 1000" ]
}

@test "an empty group leaves the submit line unchanged" {
    local -a line=( submit --nodes 2 -- montecarlo )
    knit_search_group_forward line ""
    [ "${line[*]}" = "submit --nodes 2 -- montecarlo" ]
}

# ---------- a realistic dispatcher flow: parse + record + forward ----------

# A fake proposer dispatcher: it declares --group as an ordinary optional
# parameter (so knit auto-records it on the parent row), then forwards that group
# into the submit line it would hand to a trial. Stands in for knit sweep.
_register_campaign() {
    knit_register "campaign" _campaign_fn "A fake search campaign."
    knit_with_table "campaigns"
    knit_with_optional "group:string" "" "Campaign group label."
    _campaign_fn() {
        local g
        g=$(knit_get_parameter "group" "$@") || g=""
        local -a trial=( submit --nodes 2 -- montecarlo --samples 1000 )
        knit_search_group_forward trial "${g}"
        # Capture the line that would reach a (stubbed) submit.
        __campaign_line="${trial[*]}"
    }
    knit_done
}

@test "the group is recorded on the parent row and forwarded to the trial's submit" {
    _register_campaign
    _knit_invoke_command "campaign" --group demo

    # Recorded on the parent row automatically (an optional parameter is its own
    # column), with no search-specific recording code.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT \"group\" FROM campaigns;")" = "demo" ]
    # And forwarded into the submit line the campaign built for the trial.
    [ "${__campaign_line}" = "submit --group demo --nodes 2 -- montecarlo --samples 1000" ]
}

@test "a campaign with no group records none and forwards nothing" {
    _register_campaign
    _knit_invoke_command "campaign"

    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT \"group\" FROM campaigns;")" = "" ]
    [ "${__campaign_line}" = "submit --nodes 2 -- montecarlo --samples 1000" ]
}
