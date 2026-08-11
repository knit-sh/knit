#!/bin/bash

# Showcase for the Commands stitch category: the experiment-script skeleton,
# registering commands, nesting subcommands, a dispatcher command, and the
# visibility/gating decorators. Kept to the local backend so it runs anywhere
# with just bash and sqlite3.

# START skeleton
source knit.sh
# END skeleton

# START description
knit_set_program_description "Demonstrate command registration and nesting."
# END description

# START register
knit_register "hello" hello "Print a greeting."
hello() {
    echo "Hello World"
}
knit_done

# knit_empty registers a command with no behavior --- handy for a stub or a
# grouping parent that only carries subcommands.
knit_register "todo" knit_empty "Planned command, not implemented yet."
knit_done
# END register

# START nest
# A parent command that only groups subcommands: register it with knit_empty and
# (optionally) rename the section its children appear under in --help.
knit_register "say" knit_empty "Say something."
knit_with_subcommand_title "Greetings"
knit_done

# Subcommands: colons in the name nest them under the parent, so they are invoked
# as "say hello" and "say goodbye".
knit_register "say:hello" say_hello "Say hello."
say_hello() {
    echo "Hello"
}
knit_done

knit_register "say:goodbye" say_goodbye "Say goodbye."
say_goodbye() {
    echo "Goodbye"
}
knit_done
# END nest

# START dispatch
# A dispatcher forwards everything after "--" to a target it looks up itself.
# knit_with_dispatch changes the --help usage line to "tool [OPTIONS] -- <tool>"
# and allows the trailing arguments; the body reads them with knit_extra_index.
knit_register "tool" run_tool "Run a named tool with trailing arguments."
knit_with_dispatch "tool" "The tool name and its arguments (after --)."
run_tool() {
    local args=("$@") extra_index extra
    extra_index=$(knit_extra_index "${args[@]}")
    extra=("${args[@]:extra_index}")
    printf 'running: %s\n' "${extra[*]}"
}
knit_done
# END dispatch

# START gate
# Hide a command from --help. It stays fully invokable.
knit_register "internal" internal_cmd "Internal helper."
knit_hidden
internal_cmd() {
    echo "internal"
}
knit_done

# Refuse to run a command unless a predicate holds. The predicate receives the
# command name and returns 0 (usable) or non-zero (blocked); its description is
# shown as the error when the command is invoked while blocked.
_danger_allowed() {
    [[ "${ALLOW_DANGER:-}" == "1" ]]
}
knit_register "danger" danger_cmd "Perform a dangerous operation."
knit_usable_if _danger_allowed "Set ALLOW_DANGER=1 to enable this command."
danger_cmd() {
    echo "danger performed"
}
knit_done
# END gate

# START highlight
# Bold a command's name in --help when a predicate holds and output is a
# terminal. Purely cosmetic: it never affects whether the command runs.
_is_featured() {
    true
}
knit_register "featured" featured_cmd "A command highlighted in --help."
knit_highlight_if _is_featured
featured_cmd() {
    echo "featured"
}
knit_done
# END highlight

# START entry
knit "$@"
# END entry
