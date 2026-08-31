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
@command "hello" "Print a greeting."
hello() {
    echo "Hello World"
}
@done

# @empty registers a command with no behavior --- handy for a stub or a
# grouping parent that only carries subcommands.
@command "todo" "Planned command, not implemented yet."
@empty
@done
# END register

# START nest
# A parent command that only groups subcommands: register it with @empty and
# (optionally) rename the section its children appear under in --help.
@command "say" "Say something."
@empty
@with_subcommand_title "Greetings"
@done

# Subcommands: colons in the name nest them under the parent, so they are invoked
# as "say hello" and "say goodbye".
@command "say:hello" "Say hello."
say_hello() {
    echo "Hello"
}
@done

@command "say:goodbye" "Say goodbye."
say_goodbye() {
    echo "Goodbye"
}
@done
# END nest

# START dispatch
# A dispatcher forwards everything after "--" to a target it looks up itself.
# @with_dispatch changes the --help usage line to "tool [OPTIONS] -- <tool>"
# and allows the trailing arguments; the body reads them with knit_extra_index.
@command "tool" "Run a named tool with trailing arguments."
@with_dispatch "tool" "The tool name and its arguments (after --)."
run_tool() {
    local args=("$@") extra_index extra
    extra_index=$(knit_extra_index "${args[@]}")
    extra=("${args[@]:extra_index}")
    printf 'running: %s\n' "${extra[*]}"
}
@done
# END dispatch

# START gate
# Hide a command from --help. It stays fully invokable.
@command "internal" "Internal helper."
@hidden
internal_cmd() {
    echo "internal"
}
@done

# Refuse to run a command unless a predicate holds. The predicate receives the
# command name and returns 0 (usable) or non-zero (blocked); its description is
# shown as the error when the command is invoked while blocked.
_danger_allowed() {
    [[ "${ALLOW_DANGER:-}" == "1" ]]
}
@command "danger" "Perform a dangerous operation."
@usable_if _danger_allowed "Set ALLOW_DANGER=1 to enable this command."
danger_cmd() {
    echo "danger performed"
}
@done
# END gate

# START highlight
# Bold a command's name in --help when a predicate holds and output is a
# terminal. Purely cosmetic: it never affects whether the command runs.
_is_featured() {
    true
}
@command "featured" "A command highlighted in --help."
@highlight_if _is_featured
featured_cmd() {
    echo "featured"
}
@done
# END highlight

# START entry
knit "$@"
# END entry
