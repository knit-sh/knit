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
_greet() {
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
_shout() {
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
_roll() {
    echo "seed=$(knit_get_parameter "seed" "$@")"
}
@done
# END env-default

# START pset
# Define a reusable set of parameters once...
@parameter_set "grid"
@with_required "width:integer" "Grid width."
@with_required "height:integer" "Grid height."
@done

# ...then import it into any command with @with_parameter_set.
@command "area" "Compute a grid area."
@with_parameter_set "grid"
_area() {
    local width height
    width=$(knit_get_parameter "width" "$@")
    height=$(knit_get_parameter "height" "$@")
    echo $(( width * height ))
}
@done
# END pset

# START pset-only
# --only imports just the named parameters of a set (an allow-list); the rest are
# left out.
@command "width-only" "Report just the grid width."
@with_parameter_set "grid" --only "width"
_width_only() {
    echo "$(knit_get_parameter "width" "$@")"
}
@done
# END pset-only

# START pset-exclude
# --exclude imports every parameter but the named ones, freeing a name so the
# command can re-declare it differently (here "height" becomes optional).
@command "flat-area" "Compute a grid area with an optional height."
@with_parameter_set "grid" --exclude "height"
@with_optional "height:integer" "1" "Grid height (defaults to 1)."
_flat_area() {
    local width height
    width=$(knit_get_parameter "width" "$@")
    height=$(knit_get_parameter "height" "$@")
    echo $(( width * height ))
}
@done
# END pset-exclude

# START extra
# @with_extra documents the arguments accepted after "--"; the body reads them
# starting at knit_extra_index.
@command "forward" "Echo the arguments given after --."
@with_extra "The arguments to echo."
_forward() {
    local args=("$@") extra_index extra
    extra_index=$(knit_extra_index "${args[@]}")
    extra=("${args[@]:extra_index}")
    printf '%s\n' "${extra[*]}"
}
@done
# END extra

# START forward
# Forward parameters to another command WITHOUT emitting dangling options. Each
# helper prints tokens meant to be used UNQUOTED so the shell splits them (or
# drops them entirely when the helper prints nothing).
@command "relay" "Forward its parameters on to a plain helper."
@with_optional "size:integer" "8" "Image size to forward."
@with_flag "quiet" "When set, drop the banner."
_relay() {
    # knit_forward_parameter_as forwards "size" under the name "--dim" without
    # hand-building the "--dim <value>" pair (and prints nothing if it is absent).
    # knit_forward_flag_as maps the declared "quiet" flag (expanded to true/false
    # in the body) to its negation: "--banner" appears only when --quiet is absent.
    _render_opts \
        $(knit_forward_parameter_as "--dim" "size" "$@") \
        $(knit_forward_flag_as "" "--banner" "quiet" "$@")
}
# A stand-in for a downstream command: echo the arguments it received.
_render_opts() { printf '%s\n' "$*"; }

# knit_get_parameter_with_default fills in a fallback when a parameter is absent
# from a raw list (one the CLI did not expand, such as a plain helper's own "$@").
_pick_color() {
    echo "color=$(knit_get_parameter_with_default "color" "auto" "$@")"
}
@command "paint" "Pick a color, defaulting to auto."
@with_extra "Optional: --color NAME."
_paint() {
    local args=("$@") extra_index
    extra_index=$(knit_extra_index "${args[@]}")
    _pick_color "${args[@]:extra_index}"
}
@done
# END forward

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
_render_cmd() {
    _render --size "$(knit_get_parameter "size" "$@")"
}
@done
# END check-args

knit "$@"
