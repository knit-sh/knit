#!/usr/bin/env bats
#
# M4 tests for the odometer, line reconstruction, the --group splice, the
# dimensions JSON / count, and --dry-run: _knit_sweep_plan,
# _knit_sweep_reconstruct, _knit_sweep_dimensions_json, and the dry-run body.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq
    knit_test_db_setup
    _KNIT_JQ_EXE="jq"

    # Targets used by the dry-run command tests.
    knit_register_job "montecarlo" _mc "A Monte Carlo job."
    knit_with_optional "samples:integer" "1000" "sample count"
    knit_with_optional "seed:integer" "1" "seed"
    _mc() { :; }
    knit_done

    knit_register "render" _render "A plain command."
    knit_with_optional "width:integer" "256" "width"
    knit_with_optional "quality:string" "low" "quality"
    _render() { :; }
    knit_done
}

teardown() {
    knit_test_db_teardown
}

# Scan + plan a downstream into C/F/O/TOT and the axes/values, for the unit tests.
_scan_plan() {
    _knit_sweep_scan _T _A _V _S "" "$@"
    _knit_sweep_plan _C _F _O _TOT _V
}

# ---------- _knit_sweep_plan ----------

@test "the plan's total is the product of the per-axis counts" {
    local -a _T _A _V; local -A _S
    local -a _C _F _O; local _TOT
    _scan_plan submit --nodes '{1,2,4}' -- montecarlo --samples '{1000,100000}' --seed '[1..2]'
    [ "${_TOT}" -eq 12 ]
    [ "${_C[*]}" = "3 2 2" ]
}

@test "the plan's total is 1 when there are no axes" {
    local -a _T _A _V; local -A _S
    local -a _C _F _O; local _TOT
    _scan_plan render --width 256 --quality high
    [ "${_TOT}" -eq 1 ]
    [ "${#_A[@]}" -eq 0 ]
}

# ---------- _knit_sweep_reconstruct (enumeration order + substitution) ----------

@test "reconstruction substitutes each axis value and enumerates row-major" {
    local -a _T _A _V; local -A _S
    local -a _C _F _O; local _TOT
    _scan_plan submit --nodes '{1,2}' -- montecarlo --samples '{1000,100000}'
    # Axis 0 (nodes) is most significant; axis 1 (samples) varies fastest.
    local -a l
    _knit_sweep_reconstruct l _T _A _F _O _C 0
    [ "${l[*]}" = "submit --nodes 1 -- montecarlo --samples 1000" ]
    _knit_sweep_reconstruct l _T _A _F _O _C 1
    [ "${l[*]}" = "submit --nodes 1 -- montecarlo --samples 100000" ]
    _knit_sweep_reconstruct l _T _A _F _O _C 2
    [ "${l[*]}" = "submit --nodes 2 -- montecarlo --samples 1000" ]
    _knit_sweep_reconstruct l _T _A _F _O _C 3
    [ "${l[*]}" = "submit --nodes 2 -- montecarlo --samples 100000" ]
}

# ---------- _knit_sweep_dimensions_json ----------

@test "the dimensions JSON maps each axis name to its value list" {
    local -a _T _A _V; local -A _S
    local -a _C _F _O; local _TOT
    _scan_plan submit --nodes '{1,2,4}' -- montecarlo --samples '{1000,100000}'
    local dims
    _knit_sweep_dimensions_json dims _A _F _O _C
    [ "${dims}" = '{"nodes":[1,2,4],"samples":[1000,100000]}' ]
}

@test "the dimensions JSON keeps non-numeric values as strings" {
    local -a _T _A _V; local -A _S
    local -a _C _F _O; local _TOT
    _scan_plan render --quality '{low,high}'
    local dims
    _knit_sweep_dimensions_json dims _A _F _O _C
    [ "${dims}" = '{"quality":["low","high"]}' ]
}

# ---------- --dry-run (full command) ----------

@test "--dry-run prints exactly the reconstructed lines" {
    run _knit_invoke_command "sweep" --dry-run \
        -- submit --nodes '{1,2}' -- montecarlo --samples '{1000,100000}'
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 4 ]
    [ "${lines[0]}" = "submit --nodes 1 -- montecarlo --samples 1000" ]
    [ "${lines[1]}" = "submit --nodes 1 -- montecarlo --samples 100000" ]
    [ "${lines[2]}" = "submit --nodes 2 -- montecarlo --samples 1000" ]
    [ "${lines[3]}" = "submit --nodes 2 -- montecarlo --samples 100000" ]
}

@test "--dry-run splices the group into submit lines" {
    run _knit_invoke_command "sweep" --group mc --dry-run \
        -- submit -- montecarlo --samples '{1000,100000}'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "submit --group mc -- montecarlo --samples 1000" ]
    [ "${lines[1]}" = "submit --group mc -- montecarlo --samples 100000" ]
}

@test "--dry-run splices the group into prepare lines" {
    run _knit_invoke_command "sweep" --group mc --dry-run \
        -- prepare -- montecarlo --samples '{1000,100000}'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "prepare --group mc -- montecarlo --samples 1000" ]
}

@test "--dry-run does not splice the group into a bare command line" {
    run _knit_invoke_command "sweep" --group mc --dry-run \
        -- render --width '{256,512}'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "render --width 256" ]
    [ "${lines[1]}" = "render --width 512" ]
}

@test "--dry-run records nothing" {
    _knit_invoke_command "sweep" --dry-run \
        -- submit -- montecarlo --samples '{1000,100000}'
    local n
    n=$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM sweeps;")
    [ "${n}" -eq 0 ]
}
