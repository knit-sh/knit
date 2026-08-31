#!/bin/bash

# The Quickstart experiment. It grows one command at a time --- from a bare
# "hello" through parameters, flags, and finally a recorded output backed by a
# table --- so each documentation subsection can show exactly one new idea.
# Kept to the local backend so it runs anywhere with just bash and sqlite3.

# START run
source knit.sh

knit_set_program_description "A tiny quickstart experiment."
# END run

# START hello
@command "hello" "Print a greeting."
hello() {
    echo "Hello World"
}
@done
# END hello

# START say
@command "say" "Repeat a message."
@with_required "message:string" "The message to repeat."
say() {
    local message
    message="$(knit_get_parameter "message" "$@")"
    echo "User said '${message}'"
}
@done
# END say

# START greet
@command "greet" "Greet someone by name."
@with_required "name:string" "Who to greet."
@with_optional "title:string" "" "An optional title (Mr, Mrs, Prof., ...)."
@with_flag "capitalize" "Upper-case the whole greeting."
greet() {
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
# END greet

# START scale
@command "scale" "Multiply an integer by a factor."
@with_required "value:integer" "The value to scale."
@with_optional "factor:integer" "2" "The multiplier (defaults to 2)."
@with_output "result:integer" "0" "value * factor."
scale() {
    local value factor
    value="$(knit_get_parameter "value" "$@")"
    factor="$(knit_get_parameter "factor" "$@")"
    knit_output "result" "$((value * factor))"
    printf 'result=%s\n' "$((value * factor))"
}
@done
# END scale

# START add
@command "add" "Add two integers and record the run."
@with_required "x:integer" "First value."
@with_required "y:integer" "Second value."
@with_output "total:integer" "0" "x + y."
@with_table
add() {
    local x y
    x="$(knit_get_parameter "x" "$@")"
    y="$(knit_get_parameter "y" "$@")"
    knit_output "total" "$((x + y))"
    printf 'total=%s\n' "$((x + y))"
}
@done
# END add

knit "$@"
