#!/bin/bash

# Showcase for the Parameters stitch category: a required parameter, optional
# parameters and flags, an environment-backed default, a reusable parameter set,
# opaque trailing arguments, and validating a plain helper's own arguments. Kept
# to the local backend so it runs anywhere with just bash and sqlite3.

source knit.sh

# START required
# A required parameter must be supplied; the body reads it with knit_get_parameter.
knit_register "greet" greet "Greet someone."
knit_with_required "name:string" "Who to greet."
greet() {
    local name
    name=$(knit_get_parameter "name" "$@")
    echo "Hello ${name}"
}
knit_done
# END required

# START optional
# An optional parameter has a default; a flag is either present or not and reads
# back as "true"/"false".
knit_register "shout" shout "Greet someone, optionally louder."
knit_with_optional "name:string" "World" "Who to greet."
knit_with_flag "excited" "Add an exclamation mark."
shout() {
    local name excited greeting
    name=$(knit_get_parameter "name" "$@")
    excited=$(knit_get_parameter "excited" "$@")
    greeting="Hello ${name}"
    [[ "${excited}" == "true" ]] && greeting="${greeting}!"
    echo "${greeting}"
}
knit_done
# END optional

# START env-default
# An "ENV[NAME]" default falls back to the NAME environment variable when the
# parameter is not passed (empty if NAME is unset). Resolved when the parameter
# is filled in, so a job picks up a value exported by its setup.
knit_register "roll" roll "Print the random seed in use."
knit_with_optional "seed:integer" "ENV[SEED]" "Random seed."
roll() {
    echo "seed=$(knit_get_parameter "seed" "$@")"
}
knit_done
# END env-default

# START pset
# Define a reusable set of parameters once...
knit_define_parameter_set "grid"
knit_with_required "width:integer" "Grid width."
knit_with_required "height:integer" "Grid height."
knit_done

# ...then import it into any command with knit_with_parameter_set.
knit_register "area" area "Compute a grid area."
knit_with_parameter_set "grid"
area() {
    local width height
    width=$(knit_get_parameter "width" "$@")
    height=$(knit_get_parameter "height" "$@")
    echo $(( width * height ))
}
knit_done
# END pset

# START extra
# knit_with_extra documents the arguments accepted after "--"; the body reads them
# starting at knit_extra_index.
knit_register "forward" forward "Echo the arguments given after --."
knit_with_extra "The arguments to echo."
forward() {
    local args=("$@") extra_index extra
    extra_index=$(knit_extra_index "${args[@]}")
    extra=("${args[@]:extra_index}")
    printf '%s\n' "${extra[*]}"
}
knit_done
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
knit_register "render" render "Render at a given size."
knit_with_optional "size:integer" "8" "Image size."
render() {
    _render --size "$(knit_get_parameter "size" "$@")"
}
knit_done
# END check-args

knit "$@"
