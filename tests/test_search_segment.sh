#!/usr/bin/env bats
#
# Tests for knit_search_segment_command: map a downstream segment to the command
# whose parameters/declared domains govern that segment's axes (per-segment
# domain resolution, shared by knit sweep and the knit-ax plugin).

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_source_knit

    # A job that declares a domain on "nodes" -- the same option name the submit
    # dispatcher carries -- so the collision case routes to two commands.
    knit_register_job "train" _train "A training job."
    knit_with_optional "nodes:integer" "1"    "graph node count" --domain '{1,2,4,8}'
    knit_with_optional "lr:real"       "0.01" "learning rate"    --domain '[1e-5..1.0]' --log
    _train() { :; }
    knit_done

    knit_register_app "stencil" _stencil "A stencil app."
    knit_with_optional "tile:integer" "64" "tile size" --domain '{64,128,256}'
    _stencil() { :; }
    knit_done

    knit_register "render" _render "A plain command."
    knit_with_optional "width:integer" "256" "width" --domain '{256,512,1024}'
    _render() { :; }
    knit_done
}

@test "the target segment of 'submit -- job' maps to the mangled submit:<job>" {
    local m
    knit_search_segment_command m train \
        submit --nodes @domain -- train --nodes @domain
    [ "$m" = "submit__1__train" ]
}

@test "the dispatcher segment 'submit' maps to the submit command" {
    local m
    knit_search_segment_command m submit \
        submit --nodes @domain -- train --nodes @domain
    [ "$m" = "submit" ]
}

@test "the dispatcher segment 'prepare' shares submit's option surface" {
    local m
    knit_search_segment_command m prepare prepare --nodes @domain -- train
    [ "$m" = "submit" ]
}

@test "a 'run -- app' line maps the dispatcher to run and the target to run:<app>" {
    local m
    knit_search_segment_command m run run -- stencil --tile @domain
    [ "$m" = "run" ]
    knit_search_segment_command m stencil run -- stencil --tile @domain
    [ "$m" = "run__1__stencil" ]
}

@test "a bare command's sole segment maps to the command itself" {
    local m
    knit_search_segment_command m render render --width @domain
    [ "$m" = "render" ]
}

@test "an unknown segment maps to the empty string" {
    local m
    knit_search_segment_command m nosuch \
        submit --nodes @domain -- train --nodes @domain
    [ -z "$m" ]
}

@test "the colliding --nodes axes route to two different commands' domains" {
    # The crux of qualified axis names: submit.nodes and train.nodes share the
    # bare option "nodes", but each resolves against its own segment's command.
    local m_submit m_train
    knit_search_segment_command m_submit submit \
        submit --nodes @domain -- train --nodes @domain
    knit_search_segment_command m_train train \
        submit --nodes @domain -- train --nodes @domain
    [ "$m_submit" != "$m_train" ]

    # train.nodes has a declared domain; the submit dispatcher's nodes has none.
    local kind type lo hi step log glob
    local -a values
    run knit_parameter_space kind type lo hi values step log glob \
        "$m_train" nodes
    [ "$status" -eq 0 ]
    run knit_parameter_space kind type lo hi values step log glob \
        "$m_submit" nodes
    [ "$status" -ne 0 ]
}
