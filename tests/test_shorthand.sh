#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_source_knit
}

# ---------- function-name discovery (_knit_shorthand_find_function) ----------
#
# The helper is tested directly: it reads a source file and reports the name of
# the decorated function. Fixtures are written to a throwaway file so the
# discovery is deterministic and independent of how bats lays out this file.

@test "find_function: adjacent name() style" {
    local f="${BATS_TEST_TMPDIR}/exp.sh"
    printf '%s\n' '@command "x" "d"' 'foo_fn() {' '    :' '}' > "${f}"
    local fn
    _knit_shorthand_find_function fn "${f}" 1
    [ "${fn}" = "foo_fn" ]
}

@test "find_function: name () with a space before the parentheses" {
    local f="${BATS_TEST_TMPDIR}/exp.sh"
    printf '%s\n' '@command "x" "d"' 'foo_fn () {' '    :' '}' > "${f}"
    local fn
    _knit_shorthand_find_function fn "${f}" 1
    [ "${fn}" = "foo_fn" ]
}

@test "find_function: function keyword without parentheses" {
    local f="${BATS_TEST_TMPDIR}/exp.sh"
    printf '%s\n' '@command "x" "d"' 'function foo_fn {' '    :' '}' > "${f}"
    local fn
    _knit_shorthand_find_function fn "${f}" 1
    [ "${fn}" = "foo_fn" ]
}

@test "find_function: function keyword with parentheses" {
    local f="${BATS_TEST_TMPDIR}/exp.sh"
    printf '%s\n' '@command "x" "d"' 'function foo_fn() {' '    :' '}' > "${f}"
    local fn
    _knit_shorthand_find_function fn "${f}" 1
    [ "${fn}" = "foo_fn" ]
}

@test "find_function: one-liner definition" {
    local f="${BATS_TEST_TMPDIR}/exp.sh"
    printf '%s\n' '@command "x" "d"' 'foo_fn() { :; }' > "${f}"
    local fn
    _knit_shorthand_find_function fn "${f}" 1
    [ "${fn}" = "foo_fn" ]
}

@test "find_function: skips blank, comment, and decorator lines" {
    local f="${BATS_TEST_TMPDIR}/exp.sh"
    printf '%s\n' \
        '@command "x" "d"' \
        '@with_required "a:string" "A."' \
        '# a comment' \
        '' \
        'foo_fn() {' \
        '    :' \
        '}' > "${f}"
    local fn
    _knit_shorthand_find_function fn "${f}" 1
    [ "${fn}" = "foo_fn" ]
}

@test "find_function: name containing an @" {
    local f="${BATS_TEST_TMPDIR}/exp.sh"
    printf '%s\n' '@command "x" "d"' 'my@fn() {' '    :' '}' > "${f}"
    local fn
    _knit_shorthand_find_function fn "${f}" 1
    [ "${fn}" = "my@fn" ]
}

@test "find_function: @empty marker resolves to knit_empty" {
    local f="${BATS_TEST_TMPDIR}/exp.sh"
    printf '%s\n' '@command "grp" "d"' '@empty' '@done' > "${f}"
    local fn
    _knit_shorthand_find_function fn "${f}" 1
    [ "${fn}" = "knit_empty" ]
}

# ---------- discovery failure modes (all knit_fatal) ----------

@test "find_function: fatal when the source is not a readable file" {
    run _knit_shorthand_find_function fn "${BATS_TEST_TMPDIR}/no-such-file.sh" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot read the source"* ]]
}

@test "find_function: fatal when no function or @empty before @done" {
    local f="${BATS_TEST_TMPDIR}/exp.sh"
    printf '%s\n' '@command "grp" "d"' '@done' > "${f}"
    run _knit_shorthand_find_function fn "${f}" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"no function definition or @empty marker"* ]]
}

@test "find_function: fatal when no function or @empty before end of file" {
    local f="${BATS_TEST_TMPDIR}/exp.sh"
    printf '%s\n' '@command "grp" "d"' > "${f}"
    run _knit_shorthand_find_function fn "${f}" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"no function definition or @empty marker"* ]]
}

@test "find_function: @done written with parentheses is not taken as the body" {
    local f="${BATS_TEST_TMPDIR}/exp.sh"
    printf '%s\n' '@command "grp" "d"' '@done()' > "${f}"
    run _knit_shorthand_find_function fn "${f}" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"no function definition or @empty marker"* ]]
}

# ---------- the five extracting shorthands (name injected at position 2) ----------
#
# The knit_register* target is stubbed so the wrapper's behaviour — discover the
# decorated name, forward it at argument position 2 — is observed without a real
# registration. The fixture is sourced so the wrapper captures a real call site.

@test "@command injects the discovered name and forwards to knit_register" {
    knit_register() { printf '%s\n' "$*" > "${BATS_TEST_TMPDIR}/got"; }
    local f="${BATS_TEST_TMPDIR}/exp.sh"
    printf '%s\n' '@command "grp" "A group."' 'grp_fn() {' '    :' '}' > "${f}"
    source "${f}"
    [ "$(cat "${BATS_TEST_TMPDIR}/got")" = "grp grp_fn A group." ]
}

@test "@app forwards the discovered name to knit_register_app (one-liner)" {
    knit_register_app() { printf '%s\n' "$*" > "${BATS_TEST_TMPDIR}/got"; }
    local f="${BATS_TEST_TMPDIR}/exp.sh"
    printf '%s\n' '@app "sim" "A sim."' 'sim_fn() { :; }' > "${f}"
    source "${f}"
    [ "$(cat "${BATS_TEST_TMPDIR}/got")" = "sim sim_fn A sim." ]
}

@test "@job forwards the discovered name to knit_register_job (function keyword)" {
    knit_register_job() { printf '%s\n' "$*" > "${BATS_TEST_TMPDIR}/got"; }
    local f="${BATS_TEST_TMPDIR}/exp.sh"
    printf '%s\n' '@job "compute" "Compute."' 'function compute_fn {' '    :' '}' > "${f}"
    source "${f}"
    [ "$(cat "${BATS_TEST_TMPDIR}/got")" = "compute compute_fn Compute." ]
}

@test "@setup forwards the discovered name to knit_register_setup" {
    knit_register_setup() { printf '%s\n' "$*" > "${BATS_TEST_TMPDIR}/got"; }
    local f="${BATS_TEST_TMPDIR}/exp.sh"
    printf '%s\n' '@setup "env" "An env."' 'env_fn() {' '    :' '}' > "${f}"
    source "${f}"
    [ "$(cat "${BATS_TEST_TMPDIR}/got")" = "env env_fn An env." ]
}

@test "@wrapper forwards the discovered name to knit_register_wrapper (@-in-name)" {
    knit_register_wrapper() { printf '%s\n' "$*" > "${BATS_TEST_TMPDIR}/got"; }
    local f="${BATS_TEST_TMPDIR}/exp.sh"
    printf '%s\n' '@wrapper "spack" "Spack."' 'spack@fn() {' '    :' '}' > "${f}"
    source "${f}"
    [ "$(cat "${BATS_TEST_TMPDIR}/got")" = "spack spack@fn Spack." ]
}

@test "@command with @empty forwards knit_empty as the body" {
    knit_register() { printf '%s\n' "$*" > "${BATS_TEST_TMPDIR}/got"; }
    local f="${BATS_TEST_TMPDIR}/exp.sh"
    printf '%s\n' '@command "grp" "A group."' '@empty' > "${f}"
    source "${f}"
    [ "$(cat "${BATS_TEST_TMPDIR}/got")" = "grp knit_empty A group." ]
}

# ---------- pass-through shorthands (arguments forwarded verbatim) ----------

@test "@resource forwards verbatim to knit_register_resource" {
    knit_register_resource() { printf '%s\n' "$*" > "${BATS_TEST_TMPDIR}/got"; }
    @resource "dataset" "A dataset."
    [ "$(cat "${BATS_TEST_TMPDIR}/got")" = "dataset A dataset." ]
}

@test "@with_required forwards verbatim to knit_with_required" {
    knit_with_required() { printf '%s\n' "$*" > "${BATS_TEST_TMPDIR}/got"; }
    @with_required "x:integer" "The x value."
    [ "$(cat "${BATS_TEST_TMPDIR}/got")" = "x:integer The x value." ]
}

@test "@with_optional forwards verbatim to knit_with_optional" {
    knit_with_optional() { printf '%s\n' "$*" > "${BATS_TEST_TMPDIR}/got"; }
    @with_optional "y:integer" "0" "The y value."
    [ "$(cat "${BATS_TEST_TMPDIR}/got")" = "y:integer 0 The y value." ]
}

@test "@done forwards verbatim to knit_done" {
    knit_done() { printf '%s\n' "called" > "${BATS_TEST_TMPDIR}/got"; }
    @done
    [ "$(cat "${BATS_TEST_TMPDIR}/got")" = "called" ]
}

# ---------- opt-out (KNIT_WITHOUT_SHORTHAND) ----------
#
# Each bats test runs in its own subshell, so unsetting an @ function and
# regenerating with an opt-out cannot leak into another test.

@test "opt-out: a listed token is not defined while others remain" {
    unset -f "@job"
    KNIT_WITHOUT_SHORTHAND="job" _knit_shorthand_generate
    ! declare -F "@job" >/dev/null
    declare -F "@app" >/dev/null
    declare -F "@with_required" >/dev/null
}

@test "opt-out: tokens are whitespace-trimmed" {
    unset -f "@job" "@app"
    KNIT_WITHOUT_SHORTHAND=" job , app " _knit_shorthand_generate
    ! declare -F "@job" >/dev/null
    ! declare -F "@app" >/dev/null
    declare -F "@wrapper" >/dev/null
}

@test "opt-out: all defines no shorthand" {
    unset -f "@job" "@resource" "@with_required"
    KNIT_WITHOUT_SHORTHAND="all" _knit_shorthand_generate
    ! declare -F "@job" >/dev/null
    ! declare -F "@resource" >/dev/null
    ! declare -F "@with_required" >/dev/null
}

@test "opt-out: the knit_* long form is always present" {
    KNIT_WITHOUT_SHORTHAND="all" _knit_shorthand_generate
    declare -F knit_register >/dev/null
    declare -F knit_register_job >/dev/null
    declare -F knit_with_required >/dev/null
}

@test "opt-out: an unknown token warns and is otherwise ignored" {
    run env KNIT_WITHOUT_SHORTHAND="not_a_real_token" bash -c \
        'source knit.sh; _knit_shorthand_generate'
    [ "$status" -eq 0 ]
    [[ "$output" == *"unknown shorthand token 'not_a_real_token'"* ]]
}

# ---------- coexistence with bats ----------

@test "@-prefixed function definitions and calls coexist with bats" {
    my@helper() { echo "called"; }
    run my@helper
    [ "$output" = "called" ]
}
