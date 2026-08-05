#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    # A small tree of top-level commands exercising the hide paths:
    #   hih_plain    always shown
    #   hih_dyn      dynamically hidden (predicate returns 0)
    #   hih_show     dynamic predicate returns non-zero -> shown
    #   hih_static   statically hidden via knit_hidden
    knit_register knit_empty "hih_plain" "A plain command."
    knit_done
    knit_register knit_empty "hih_dyn" "A dynamically hidden command."
    knit_hidden_if _hih_yes
    knit_done
    knit_register knit_empty "hih_show" "A shown command."
    knit_hidden_if _hih_no
    knit_done
    knit_register knit_empty "hih_static" "A statically hidden command."
    knit_hidden
    knit_done
}

teardown() {
    knit_test_db_teardown
}

_hih_yes() { return 0; }
_hih_no() { return 1; }

@test "root --help lists a plain command and a shown (predicate-false) command" {
    run _knit_print_command_usage "__main__"
    [ "$status" -eq 0 ]
    [[ "$output" == *"hih_plain"* ]]
    [[ "$output" == *"hih_show"* ]]
}

@test "root --help omits a dynamically hidden command" {
    run _knit_print_command_usage "__main__"
    [[ "$output" != *"hih_dyn"* ]]
}

@test "root --help omits a statically hidden command" {
    run _knit_print_command_usage "__main__"
    [[ "$output" != *"hih_static"* ]]
}

@test "a dynamically hidden command still prints its own --help" {
    run _knit_print_command_usage "hih_dyn"
    [ "$status" -eq 0 ]
    [[ "$output" == *"hih_dyn"* ]]
}

# ---------- regression: static consumers key off _is_hidden only ----------

@test "_knit_provenance_enabled ignores a dynamic hide (keys off _is_hidden)" {
    # A dynamically hidden command is NOT statically hidden, so provenance stays
    # enabled for it (provenance keys off the _is_hidden boolean, unchanged).
    knit_register knit_empty "hih_prov" "A command."
    knit_with_table "id:string"
    knit_hidden_if _hih_yes
    knit_done
    _knit_provenance_enabled "hih_prov"
}

@test "_knit_provenance_enabled treats a statically hidden command as transparent" {
    knit_register knit_empty "hih_prov_static" "A command."
    knit_with_table "id:string"
    knit_hidden
    knit_done
    run _knit_provenance_enabled "hih_prov_static"
    [ "$status" -ne 0 ]
}
