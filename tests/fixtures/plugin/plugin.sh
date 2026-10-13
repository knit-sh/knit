#!/bin/bash
#
# A test fixture plugin. It exercises the expressive plugin API offline, with no
# network: a decorator authored from the public registration surface and exposed
# as a shorthand, a command that writes under the ".knit" directory, and an
# extension of a core Knit command. A unit test sources this file after knit.sh
# and checks each part. It is not a real plugin and lives only under tests/.

# A decorator, authored from the public registration surface (knit_run_before,
# knit_add_command_note, the per-command markers) and made available as a
# shorthand. It prints a tag before the command runs and rejects a second use.

fixture_print_tag() {
    printf 'TAG:%s\n' "$1"
}

fixture_with_tag() {
    if knit_command_has_marker fixture_tag; then
        knit_fatal "@with_tag is used more than once on \"$(knit_current_command)\"."
    fi
    knit_command_set_marker fixture_tag
    knit_add_command_note "Prints the tag \"$1\" before it runs."
    knit_run_before fixture_print_tag "$1"
}

knit_register_shorthand with_tag fixture_with_tag

# A command that writes under the experiment's ".knit" directory (located with
# knit_prefix) and uses the decorator above.

fixture_hello() {
    local who
    who="$(knit_get_parameter who "$@")"
    local dir
    dir="$(knit_prefix)/fixture"
    mkdir -p "${dir}"
    printf '%s\n' "${who}" >> "${dir}/log"
    printf 'hi %s\n' "${who}"
}

knit_register "fixture" knit_empty "Fixture plugin commands."
knit_done

knit_register "fixture:hello" fixture_hello "Greet a name and log it under .knit."
knit_with_required "who:string" "Who to greet."
# Call the decorator by its canonical name, not the "@with_tag" shorthand: a
# user may disable shorthands (KNIT_WITHOUT_SHORTHAND), which would leave the
# shorthand undefined and break this registration. The shorthand stays available
# for the user's own experiment.
fixture_with_tag "fixture"
knit_done

# Extend a core Knit command. knit_ensure_subcommand_exists runs the lazy
# discovery so metadata:store is registered, then knit_extend reopens it to add
# an option.
knit_ensure_subcommand_exists metadata store
knit_extend "metadata:store"
knit_with_optional "fixture-note:string" "" "A note added by the fixture plugin."
knit_done
