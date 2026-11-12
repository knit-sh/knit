#!/usr/bin/env bats

# Tests for _knit_env_render_tokens (src/env.sh): the generic "{{parameter}}"
# placeholder renderer shared by the specs sugar, here-doc/stdin manifests, and
# file manifests. It resolves tokens against a setup's expanded invocation
# arguments with knit_get_parameter, so the tests drive it with real argument
# arrays rather than a stub.

setup() {
    source "${BATS_TEST_DIRNAME}/../knit.sh"
}

# Render <text> against the given invocation args and print the result, so bats
# "run" can capture both the output and the exit status (the renderer returns
# through a nameref and fatals via exit on an unresolved token).
_render() {
    local text="$1"; shift
    local rendered
    _knit_env_render_tokens rendered "fake" "${text}" "$@"
    printf '%s' "${rendered}"
}

@test "_knit_env_render_tokens returns text with no placeholder unchanged" {
    run _render "openblas +fortran" --openblas-version 0.3.28
    [ "$status" -eq 0 ]
    [ "$output" = "openblas +fortran" ]
}

@test "_knit_env_render_tokens substitutes a single token" {
    run _render "openblas@{{openblas-version}}" --openblas-version 0.3.28
    [ "$status" -eq 0 ]
    [ "$output" = "openblas@0.3.28" ]
}

@test "_knit_env_render_tokens substitutes multiple distinct tokens" {
    run _render "{{pkg}}@{{ver}}" --pkg openblas --ver 0.3.28
    [ "$status" -eq 0 ]
    [ "$output" = "openblas@0.3.28" ]
}

@test "_knit_env_render_tokens substitutes a repeated token everywhere" {
    run _render "{{v}}-{{v}}" --v 9
    [ "$status" -eq 0 ]
    [ "$output" = "9-9" ]
}

@test "_knit_env_render_tokens tolerates whitespace inside the braces" {
    run _render "openblas@{{  openblas-version  }}" --openblas-version 0.3.28
    [ "$status" -eq 0 ]
    [ "$output" = "openblas@0.3.28" ]
}

@test "_knit_env_render_tokens treats hyphens and underscores as equivalent" {
    # Token uses hyphens, option uses underscores.
    run _render "x@{{my-ver}}" --my_ver 1.2
    [ "$status" -eq 0 ]
    [ "$output" = "x@1.2" ]
    # Token uses underscores, option uses hyphens.
    run _render "x@{{my_ver}}" --my-ver 1.2
    [ "$status" -eq 0 ]
    [ "$output" = "x@1.2" ]
}

@test "_knit_env_render_tokens preserves literal text adjacent to tokens" {
    run _render "pre-{{v}}-post +flag" --v mid
    [ "$status" -eq 0 ]
    [ "$output" = "pre-mid-post +flag" ]
}

@test "_knit_env_render_tokens renders tokens across multiple lines" {
    local manifest
    manifest=$'spack:\n  specs:\n    - openblas@{{v}}\n  view: true\n'
    run _render "${manifest}" --v 0.3.28
    [ "$status" -eq 0 ]
    [[ "$output" == *"- openblas@0.3.28"* ]]
}

@test "_knit_env_render_tokens resolves a token from an inline --name=value arg" {
    run _render "x@{{v}}" --v=7
    [ "$status" -eq 0 ]
    [ "$output" = "x@7" ]
}

@test "_knit_env_render_tokens substitutes an empty value for an empty parameter" {
    run _render "x{{v}}y" --v ""
    [ "$status" -eq 0 ]
    [ "$output" = "xy" ]
}

@test "_knit_env_render_tokens is fatal on an unresolved token" {
    run _render "x@{{nope}}" --v 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"{{nope}}"* ]]
    [[ "$output" == *"declared parameter"* ]]
}
