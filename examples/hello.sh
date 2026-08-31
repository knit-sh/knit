#!/bin/bash

source knit.sh

knit_set_program_description "Hello World example"

@command "sum" "Add two numbers."
@with_required "x:integer" "First value"
@with_required "y:integer" "Second value"
sum() {
    local x=$(knit_get_parameter "x" $@)
    local y=$(knit_get_parameter "y" $@)
    echo $((x + y))
}
@done

@command "say" "Say something."
@empty
@done

@command "say:hello" "Greet somebody."
@with_required "the-name:string" "Name of the person to greet."
@with_optional "greeting:string" "Hello" "How to greet them."
@with_flag "prof" "Whether they are a professor."
_knit_run_before echo "Hello world" Something
_knit_run_after echo "Good bye" ABD
hello() {
    local name=$(knit_get_parameter "the-name" $@)
    local greeting=$(knit_get_parameter "greeting" $@)
    local prof=$(knit_get_parameter "prof" $@)
    local message
    if [[ "$prof" == "true" ]]; then
        message="$greeting, Prof. $name"
    else
        message="$greeting, $name"
    fi
    echo $message
}
@done

@command "say:good_bye" "Greet somebody."
bye() {
    echo "Good bye"
}
@done

knit $@
