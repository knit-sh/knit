#!/usr/bin/env bash
# doc-check: source-only
#
# The author side of plugins: the contents of a plugin's plugin.sh. It authors a
# decorator, exposes it as a shorthand for the user, registers a command, and
# extends a core command. A real plugin lives in its own repository; this file
# shows the authoring API and is syntax-checked only (source-only).

source knit.sh

# The command body the plugin registers below.
demo_greet() {
    local name
    name="$(knit_get_parameter name "$@")"
    printf 'Hello, %s!\n' "${name}"
}

# START decorator
# A decorator is a function that changes the command currently being registered,
# using the same public surface the built-in knit_with_* decorators use:
# knit_run_before installs a callback, knit_add_command_note adds a help note,
# and the per-command markers reject a second use of the decorator.
demo_print_banner() {
    printf '=== %s ===\n' "$1"
}

demo_with_banner() {
    if knit_command_has_marker banner; then
        knit_fatal "@with_banner is used more than once on \"$(knit_current_command)\"."
    fi
    knit_command_set_marker banner
    knit_add_command_note "Prints a \"$1\" banner before it runs."
    knit_run_before demo_print_banner "$1"
}
# END decorator

# START shorthand
# Expose the decorator as "@with_banner" for the user's own experiment. The
# shorthand generator runs before a plugin loads, so a plugin registers its
# shorthand on demand. Reserve the shorthand for the user: call the decorator by
# its canonical name inside plugin.sh (a user may disable shorthands).
knit_register_shorthand with_banner demo_with_banner
# END shorthand

# START command
knit_register "greet" demo_greet "Greet a name."
knit_with_required "name:string" "The name to greet."
demo_with_banner "demo plugin"
knit_done
# END command

# START extend
# knit_extend reopens a command that is already registered so the decorators
# apply again. It works on any command, including a core Knit command.
# knit_ensure_subcommand_exists runs the lazy discovery so the target exists.
knit_ensure_subcommand_exists metadata store
knit_extend "metadata:store"
knit_with_optional "note:string" "" "A note added by the plugin."
knit_done
# END extend

knit "$@"
