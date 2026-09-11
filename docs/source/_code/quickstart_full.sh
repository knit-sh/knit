#!/bin/bash

# The complete Quickstart experiment: the final state of the script built up one
# command at a time over the Quickstart page (hello, say, greet, scale, and the
# recorded add). Kept to the local backend so it runs anywhere with just bash and
# sqlite3. Functions are given a leading underscore so their names need not match
# the command names.

source knit.sh

knit_set_program_description "A tiny quickstart experiment."

@command "hello" "Print a greeting."
_hello() {
    echo "Hello World"
}
@done

@command "say" "Repeat a message."
@with_required "message:string" "The message to repeat."
_say() {
    local message
    message="$(knit_get_parameter "message" "$@")"
    echo "User said '${message}'"
}
@done

@command "greet" "Greet someone by name."
@with_required "name:string" "Who to greet."
@with_optional "title:string" "" "An optional title (Mr, Mrs, Prof., ...)."
@with_flag "capitalize" "Upper-case the whole greeting."
_greet() {
    local name title capitalize greeting
    name="$(knit_get_parameter "name" "$@")"
    title="$(knit_get_parameter "title" "$@")"
    capitalize="$(knit_get_parameter "capitalize" "$@")"
    if [[ -n "${title}" ]]; then
        greeting="Hello, ${title} ${name}!"
    else
        greeting="Hello, ${name}!"
    fi
    if [[ "${capitalize}" == "true" ]]; then
        greeting="${greeting^^}"
    fi
    echo "${greeting}"
}
@done

@command "scale" "Multiply an integer by a factor."
@with_required "value:integer" "The value to scale."
@with_optional "factor:integer" "2" "The multiplier (defaults to 2)."
@with_output "result:integer" "0" "value * factor."
_scale() {
    local value factor
    value="$(knit_get_parameter "value" "$@")"
    factor="$(knit_get_parameter "factor" "$@")"
    knit_output "result" "$((value * factor))"
    printf 'result=%s\n' "$((value * factor))"
}
@done

@command "add" "Add two integers and record the run."
@with_required "x:integer" "First value."
@with_required "y:integer" "Second value."
@with_output "total:integer" "0" "x + y."
@with_table
_add() {
    local x y
    x="$(knit_get_parameter "x" "$@")"
    y="$(knit_get_parameter "y" "$@")"
    knit_output "total" "$((x + y))"
    printf 'total=%s\n' "$((x + y))"
}
@done

knit "$@"
