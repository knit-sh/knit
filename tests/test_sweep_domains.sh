#!/usr/bin/env bats
#
# M3 tests for declared-domain resolution: target resolution from the downstream
# (_knit_sweep_resolve_target) and the --fill / @sweep / @default splicing
# (_knit_sweep_resolve_domains, _knit_sweep_enumerate_domain).

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_source_knit

    # A job with declared domains (mirrors the design example): a real range
    # (bounds only), an enumerable list, and an integer range.
    knit_register_job "train" _train "A training job."
    knit_with_optional "lr:real"       "0.01" "learning rate" --domain '[1e-5..1.0]' --log
    knit_with_optional "batch:integer" "32"   "batch size"    --domain '{16,32,64,128}'
    knit_with_required "layers:integer"       "depth"         --domain '[2..12]'
    knit_with_optional "tag:string"    ""     "a domainless option"
    _train() { :; }
    knit_done

    # An app and a bare command, to exercise the other two target shapes.
    knit_register_app "stencil" _stencil "A stencil app."
    knit_with_optional "tile:integer" "64" "tile size" --domain '{64,128,256}'
    _stencil() { :; }
    knit_done

    knit_register "render" _render "A plain command."
    knit_with_optional "width:integer" "256" "width" --domain '{256,512,1024}'
    _render() { :; }
    knit_done
}

# The axis for parameter $2 within axes array $1 (parallel values array $3),
# printed as a space-separated value list. Empty if no such axis.
_axis_values() {
    local -n _axes=$1 _vals=$3
    local want="$2" i kind slot name
    for i in "${!_axes[@]}"; do
        read -r kind slot name <<< "${_axes[i]}"
        if [[ "${name}" == "${want}" ]]; then
            echo "${_vals[i]}" | tr '\n' ' ' | sed 's/ $//'
            return 0
        fi
    done
}

# ---------- _knit_sweep_resolve_target ----------

@test "target resolution: submit -- job maps to submit:<job>" {
    local m d t
    _knit_sweep_resolve_target m d t submit --nodes 2 -- train --lr 0.01
    [ "$m" = "submit__1__train" ]
    [ "$d" = "submit" ]
    [ "$t" = "train" ]
}

@test "target resolution: prepare reuses the submit job registration" {
    local m d t
    _knit_sweep_resolve_target m d t prepare -- train
    [ "$m" = "submit__1__train" ]
    [ "$d" = "prepare" ]
    [ "$t" = "train" ]
}

@test "target resolution: run -- app maps to run:<app>" {
    local m d t
    _knit_sweep_resolve_target m d t run --procs 4 -- stencil --tile 64
    [ "$m" = "run__1__stencil" ]
    [ "$d" = "run" ]
    [ "$t" = "stencil" ]
}

@test "target resolution: a bare command resolves to itself" {
    local m d t
    _knit_sweep_resolve_target m d t render --width 256
    [ "$m" = "render" ]
    [ "$d" = "render" ]
    [ "$t" = "render" ]
}

@test "target resolution: a submit line with no job after -- has no target" {
    local m d t
    _knit_sweep_resolve_target m d t submit --nodes 2
    [ -z "$m" ]
    [ "$d" = "submit" ]
}

# ---------- _knit_sweep_resolve_domains ----------

@test "--fill default with no marker introspects nothing" {
    local -a tmpl axes values; local -A seen
    _knit_sweep_scan tmpl axes values seen "" submit -- train --batch '{16,64}'
    local before_axes="${#axes[@]}" before_tmpl="${tmpl[*]}"
    _knit_sweep_resolve_domains tmpl axes values seen default "submit__1__train"
    [ "${#axes[@]}" -eq "${before_axes}" ]
    [ "${tmpl[*]}" = "${before_tmpl}" ]
}

@test "--fill sweep varies every enumerable domain and skips domainless ones" {
    local -a tmpl axes values; local -A seen
    _knit_sweep_scan tmpl axes values seen "" submit -- train --lr @default
    _knit_sweep_resolve_domains tmpl axes values seen sweep "submit__1__train"
    # batch (list) and layers (int range) are swept; tag (no domain) and lr
    # (opted out via @default) are not.
    [ "$(_axis_values axes batch values)" = "16 32 64 128" ]
    [ "$(_axis_values axes layers values)" = "2 3 4 5 6 7 8 9 10 11 12" ]
    [ -z "$(_axis_values axes tag values)" ]
    [ -z "$(_axis_values axes lr values)" ]
    # lr @default is pinned to its default value in the template.
    [[ "${tmpl[*]}" == *"--lr 0.01"* ]]
}

@test "@sweep opts a parameter in even under --fill default" {
    local -a tmpl axes values; local -A seen
    _knit_sweep_scan tmpl axes values seen "" submit -- train --batch '{16,64}' --layers @sweep
    _knit_sweep_resolve_domains tmpl axes values seen default "submit__1__train"
    # batch is the explicit literal; layers is swept from its declared domain.
    [ "$(_axis_values axes batch values)" = "16 64" ]
    [ "$(_axis_values axes layers values)" = "2 3 4 5 6 7 8 9 10 11 12" ]
}

@test "@default opts a parameter out even under --fill sweep" {
    local -a tmpl axes values; local -A seen
    # lr (a real range) must also be opted out, or --fill sweep would try to
    # enumerate its real interval and fatal (see the real-range test below).
    _knit_sweep_scan tmpl axes values seen "" \
        submit -- train --batch @default --lr @default
    _knit_sweep_resolve_domains tmpl axes values seen sweep "submit__1__train"
    # batch is pinned (no axis); layers (unspecified, int range) is swept.
    [ -z "$(_axis_values axes batch values)" ]
    [[ "${tmpl[*]}" == *"--batch 32"* ]]
    [ -n "$(_axis_values axes layers values)" ]
}

@test "an explicit value wins over the declared domain under --fill sweep" {
    local -a tmpl axes values; local -A seen
    _knit_sweep_scan tmpl axes values seen "" submit -- train --batch '{8,16}' --lr @default
    _knit_sweep_resolve_domains tmpl axes values seen sweep "submit__1__train"
    # batch uses the explicit {8,16}, not its declared {16,32,64,128}.
    [ "$(_axis_values axes batch values)" = "8 16" ]
}

@test "a real-range @sweep is a fatal with the fix message" {
    local -a tmpl axes values; local -A seen
    _knit_sweep_scan tmpl axes values seen "" submit -- train --lr @sweep
    run _knit_sweep_resolve_domains tmpl axes values seen default "submit__1__train"
    [ "$status" -ne 0 ]
    [[ "$output" == *"real interval"* ]]
    [[ "$output" == *"bounds only"* ]]
}

@test "@sweep on a domainless parameter is a fatal" {
    local -a tmpl axes values; local -A seen
    _knit_sweep_scan tmpl axes values seen "" submit -- train --tag @sweep
    run _knit_sweep_resolve_domains tmpl axes values seen default "submit__1__train"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no declared domain"* ]]
}

@test "@sweep on an unknown parameter is a fatal" {
    local -a tmpl axes values; local -A seen
    _knit_sweep_scan tmpl axes values seen "" submit -- train --bogus @sweep
    run _knit_sweep_resolve_domains tmpl axes values seen default "submit__1__train"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a parameter"* ]]
}

@test "--fill sweep works for a run -- app target" {
    local -a tmpl axes values; local -A seen
    _knit_sweep_scan tmpl axes values seen "" run -- stencil
    _knit_sweep_resolve_domains tmpl axes values seen sweep "run__1__stencil"
    [ "$(_axis_values axes tile values)" = "64 128 256" ]
}

@test "--fill sweep works for a bare command target" {
    local -a tmpl axes values; local -A seen
    _knit_sweep_scan tmpl axes values seen "" render
    _knit_sweep_resolve_domains tmpl axes values seen sweep "render"
    [ "$(_axis_values axes width values)" = "256 512 1024" ]
}
