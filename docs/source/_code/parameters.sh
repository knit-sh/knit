#!/bin/bash

# Showcase for the Parameters stitch category: a required parameter, optional
# parameters and flags, an environment-backed default, a reusable parameter set,
# opaque trailing arguments, and validating a plain helper's own arguments. Kept
# to the local backend so it runs anywhere with just bash and sqlite3.

source knit.sh

# START required
# A required parameter must be supplied; the body reads it with knit_get_parameter.
@command "greet" "Greet someone."
@with_required "name:string" "Who to greet."
greet() {
    local name
    name=$(knit_get_parameter "name" "$@")
    echo "Hello ${name}"
}
@done
# END required

# START optional
# An optional parameter has a default; a flag is either present or not and reads
# back as "true"/"false".
@command "shout" "Greet someone, optionally louder."
@with_optional "name:string" "World" "Who to greet."
@with_flag "excited" "Add an exclamation mark."
shout() {
    local name excited greeting
    name=$(knit_get_parameter "name" "$@")
    excited=$(knit_get_parameter "excited" "$@")
    greeting="Hello ${name}"
    [[ "${excited}" == "true" ]] && greeting="${greeting}!"
    echo "${greeting}"
}
@done
# END optional

# START env-default
# An "ENV[NAME]" default falls back to the NAME environment variable when the
# parameter is not passed (empty if NAME is unset). Resolved when the parameter
# is filled in, so a job picks up a value exported by its setup.
@command "roll" "Print the random seed in use."
@with_optional "seed:integer" "ENV[SEED]" "Random seed."
roll() {
    echo "seed=$(knit_get_parameter "seed" "$@")"
}
@done
# END env-default

# START pset
# Define a reusable set of parameters once...
@define_parameter_set "grid"
@with_required "width:integer" "Grid width."
@with_required "height:integer" "Grid height."
@done

# ...then import it into any command with @with_parameter_set.
@command "area" "Compute a grid area."
@with_parameter_set "grid"
area() {
    local width height
    width=$(knit_get_parameter "width" "$@")
    height=$(knit_get_parameter "height" "$@")
    echo $(( width * height ))
}
@done
# END pset

# START extra
# @with_extra documents the arguments accepted after "--"; the body reads them
# starting at knit_extra_index.
@command "forward" "Echo the arguments given after --."
@with_extra "The arguments to echo."
forward() {
    local args=("$@") extra_index extra
    extra_index=$(knit_extra_index "${args[@]}")
    extra=("${args[@]:extra_index}")
    printf '%s\n' "${extra[*]}"
}
@done
# END extra

# START check-args
# A plain helper (not registered) can validate its own "$@" with
# knit_check_arguments: the first list names options that take a value, the second
# names flags. It errors on the first unexpected argument and returns 1.
_render() {
    local args=("$@")
    knit_check_arguments "size" "verbose" "${args[@]}" || return 1
    echo "size=$(knit_get_parameter "size" "${args[@]}")"
}
@command "render" "Render at a given size."
@with_optional "size:integer" "8" "Image size."
render() {
    _render --size "$(knit_get_parameter "size" "$@")"
}
@done
# END check-args

knit "$@"
