#!/usr/bin/env bats
#
# M2 tests for the sweep's opaque token scanner and literal axis enumeration:
# _knit_sweep_scan, _knit_sweep_enumerate, _knit_sweep_range_grid, and
# _knit_sweep_expand_glob. The scanner turns a downstream token list into axes +
# a reconstruction template without introspecting the target command.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_source_knit
}

# Split a newline-joined value list (one scan value entry) into array $1.
_split_values() {
    local -n __out=$1
    if [[ -z "$2" ]]; then __out=(); else mapfile -t __out <<< "$2"; fi
}

# ---------- _knit_sweep_range_grid ----------

@test "an integer range [lo..hi] enumerates its step-1 grid, ascending" {
    local -a g
    _knit_sweep_range_grid g 1 5 "" "[1..5]"
    [ "${g[*]}" = "1 2 3 4 5" ]
}

@test "an integer range enumerates descending when lo > hi" {
    local -a g
    _knit_sweep_range_grid g 5 1 "" "[5..1]"
    [ "${g[*]}" = "5 4 3 2 1" ]
}

@test "a range with an explicit step enumerates its linear grid" {
    local -a g
    _knit_sweep_range_grid g 0.0 1.0 0.25 "[0.0..1.0:0.25]"
    [ "${g[*]}" = "0 0.25 0.5 0.75 1" ]
}

@test "an integer range with an explicit step enumerates that grid" {
    local -a g
    _knit_sweep_range_grid g 0 10 2 "[0..10:2]"
    [ "${g[*]}" = "0 2 4 6 8 10" ]
}

@test "a bare real interval [lo..hi] with no step is a fatal" {
    run _knit_sweep_range_grid g 0.0 1.0 "" "[0.0..1.0]"
    [ "$status" -ne 0 ]
    [[ "$output" == *"integer grid"* ]]
}

# ---------- _knit_sweep_enumerate ----------

@test "a list descriptor enumerates its values verbatim" {
    local -a e
    _knit_sweep_enumerate e "{a,b,c}"
    [ "${e[*]}" = "a b c" ]
}

@test "a @file descriptor enumerates one value per line" {
    local f="${BATS_TEST_TMPDIR}/vals.txt"
    printf '%s\n' one two three > "${f}"
    local -a e
    _knit_sweep_enumerate e "@file:${f}"
    [ "${e[*]}" = "one two three" ]
}

@test "a @glob descriptor expands to the matching paths" {
    local d="${BATS_TEST_TMPDIR}/g"
    mkdir -p "${d}"
    touch "${d}/a.txt" "${d}/b.txt"
    local -a e
    _knit_sweep_enumerate e "@glob:${d}/*.txt"
    [ "${#e[@]}" -eq 2 ]
    [ "${e[0]}" = "${d}/a.txt" ]
    [ "${e[1]}" = "${d}/b.txt" ]
}

@test "a @glob matching nothing is a fatal" {
    run _knit_sweep_enumerate e "@glob:${BATS_TEST_TMPDIR}/nope/*.none"
    [ "$status" -ne 0 ]
    [[ "$output" == *"matched no files"* ]]
}

# ---------- _knit_sweep_scan ----------

@test "the template is the downstream tokens, literals untouched" {
    local -a tmpl axes values
    local -A seen
    _knit_sweep_scan tmpl axes values seen "" \
        submit --walltime 00:30:00 --nodes '{1,2,4}' -- montecarlo
    [ "${tmpl[0]}" = "submit" ]
    [ "${tmpl[1]}" = "--walltime" ]
    [ "${tmpl[2]}" = "00:30:00" ]
    [ "${tmpl[3]}" = "--nodes" ]
    [ "${tmpl[4]}" = "{1,2,4}" ]
    [ "${tmpl[5]}" = "--" ]
    [ "${tmpl[6]}" = "montecarlo" ]
}

@test "each swept token becomes an axis named by its option" {
    local -a tmpl axes values
    local -A seen
    _knit_sweep_scan tmpl axes values seen "" \
        submit --nodes '{1,2,4}' -- montecarlo --samples '{1000,100000}' --seed '[1..3]'
    [ "${#axes[@]}" -eq 3 ]
    [ "${axes[0]}" = "literal 2 nodes" ]
    [ "${axes[1]}" = "literal 6 samples" ]
    [ "${axes[2]}" = "literal 8 seed" ]
    local -a v
    _split_values v "${values[0]}"; [ "${v[*]}" = "1 2 4" ]
    _split_values v "${values[1]}"; [ "${v[*]}" = "1000 100000" ]
    _split_values v "${values[2]}"; [ "${v[*]}" = "1 2 3" ]
}

@test "a concrete value marks its option explicit in the seen map" {
    local -a tmpl axes values
    local -A seen
    _knit_sweep_scan tmpl axes values seen "" \
        submit --walltime 00:30:00 --nodes '{1,2,4}' -- montecarlo
    [ "${seen[walltime]}" = "explicit" ]
    [ "${seen[nodes]}" = "explicit" ]
}

@test "--passthrough protects a named option's value from being swept" {
    local -a tmpl axes values
    local -A seen
    _knit_sweep_scan tmpl axes values seen "pattern" \
        scan --pattern '{foo,bar}' --threads '{1,2,4}'
    # Only --threads is an axis; --pattern reaches the command verbatim.
    [ "${#axes[@]}" -eq 1 ]
    [ "${axes[0]}" = "literal 4 threads" ]
    [ "${seen[pattern]}" = "explicit" ]
    [ "${tmpl[2]}" = "{foo,bar}" ]
}

@test "a swept positional is named by its index" {
    local -a tmpl axes values
    local -A seen
    _knit_sweep_scan tmpl axes values seen "" render '{256,512}'
    [ "${#axes[@]}" -eq 1 ]
    [ "${axes[0]}" = "literal 1 #1" ]
}

@test "@sweep and @default are marked, not enumerated" {
    local -a tmpl axes values
    local -A seen
    _knit_sweep_scan tmpl axes values seen "" \
        submit -- train --batch '{16,64}' --layers @sweep --lr @default
    [ "${#axes[@]}" -eq 3 ]
    [ "${axes[0]}" = "literal 4 batch" ]
    [ "${axes[1]}" = "sweep 6 layers" ]
    [ "${axes[2]}" = "default 8 lr" ]
    # The markers carry no values yet (resolved in M3).
    [ -z "${values[1]}" ]
    [ -z "${values[2]}" ]
    [ "${seen[batch]}" = "explicit" ]
    [ "${seen[layers]}" = "sweep" ]
    [ "${seen[lr]}" = "default" ]
}

@test "an unknown @ directive is a fatal" {
    run _knit_sweep_scan tmpl axes values seen "" render --x @bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown sweep directive"* ]]
}

@test "the inline --opt=value form is explicit and never swept" {
    local -a tmpl axes values
    local -A seen
    _knit_sweep_scan tmpl axes values seen "" render --width='{256,512}'
    # Inline value is self-contained: no axis, recorded as explicit.
    [ "${#axes[@]}" -eq 0 ]
    [ "${seen[width]}" = "explicit" ]
}

@test "hyphenated option names are normalized when naming an axis" {
    local -a tmpl axes values
    local -A seen
    _knit_sweep_scan tmpl axes values seen "" run --procs-per-node '{1,2}'
    [ "${axes[0]}" = "literal 2 procs_per_node" ]
}
