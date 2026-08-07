#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# ---------- knit_register_wrapper / _knit_command_is_wrapper ----------

@test "knit_register_wrapper registers the command and marks it a wrapper" {
    wrap_fn() { :; }
    knit_register_wrapper "wrap" "wrap_fn" "A wrapper."
    knit_done
    _knit_set_find _KNIT_COMMANDS "wrap"
    _knit_command_is_wrapper "wrap"
}

@test "_knit_command_is_wrapper is false for a regular command" {
    knit_register "regular" knit_empty "A regular command."
    knit_done
    run _knit_command_is_wrapper "regular"
    [ "$status" -ne 0 ]
}

@test "_knit_command_is_wrapper is false for an unknown command" {
    run _knit_command_is_wrapper "does_not_exist"
    [ "$status" -ne 0 ]
}

# ---------- declaration guards ----------

@test "knit_with_required is fatal on a wrapper" {
    wrap_fn() { :; }
    knit_register_wrapper "wrap" "wrap_fn" "A wrapper."
    run knit_with_required "name:string" "Nope."
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be used with a wrapper command"* ]]
    knit_done
}

@test "knit_with_optional is fatal on a wrapper" {
    wrap_fn() { :; }
    knit_register_wrapper "wrap" "wrap_fn" "A wrapper."
    run knit_with_optional "name:string" "x" "Nope."
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be used with a wrapper command"* ]]
    knit_done
}

@test "knit_with_flag is fatal on a wrapper" {
    wrap_fn() { :; }
    knit_register_wrapper "wrap" "wrap_fn" "A wrapper."
    run knit_with_flag "verbose" "Nope."
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be used with a wrapper command"* ]]
    knit_done
}

@test "knit_with_output is fatal on a wrapper" {
    wrap_fn() { :; }
    knit_register_wrapper "wrap" "wrap_fn" "A wrapper."
    run knit_with_output "result:string" "" "Nope."
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be used with a wrapper command"* ]]
    knit_done
}

@test "knit_with_dispatch is fatal on a wrapper" {
    wrap_fn() { :; }
    knit_register_wrapper "wrap" "wrap_fn" "A wrapper."
    run knit_with_dispatch "target" "Nope."
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be used with a wrapper command"* ]]
    knit_done
}

@test "knit_with_parameter_set is fatal on a wrapper" {
    knit_define_parameter_set "pset"
    knit_with_optional "n:integer" "1" "A number."
    knit_done
    wrap_fn() { :; }
    knit_register_wrapper "wrap" "wrap_fn" "A wrapper."
    run knit_with_parameter_set "pset"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be used with a wrapper command"* ]]
    knit_done
}

@test "a regular command still accepts parameters after a wrapper is defined" {
    wrap_fn() { :; }
    knit_register_wrapper "wrap" "wrap_fn" "A wrapper."
    knit_done
    knit_register "regular" knit_empty "A regular command."
    knit_with_optional "n:integer" "1" "A number."
    knit_done
    _knit_set_find "_KNIT_CMD_regular_optional" "n"
}

@test "knit_with_table is allowed on a wrapper" {
    wrap_fn() { :; }
    knit_register_wrapper "wrap" "wrap_fn" "A wrapper."
    knit_with_table
    knit_done
    local result
    result=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='wrap';")
    [ "$result" -eq 1 ]
}

# ---------- verbatim forwarding ----------

@test "a wrapper forwards its arguments verbatim" {
    wrap_fn() { printf '%s\n' "$*" > "${BATS_TEST_TMPDIR}/got"; }
    knit_register_wrapper "wrap" "wrap_fn" "A wrapper."
    knit_done
    _knit_invoke_command "wrap" install "pkg@1.0" --with-x -- extra
    [ "$(cat "${BATS_TEST_TMPDIR}/got")" = "install pkg@1.0 --with-x -- extra" ]
}

@test "a wrapper forwards --help verbatim instead of printing knit help" {
    wrap_fn() { printf '%s\n' "$*" > "${BATS_TEST_TMPDIR}/got"; }
    knit_register_wrapper "wrap" "wrap_fn" "A wrapper."
    knit_done
    _knit_invoke_command "wrap" --help
    [ "$(cat "${BATS_TEST_TMPDIR}/got")" = "--help" ]
}

@test "a wrapper with no arguments forwards an empty argument list" {
    wrap_fn() { printf '[%s]\n' "$#" > "${BATS_TEST_TMPDIR}/got"; }
    knit_register_wrapper "wrap" "wrap_fn" "A wrapper."
    knit_done
    _knit_invoke_command "wrap"
    [ "$(cat "${BATS_TEST_TMPDIR}/got")" = "[0]" ]
}

@test "the parser stops at a wrapper so non---- args are not read as subcommands" {
    # "list" and "installed" look like subcommand names but must reach the fn.
    wrap_fn() { printf '%s\n' "$*" > "${BATS_TEST_TMPDIR}/got"; }
    knit_register_wrapper "wrap" "wrap_fn" "A wrapper."
    knit_done
    _knit_invoke_command "wrap" list installed
    [ "$(cat "${BATS_TEST_TMPDIR}/got")" = "list installed" ]
}

@test "a wrapper returns the underlying function's exit status" {
    wrap_fn() { return 7; }
    knit_register_wrapper "wrap" "wrap_fn" "A wrapper."
    knit_done
    run _knit_invoke_command "wrap" whatever
    [ "$status" -eq 7 ]
}

# ---------- callbacks ----------

@test "a wrapper runs its before and after callbacks around the function" {
    : > "${BATS_TEST_TMPDIR}/order"
    before_cb() { echo "before" >> "${BATS_TEST_TMPDIR}/order"; }
    after_cb() { echo "after" >> "${BATS_TEST_TMPDIR}/order"; }
    wrap_fn() { echo "fn" >> "${BATS_TEST_TMPDIR}/order"; }
    knit_register_wrapper "wrap" "wrap_fn" "A wrapper."
    _knit_run_before before_cb
    _knit_run_after after_cb
    knit_done
    _knit_invoke_command "wrap" arg
    [ "$(cat "${BATS_TEST_TMPDIR}/order")" = "$(printf 'before\nfn\nafter')" ]
}

# ---------- table recording ----------

@test "a wrapper table has an id and an args column only" {
    wrap_fn() { :; }
    knit_register_wrapper "wrap" "wrap_fn" "A wrapper."
    knit_with_table
    knit_done
    local cols
    cols=$(sqlite3 "${_KNIT_DATABASE}" "SELECT name FROM pragma_table_info('wrap');" | paste -sd, -)
    [ "${cols}" = "id,args" ]
}

@test "a wrapper records the rendered command line in the args column" {
    wrap_fn() { :; }
    knit_register_wrapper "wrap" "wrap_fn" "A wrapper."
    knit_with_table
    knit_done
    _knit_invoke_command "wrap" install "hdf5@1.14" -- "a b"
    local args
    args=$(sqlite3 "${_KNIT_DATABASE}" "SELECT args FROM wrap;")
    # The space-bearing argument is %q-quoted by _knit_str_render_cmd.
    [ "${args}" = 'install hdf5@1.14 -- a\ b' ]
}

@test "a wrapper body that clobbers 'cmd' still records under the correct command" {
    # Simulate a third-party script (e.g. Spack's setup-env.sh, which runs
    # `for cmd in ...` without declaring it local) polluting the bare `cmd`
    # variable while the wrapper body runs. Bash dynamic scoping must not let
    # this corrupt _knit_invoke_command's post-body after-callbacks/recording.
    wrap_fn() { cmd="/usr/bin/python3"; }
    knit_register_wrapper "wrap" "wrap_fn" "A wrapper."
    knit_with_table
    knit_done
    run _knit_invoke_command "wrap" find zlib
    [ "$status" -eq 0 ]
    [[ "$output" != *"invalid variable name"* ]]
    # The row lands in the wrapper's own table under the right command name.
    local args
    args=$(sqlite3 "${_KNIT_DATABASE}" "SELECT args FROM wrap;")
    [ "${args}" = 'find zlib' ]
}

@test "a wrapper without a table records nothing" {
    wrap_fn() { :; }
    knit_register_wrapper "wrap" "wrap_fn" "A wrapper."
    knit_done
    # No table declared: invocation must not error and must create no table.
    _knit_invoke_command "wrap" anything
    local result
    result=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='wrap';")
    [ "$result" -eq 0 ]
}

@test "each wrapper invocation records its own row" {
    wrap_fn() { :; }
    knit_register_wrapper "wrap" "wrap_fn" "A wrapper."
    knit_with_table
    knit_done
    _knit_invoke_command "wrap" find
    _knit_invoke_command "wrap" info pkg
    local count
    count=$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM wrap;")
    [ "$count" -eq 2 ]
}
