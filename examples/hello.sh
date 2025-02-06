#!/bin/bash

source knit.sh

knit_register sum "sum" "Add two numbers."
knit_with_required "x" "First value"
knit_with_required "y" "Second value"
sum() {
    local x=$(knit_get_parameter "x" $@)
    local y=$(knit_get_parameter "y" $@)
    echo $((x + y))
}
knit_done

knit_register knit_empty "say" "Say something."
knit_done

knit_register hello "say:hello" "Greet somebody."
knit_with_required "the-name" "Name of the person to greet."
knit_with_optional "greeting" "Hello" "How to greet them."
knit_with_flag "prof" "Whether they are a professor."
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
knit_done

knit_register bye "say:good_bye" "Greet somebody."
bye() {
    echo "Good bye"
}
knit_done

knit $@
