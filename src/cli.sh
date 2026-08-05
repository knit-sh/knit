#!/bin/bash

## @file cli.sh

# ------------------------------------------------------------------------------
# List of registered commands.
# ------------------------------------------------------------------------------
declare -gA _KNIT_COMMANDS

# ------------------------------------------------------------------------------
# Top-level commands (those with no parent), in registration order. Together
# with the per-command "_KNIT_CMD_<cmd>_subcommands" arrays this forms an
# explicit command-tree adjacency so help/describe can traverse the tree in
# declaration order without deriving it from prefix-matching _KNIT_COMMANDS.
# ------------------------------------------------------------------------------
declare -ga _KNIT_ROOT_COMMANDS=()

# ------------------------------------------------------------------------------
# Set of defined parameter set names (normalized).
# ------------------------------------------------------------------------------
declare -gA _KNIT_PARAMETER_SETS

# ------------------------------------------------------------------------------
# Stack of currently-executing command names (mangled). Used by knit_output.
# ------------------------------------------------------------------------------
declare -ga _KNIT_EXECUTING_COMMAND=()

# ------------------------------------------------------------------------------
# Stack of resolved row ids, parallel to _KNIT_EXECUTING_COMMAND: entry i holds
# the id that frame i's invocation will record. The id is resolved when the frame
# is pushed (so a nested callee can read its caller's id while the caller's body
# still runs) and read back by _knit_record_invocation, so the id a callee saw as
# its edge source is exactly the id the caller records. _knit_set_row_id updates
# the top entry so an explicit id and the recorded id never diverge.
# ------------------------------------------------------------------------------
declare -ga _KNIT_EXECUTING_ROW_ID=()

# ------------------------------------------------------------------------------
# Stack of start timestamps, parallel to _KNIT_EXECUTING_COMMAND: entry i holds
# the epoch seconds captured when frame i was pushed (before its body ran).
# _knit_record_invocation reads the top entry as the call edge's start_time and
# pairs it with an end_time captured at record time (after the body and
# after-callbacks), so an invocation's duration is a plain subtraction.
# ------------------------------------------------------------------------------
declare -ga _KNIT_EXECUTING_START_TIME=()

# ------------------------------------------------------------------------------
# Stack of call-site aliases, parallel to _KNIT_EXECUTING_COMMAND: entry i holds
# the alias knit_as named frame i's invocation with, or empty for a plain call.
# Captured when the frame is pushed (from _KNIT_CALL_ALIAS, which knit_as sets
# just before delegating) and read back by _knit_record_invocation, which writes
# it to the frame's "call" edge alias column. Per-frame, so an alias on a
# dispatcher call never leaks onto the nested edges its body records.
# ------------------------------------------------------------------------------
declare -ga _KNIT_EXECUTING_ALIAS=()

# ------------------------------------------------------------------------------
# One-shot call-site alias for the next command invocation. knit_as sets it (to
# the user-supplied alias) immediately before delegating to knit; the first
# _knit_invoke_command it reaches captures it into _KNIT_EXECUTING_ALIAS and
# clears it, so exactly one edge — the directly named call — carries the alias.
# ------------------------------------------------------------------------------
declare -g _KNIT_CALL_ALIAS=""

# ------------------------------------------------------------------------------
# Set of call-site aliases already used within each invocation, so knit_as can
# reject a reused alias (which would make two edges indistinguishable in a
# query). Keyed by "<parent-row-id>:<alias>", where the parent row id scopes the
# alias to the calling invocation (empty for a root-level call).
# ------------------------------------------------------------------------------
declare -gA _KNIT_USED_ALIASES=()

# ------------------------------------------------------------------------------
# Row id of the most recently recorded invocation. Exposed so a dispatcher can
# learn the id resolved for a body it invoked, after that body returns and its
# entry has been popped off _KNIT_EXECUTING_ROW_ID. knit setup uses it to write
# the setup body's row id to .setup.id, so a later consumer can record a "used_by"
# edge to the setup by id rather than by matching directory paths.
# ------------------------------------------------------------------------------
declare -g _KNIT_LAST_ROW_ID=""

# ------------------------------------------------------------------------------
# When non-empty, output recording is suppressed: knit_output discards its value
# (with a warning) and _knit_record_invocation records no row. This is a generic
# recording concept (the CLI layer stays unaware of MPI); the `knit run` per-rank
# worker sets it on every rank but rank 0, so a run's outputs and per-app row are
# recorded exactly once even though every rank re-enters the app command.
# ------------------------------------------------------------------------------
declare -g _KNIT_RECORDING_SUPPRESSED=""

# ------------------------------------------------------------------------------
# @fn knit_empty()
#
# Empty function to register commands with no behaviors.
# ------------------------------------------------------------------------------
knit_empty() {
    :
}

# ------------------------------------------------------------------------------
# @fn _knit_command_mangle()
#
# Mangles a command, i.e. converts "command:subcommand:subcommand" into
# "command__1__subcommand__1__subcommand" so the name can be used in variable
# names. Also converts spaces into __1__.
#
# @param cmd Command to mangle.
# ------------------------------------------------------------------------------
_knit_command_mangle() {
    local cmd="$*"
    local mangled
    mangled=$(sed -E 's/[: ]+/__1__/g' <<< "${cmd}")
    printf "%s" "${mangled}"
}

# ------------------------------------------------------------------------------
# @fn _knit_command_demangle()
#
# Demangles a command, i.e. converts "command__1__subcommand__1__subcommand"
# back into "command:subcommand:subcommand".
#
# @param cmd Command to demangle.
# ------------------------------------------------------------------------------
_knit_command_demangle() {
    local cmd="$1"
    local demangled="${cmd//__1__/:}"
    printf "%s" "${demangled}"
}

# ------------------------------------------------------------------------------
# @fn _knit_command_with_space()
#
# Prints a mangled command (or a command with ":" in it) with spaces between
# subcommands.
#
# @param cmd Command to print with spaces.
# ------------------------------------------------------------------------------
_knit_command_with_space() {
    local cmd="${1//__1__/ }"
    printf "%s\n" "${cmd//:/ }"
}

# ------------------------------------------------------------------------------
# @fn _knit_name_normalize()
#
# Normalizes a parameter or command name, i.e. converts its hyphens into
# underscores.
#
# @param name Name to normalize.
# ------------------------------------------------------------------------------
_knit_name_normalize() {
    local __ret
    _knit_str_hyphens_to_underscores __ret "$1"
    printf '%s\n' "${__ret}"
}

# ------------------------------------------------------------------------------
# @fn _knit_arg_name()
#
# Extract the normalized parameter name from a command-line token. The token may
# be given as "--name" or "--name=value"; the leading "--" and any "=value"
# suffix are stripped and hyphens are converted to underscores. This is the
# single place where the "=value" form is recognized, so registered commands and
# plain helper functions (via knit_get_parameter / knit_check_arguments) accept
# it consistently.
#
# The caller is responsible for only passing tokens that start with "--"; bare
# values must not be passed, otherwise they may be mistaken for parameter names.
#
# @param token A raw argument token starting with "--".
# ------------------------------------------------------------------------------
_knit_arg_name() {
    local name="${1#--}"
    name="${name%%=*}"
    local __ret
    _knit_str_hyphens_to_underscores __ret "${name}"
    printf '%s\n' "${__ret}"
}

# ------------------------------------------------------------------------------
# @fn _knit_name_is_valid()
#
# Checks that a parameter or command name is valid, i.e. it has to start with a
# letter, followed by any number of alphanumerical characters and hyphens and
# underscores. The names "true", "false", "null", "and", "or", and "not" are
# reserved for use in --when constraint expressions and are not allowed.
#
# @param param Parameter name to normalize.
# ------------------------------------------------------------------------------
_knit_name_is_valid() {
    if [[ ! "$1" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_-]*$ ]]; then
        return 1
    fi
    case "$1" in
        true|false|null|and|or|not) return 1 ;;
    esac
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_param_check_declaration()
#
# This function carries out all the checks for a parameter to be declared by
# knit_with_required/optional/flag. The parameter name must include a type
# annotation in the form "name:type" (e.g. "width:integer").
#
# @param suffix Suffix ("required", "optional", or "flag") to use for variables.
# @param param Parameter name followed by ":type".
# @param description Description of the parameter.
# ------------------------------------------------------------------------------
_knit_param_check_declaration() {
    local suffix="$1"
    local param="$2"
    local description="$3"

    if [[ ! -v _KNIT_CURRENT_COMMAND ]] && [[ ! -v _KNIT_CURRENT_PARAMETER_SET ]]; then
        knit_fatal "knit_with_${suffix} should be used after a call to \"knit_register\" or \"knit_define_parameter_set\"."
    fi
    _knit_wrapper_reject_declaration "knit_with_${suffix}"

    # Extract name and type from "name:type" format (flags are implicitly boolean)
    local param_name param_type
    if [[ "${suffix}" == "flag" ]]; then
        param_name="${param}"
        param_type="boolean"
    elif [[ "${param}" == *:* ]]; then
        param_name="${param%%:*}"
        param_type="${param#*:}"
    else
        knit_fatal "Parameter \"${param}\" is missing a type annotation (expected \"name:type\")."
    fi

    if ! _knit_name_is_valid "${param_name}"; then
        knit_fatal "Parameter \"${param_name}\" does not have a valid name."
    fi

    if ! knit_type_exists "${param_type}"; then
        knit_fatal "Parameter \"${param_name}\" has unknown type \"${param_type}\"."
    fi

    if [ -z "${description}" ]; then
        knit_warning "Not describing parameter \"${param_name}\" undermines its understandability."
    fi

    local context_name ns
    if [[ -v _KNIT_CURRENT_PARAMETER_SET ]]; then
        context_name="${_KNIT_CURRENT_PARAMETER_SET}"
        ns="_KNIT_PSET_${_KNIT_CURRENT_PARAMETER_SET}"
    else
        context_name=$(_knit_command_demangle "${_KNIT_CURRENT_COMMAND}")
        ns="_KNIT_CMD_${_KNIT_CURRENT_COMMAND}"
    fi
    local normalized
    normalized=$(_knit_name_normalize "${param_name}")

    if _knit_set_find "${ns}_required" "${normalized}" \
    || _knit_set_find "${ns}_optional" "${normalized}" \
    || _knit_set_find "${ns}_flags"    "${normalized}"; then
        knit_fatal "Parameter \"${param_name}\" already declared for \"${context_name}\"."
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_param_description()
#
# This function returns the description of a parameter for a given command.
#
# @param __knit_ret Name of the variable to hold the description.
# @param cmd Command to which the parameter belongs (must be mangled).
# @param param Name of the parameter (must be normalized).
# ------------------------------------------------------------------------------
_knit_param_description() {
    local -n __knit_ret=$1
    # Build the backing variable name inline (mirrors the registration scheme)
    # so this stays fork-free on the describe hot path.
    local __var="_KNIT_CMD_${2}_2_${3}_description"
    __knit_ret="${!__var}"
}

# ------------------------------------------------------------------------------
# @fn _knit_param_default()
#
# This function returns the default value of a parameter for a given command.
#
# @param __knit_ret Name of the variable to hold the default value.
# @param cmd Command to which the parameter belongs (must be mangled).
# @param param Name of the parameter (must be normalized).
# ------------------------------------------------------------------------------
_knit_param_default() {
    local -n __knit_ret=$1
    local __var="_KNIT_CMD_${2}_2_${3}_default"
    __knit_ret="${!__var}"
}

# ------------------------------------------------------------------------------
# @fn _knit_resolve_default()
#
# Resolve a declared default value into the value actually used when an optional
# parameter is not provided. A default written as "ENV[NAME]" means "fall back to
# the value of the NAME environment variable"; it resolves to that variable's
# current value (the empty string when the variable is unset). Any other string,
# including one that merely looks like ENV[...] but does not name a valid shell
# variable, is returned unchanged, so ordinary defaults keep their literal value.
#
# @param raw Raw default value as declared with knit_with_optional.
# ------------------------------------------------------------------------------
_knit_resolve_default() {
    local raw="$1"
    if [[ "${raw}" =~ ^ENV\[([A-Za-z_][A-Za-z0-9_]*)\]$ ]]; then
        local name="${BASH_REMATCH[1]}"
        printf "%s" "${!name-}"
    else
        printf "%s" "${raw}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_param_type()
#
# This function returns the type of a parameter for a given command.
#
# @param __knit_ret Name of the variable to hold the type.
# @param cmd Command to which the parameter belongs (must be mangled).
# @param param Name of the parameter (must be normalized).
# ------------------------------------------------------------------------------
_knit_param_type() {
    local -n __knit_ret=$1
    local __var="_KNIT_CMD_${2}_2_${3}_type"
    __knit_ret="${!__var}"
}

# ------------------------------------------------------------------------------
# @fn _knit_output_description()
#
# This function returns the description of an output for a given command.
#
# @param __knit_ret Name of the variable to hold the description.
# @param cmd Command to which the output belongs (must be mangled).
# @param output Name of the output (must be normalized).
# ------------------------------------------------------------------------------
_knit_output_description() {
    local -n __knit_ret=$1
    local __var="_KNIT_CMD_${2}_3_${3}_description"
    __knit_ret="${!__var}"
}

# ------------------------------------------------------------------------------
# @fn _knit_output_default()
#
# This function returns the default value of an output for a given command.
#
# @param __knit_ret Name of the variable to hold the default value.
# @param cmd Command to which the output belongs (must be mangled).
# @param output Name of the output (must be normalized).
# ------------------------------------------------------------------------------
_knit_output_default() {
    local -n __knit_ret=$1
    local __var="_KNIT_CMD_${2}_3_${3}_default"
    __knit_ret="${!__var}"
}

# ------------------------------------------------------------------------------
# @fn _knit_output_type()
#
# This function returns the type of an output for a given command.
#
# @param __knit_ret Name of the variable to hold the output type.
# @param cmd Command to which the output belongs (must be mangled).
# @param output Name of the output (must be normalized).
# ------------------------------------------------------------------------------
_knit_output_type() {
    local -n __knit_ret=$1
    # Build the backing variable name inline (mirrors the registration scheme)
    # so this stays fork-free on the describe hot path (it is iterated over
    # every output of every command).
    local __type_var="_KNIT_CMD_${2}_3_${3}_type"
    __knit_ret="${!__type_var}"
}

# ------------------------------------------------------------------------------
# @fn _knit_command_get_parents()
#
# Takes a command in the form "aaa:bbb:ccc" or "aaa bbb ccc" or
# "aaa__1__bbb__1__cccc" and return the parent commands (e.g. "aaa:bbb" or
# "aaa bbb" or "aaa__1__bbb".
#
# @param __knit_ret Name of the variable to hold the parent commands.
# @param cmd Command name (colon/space/mangled).
# ------------------------------------------------------------------------------
_knit_command_get_parents() {
    local -n __knit_ret=$1; shift
    local __cmd="$*"
    __knit_ret=""
    if [[ "$__cmd" =~ ^(.*)([[:space:]]|:|__1__)[^[:space:]:]*$ ]]; then
        __knit_ret="${BASH_REMATCH[1]}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_command_get_last()
#
# Takes a command in the form "aaa:bbb:ccc" or "aaa bbb ccc" or
# "aaa__1__bbb__1__cccc" and return the last command (e.g. "ccc" in all the
# cases above).
#
# @param __knit_ret Name of the variable to hold the last command.
# @param cmd Command name (colon/space/mangled).
# ------------------------------------------------------------------------------
_knit_command_get_last() {
    local -n __knit_ret=$1; shift
    local __cmd="$*"
    if [[ "$__cmd" =~ (.*)([[:space:]]|:|__1__)([^[:space:]:]+)$ ]]; then
        __knit_ret="${BASH_REMATCH[3]}"
    else
        __knit_ret="${__cmd}"
    fi
}

# ------------------------------------------------------------------------------
# @fn knit_register()
#
# Register a function for use with a CLI. A call to this function should be
# followed by any number of knit_with_* calls, followed by the declaration of
# the function to register, then a call to knit_done.
#
# @param name Name of the function to register.
# @param cmd Command (demangled).
# @param description Description of the command.
# ------------------------------------------------------------------------------
knit_register() {
    local name=$1 # e.g. "myfunction"
    local demangled_cmd="$2"  # e.g. "command:subcommand"
    if [[ -v _KNIT_CURRENT_COMMAND ]]; then
        knit_done
        knit_warning "You forgot to call \"knit_done\" after registering the previous command."
    fi
    knit_trace "Registering function \"${name}\" with command \"${demangled_cmd}\"."
    if [[ ! "${demangled_cmd}" =~ ^[a-zA-Z0-9_:]+$ ]]; then
        knit_fatal "Invalid character found in command name \"${demangled_cmd}\"."
    fi
    local cmd
    cmd=$(_knit_command_mangle "${demangled_cmd}")
    local parent_cmd
    _knit_command_get_parents parent_cmd "$cmd"
    if [ -n "${parent_cmd}" ]  &&  ! _knit_set_find _KNIT_COMMANDS "${parent_cmd}"; then
        knit_fatal "Cannot register command \"${demangled_cmd}\" because its parent has not been registered."
    fi
    if _knit_set_find _KNIT_COMMANDS "${cmd}"; then
        knit_fatal "Command \"${demangled_cmd}\" is already registered."
    fi
    _knit_set_add _KNIT_COMMANDS "${cmd}"
    # Record the command in the tree adjacency (registration order). Every
    # command gets an empty children array; each non-root command is appended to
    # its parent's array (which exists because the parent was registered first,
    # enforced above), and each parentless command to _KNIT_ROOT_COMMANDS. The
    # hidden "__main__" root is included there too (help filters it out; describe
    # lists it only under --include-hidden), so the top-level command list is
    # simply every parentless command.
    declare -ga "_KNIT_CMD_${cmd}_subcommands=()"
    if [[ -n "${parent_cmd}" ]]; then
        local -n _knit_parent_subs="_KNIT_CMD_${parent_cmd}_subcommands"
        _knit_parent_subs+=("${cmd}")
    else
        _KNIT_ROOT_COMMANDS+=("${cmd}")
    fi
    _knit_set_new "_KNIT_CMD_${cmd}_required"
    _knit_set_new "_KNIT_CMD_${cmd}_optional"
    _knit_set_new "_KNIT_CMD_${cmd}_flags"
    _knit_set_new "_KNIT_CMD_${cmd}_outputs"
    declare -gA "_KNIT_CMD_${cmd}_output_value"
    printf -v "_KNIT_CMD_${cmd}_function"        '%s' "${name}"
    printf -v "_KNIT_CMD_${cmd}_description"     '%s' "$3"
    printf -v "_KNIT_CMD_${cmd}_extra"           '%s' ''
    printf -v "_KNIT_CMD_${cmd}_dispatch"        '%s' ''
    printf -v "_KNIT_CMD_${cmd}_is_hidden"       '%s' 'false'
    printf -v "_KNIT_CMD_${cmd}_is_wrapper"      '%s' 'false'
    printf -v "_KNIT_CMD_${cmd}_is_builtin"      '%s' 'false'
    printf -v "_KNIT_CMD_${cmd}_usable_before_bootstrap" '%s' 'false'
    printf -v "_KNIT_CMD_${cmd}_provenance"      '%s' ''
    declare -ga "_KNIT_CMD_${cmd}_before_cb"
    declare -ga "_KNIT_CMD_${cmd}_after_cb"
    declare -ga "_KNIT_CMD_${cmd}_notes"
    printf -v "_KNIT_CMD_${cmd}_subcommand_title" '%s' 'Subcommands'
    _KNIT_DONE_CBS=()
    _KNIT_CURRENT_FUNCTION="${name}"
    _KNIT_CURRENT_COMMAND="${cmd}"
    _KNIT_CURRENT_COMMAND_DEMANGLED="${demangled_cmd}"
}

# ------------------------------------------------------------------------------
# @fn knit_done()
#
# Finishes to register a function or a parameter set.
# ------------------------------------------------------------------------------
knit_done() {
    if [[ -v _KNIT_CURRENT_PARAMETER_SET ]]; then
        unset _KNIT_CURRENT_PARAMETER_SET
        return 0
    fi
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_warning "\"knit_done\" called without a matching \"knit_register\"."
    fi
    local name="${_KNIT_CURRENT_FUNCTION}"
    if ! declare -F "${name}" > /dev/null; then
        knit_fatal "Function \"${name}\" being registered is not defined."
    fi
    local i
    for (( i=${#_KNIT_DONE_CBS[@]}-1; i>=0; i-- )); do
        # shellcheck disable=SC2209 # callback string pre-escaped with printf %q by _knit_push_done_cb
        eval "${_KNIT_DONE_CBS[$i]}"
    done
    unset _KNIT_DONE_CBS
    unset _KNIT_CURRENT_FUNCTION
    unset _KNIT_CURRENT_COMMAND
    unset _KNIT_CURRENT_COMMAND_DEMANGLED
}

# ------------------------------------------------------------------------------
# @fn _knit_command_is_wrapper()
#
# Test whether a command is a wrapper, i.e. it was registered with
# knit_register_wrapper. A wrapper forwards its arguments verbatim to the
# underlying command and declares no parameters or outputs.
#
# @param cmd Command (mangled name) to test.
# @return 0 if the command is a wrapper, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_command_is_wrapper() {
    local var="_KNIT_CMD_${1}_is_wrapper"
    [[ "${!var:-}" == "true" ]]
}

# ------------------------------------------------------------------------------
# @fn knit_register_wrapper()
#
# Register a wrapper command: a command that forwards all of its arguments
# verbatim to an underlying command (e.g. "knit spack ..." forwarding to the
# knit-installed spack). A wrapper differs from a regular command in that it:
#
#   1. cannot declare parameters or outputs (knit_with_required/optional/flag/
#      output/dispatch/parameter_set are fatal);
#   2. performs no argument validation, expansion, or --when checking;
#   3. forwards "$@" verbatim to <fn>, including "--help" and "--";
#   4. may declare a table with knit_with_table, in which case the whole
#      forwarded command line is recorded in a single "args" column;
#   5. may install before/after callbacks, which still run around <fn>.
#
# A call to this function must be followed by the definition of <fn>, an
# optional knit_with_table, and a call to knit_done.
#
# @param name        Command name (used as the wrapper's invocation name).
# @param fn          Name of the Bash function the wrapper forwards to.
# @param description One-line description shown in "--help".
#
# Example:
# ```
# knit_register_wrapper "spack" "_knit_spack" "Wrapper for the spack command"
# _knit_spack() { spack "$@"; }
# knit_done
# ```
# ------------------------------------------------------------------------------
knit_register_wrapper() {
    local name="$1"
    local fn="$2"
    local description="$3"
    knit_register "${fn}" "${name}" "${description}"
    printf -v "_KNIT_CMD_${_KNIT_CURRENT_COMMAND}_is_wrapper" '%s' 'true'
}

# ------------------------------------------------------------------------------
# @fn _knit_wrapper_reject_declaration()
#
# Fatal if the command currently being registered is a wrapper. Called by the
# declaration functions that a wrapper is not allowed to use (parameters,
# outputs, dispatch, parameter sets). A parameter-set definition is never a
# wrapper, so the check is skipped when no command is being registered.
#
# @param directive Name of the calling directive (for the error message).
# ------------------------------------------------------------------------------
_knit_wrapper_reject_declaration() {
    if [[ -v _KNIT_CURRENT_COMMAND ]] \
        && _knit_command_is_wrapper "${_KNIT_CURRENT_COMMAND}"; then
        knit_fatal "$1 cannot be used with a wrapper command (registered with knit_register_wrapper)."
    fi
}

# ------------------------------------------------------------------------------
# @fn knit_define_parameter_set()
#
# Begins the definition of a named parameter set. A call to this function should
# be followed by any number of knit_with_required, knit_with_optional, and
# knit_with_flag calls, then a call to knit_done. The resulting set can then be
# imported into one or more commands with knit_with_parameter_set.
#
# @param name Name of the parameter set (letters, digits, hyphens, underscores).
# ------------------------------------------------------------------------------
knit_define_parameter_set() {
    local set_name="$1"
    if [[ -v _KNIT_CURRENT_COMMAND ]]; then
        knit_done
        knit_warning "You forgot to call \"knit_done\" before defining a parameter set."
    fi
    if [[ -v _KNIT_CURRENT_PARAMETER_SET ]]; then
        knit_fatal "Cannot define parameter set \"${set_name}\" inside another parameter set definition."
    fi
    if ! _knit_name_is_valid "${set_name}"; then
        knit_fatal "Parameter set name \"${set_name}\" is not valid."
    fi
    local normalized
    normalized=$(_knit_name_normalize "${set_name}")
    if [[ -v "_KNIT_PARAMETER_SETS[${normalized}]" ]]; then
        knit_fatal "Parameter set \"${set_name}\" is already defined."
    fi
    _KNIT_PARAMETER_SETS["${normalized}"]=1
    _knit_set_new "_KNIT_PSET_${normalized}_required"
    _knit_set_new "_KNIT_PSET_${normalized}_optional"
    _knit_set_new "_KNIT_PSET_${normalized}_flags"
    _KNIT_CURRENT_PARAMETER_SET="${normalized}"
}

# ------------------------------------------------------------------------------
# @fn knit_hidden()
#
# Mark a command as hidden, i.e. it will not appear in usage help messages. This
# is the static, unconditional hide flag (the "_is_hidden" boolean), also read by
# _knit_provenance_enabled and describe, and it stands apart from the dynamic
# knit_hidden_if predicates.
#
# knit_hidden and knit_hidden_if are mutually exclusive per command (last-writer
# wins with a warning): calling knit_hidden after one or more knit_hidden_if
# statements shadows them, so it emits a warning, sets the static flag, and drops
# the collected dynamic predicates.
# ------------------------------------------------------------------------------
knit_hidden() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_hidden should be used after a call to \"knit_register\"."
    fi
    knit_trace "Marking command ${_KNIT_CURRENT_COMMAND_DEMANGLED} as hidden."
    local cmd="${_KNIT_CURRENT_COMMAND}"
    local hidden_pred_name="_KNIT_CMD_${cmd}_hidden_pred"
    if [[ -v "${hidden_pred_name}" ]]; then
        knit_warning "knit_hidden on command \"${_KNIT_CURRENT_COMMAND_DEMANGLED}\" shadows the previous knit_hidden_if statement(s); the dynamic hide predicates are dropped."
        unset "${hidden_pred_name}"
    fi
    local cmd_hidden_name="_KNIT_CMD_${cmd}_is_hidden"
    printf -v "${cmd_hidden_name}" '%s' 'true'
}

# ------------------------------------------------------------------------------
# @fn knit_usable_before_bootstrap()
#
# Mark the command currently being registered as usable before bootstrap, i.e. it
# may be invoked (and appears in "--help") on a fresh checkout where no ".knit/"
# directory exists yet. Commands are not usable before bootstrap by default.
#
# A command usable before bootstrap must not declare a database table
# (knit_with_table) nor carry any "--when" constraint on its parameters (both
# rely on binaries that bootstrap provisions), and a subcommand may only be
# usable before bootstrap if its parent is too. These rules are enforced at
# knit_done time by _knit_usable_before_bootstrap_validate (registered here as a
# knit_done callback), so that they see the final command definition regardless
# of the order in which knit_with_table / knit_with_* / this decorator are
# called.
#
# Calling it more than once on the same command is harmless (idempotent): the
# validation callback is registered only on the first call.
# ------------------------------------------------------------------------------
knit_usable_before_bootstrap() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_usable_before_bootstrap should be used after a call to \"knit_register\"."
    fi
    knit_trace "Marking command ${_KNIT_CURRENT_COMMAND_DEMANGLED} as usable before bootstrap."
    local cmd="${_KNIT_CURRENT_COMMAND}"
    if ! _knit_command_is_usable_before_bootstrap "${cmd}"; then
        _knit_push_done_cb _knit_usable_before_bootstrap_validate \
            "${cmd}" "${_KNIT_CURRENT_COMMAND_DEMANGLED}"
    fi
    printf -v "_KNIT_CMD_${cmd}_usable_before_bootstrap" '%s' 'true'
}

# ------------------------------------------------------------------------------
# @fn _knit_usable_before_bootstrap_validate()
#
# knit_done callback registered by knit_usable_before_bootstrap. Enforces the
# three rules a command usable before bootstrap must satisfy. Each rule guards a
# behavior that would otherwise degrade silently (not crash) before bootstrap, so
# the point is to guarantee correct pre-bootstrap behavior, not to avoid a crash:
#
#   1. No database table: table row recording is skipped before bootstrap, so a
#      usable command declaring a table would silently record nothing.
#   2. No "--when" constraint on any parameter: constraint evaluation (via jq) is
#      skipped before bootstrap, so a usable command's constraint would be
#      silently ignored.
#   3. Parent must also be usable before bootstrap: keeps the usable set a
#      connected subtree rooted at the top level, which is what makes the
#      "--help" filtering and runtime guard correct without extra reachability
#      logic.
#
# Any violation is fatal, naming the command and the specific reason.
#
# @param cmd Command (mangled name) being validated.
# @param demangled Command name in demangled form (for messages).
# ------------------------------------------------------------------------------
_knit_usable_before_bootstrap_validate() {
    local cmd="$1"
    local demangled="$2"

    # Rule 1: no database table.
    local table_var="_KNIT_CMD_${cmd}_table"
    if [[ -n "${!table_var:-}" ]]; then
        knit_fatal "Command \"${demangled}\" is usable before bootstrap and cannot declare a table (knit_with_table): before bootstrap its invocations would silently record nothing."
    fi

    # Rule 2: no "--when" constraint on any parameter.
    local set_name param when_var
    for set_name in required optional flags; do
        while IFS= read -r param; do
            when_var="_KNIT_CMD_${cmd}_2_${param}_when"
            if [[ -v "${when_var}" ]]; then
                knit_fatal "Command \"${demangled}\" is usable before bootstrap and cannot use --when (on parameter \"${param}\"): before bootstrap the constraint would be silently skipped."
            fi
        done < <(_knit_set_iter "_KNIT_CMD_${cmd}_${set_name}")
    done

    # Rule 3: parent must also be usable before bootstrap.
    local parent
    _knit_command_get_parents parent "${cmd}"
    if [[ -n "${parent}" ]] && ! _knit_command_is_usable_before_bootstrap "${parent}"; then
        local parent_demangled
        parent_demangled=$(_knit_command_demangle "${parent}")
        knit_fatal "Command \"${demangled}\" is usable before bootstrap but its parent \"${parent_demangled}\" is not."
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_command_is_usable_before_bootstrap()
#
# Test whether a command is usable before bootstrap, i.e. it was marked with
# knit_usable_before_bootstrap during its registration.
#
# @param cmd Command (mangled name) to test.
# @return 0 if the command is usable before bootstrap, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_command_is_usable_before_bootstrap() {
    local var="_KNIT_CMD_${1}_usable_before_bootstrap"
    [[ "${!var:-}" == "true" ]]
}

# ------------------------------------------------------------------------------
# @fn knit_usable_if()
#
# Declare that the command currently being registered may be used only when
# <predicate> returns 0. <predicate> is the name of a user-defined shell function
# that receives the demangled command name as its single argument and returns 0
# ("usable") or non-zero ("not usable"). <description> is a human-readable string
# explaining why the command cannot run; it is shown as a fatal error if the user
# invokes the command while the predicate is false.
#
# Repeatable: multiple calls register multiple predicates. At invocation time the
# predicates are evaluated in declaration order, stopping at the first that
# returns non-zero (whose <description> becomes the error message); a command is
# usable only if all of its predicates pass.
#
# The predicate is not called here — only its name and description are recorded.
# Enforcement happens at invocation time via _knit_command_check_usable. The
# per-command storage arrays (_usable_pred / _usable_desc) are declared lazily on
# first use so commands that do not use this decorator pay no registration cost.
#
# @param predicate   Name of the predicate function.
# @param description Message shown if the command is invoked while not usable.
# ------------------------------------------------------------------------------
knit_usable_if() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_usable_if should be used after a call to \"knit_register\"."
    fi
    if [[ $# -ne 2 ]]; then
        knit_fatal "knit_usable_if requires a predicate and a description."
    fi
    local predicate="$1"
    local description="$2"
    knit_trace "Marking command ${_KNIT_CURRENT_COMMAND_DEMANGLED} usable if \"${predicate}\"."
    local cmd="${_KNIT_CURRENT_COMMAND}"
    local pred_name="_KNIT_CMD_${cmd}_usable_pred"
    local desc_name="_KNIT_CMD_${cmd}_usable_desc"
    if [[ ! -v "${pred_name}" ]]; then
        declare -ga "${pred_name}=()"
        declare -ga "${desc_name}=()"
    fi
    # shellcheck disable=SC2178 # nameref to the command's predicate array
    local -n pred_ref="${pred_name}"
    # shellcheck disable=SC2178 # nameref to the command's description array
    local -n desc_ref="${desc_name}"
    pred_ref+=("${predicate}")
    desc_ref+=("${description}")
}

# ------------------------------------------------------------------------------
# @fn _knit_command_check_usable()
#
# Evaluate the usability predicates registered for a command (via knit_usable_if)
# in declaration order. On the first predicate that returns non-zero, set the
# reason output (nameref) to that predicate's parallel description and return 1.
# Return 0 if all predicates pass, or if the command declared none.
#
# Each predicate is called as "<predicate> <demangled-cmd>" in the current shell
# (no subshell fork), so only its exit status is used. A predicate whose function
# does not exist is fatal: a usability guard that silently vanished would let an
# unusable command run.
#
# @param __knit_ret Name of the variable to receive the failure reason (nameref).
# @param cmd        Command (mangled name) to check.
# @return 0 if usable, 1 if a predicate failed (with the reason set).
# ------------------------------------------------------------------------------
_knit_command_check_usable() {
    local -n __knit_ret=$1
    local cmd="$2"
    local pred_name="_KNIT_CMD_${cmd}_usable_pred"
    if [[ ! -v "${pred_name}" ]]; then
        return 0
    fi
    # shellcheck disable=SC2178 # nameref to the command's predicate array
    local -n pred_ref="${pred_name}"
    # shellcheck disable=SC2178 # nameref to the command's description array
    local -n desc_ref="_KNIT_CMD_${cmd}_usable_desc"
    local demangled="${cmd//__1__/:}"
    local i predicate
    for i in "${!pred_ref[@]}"; do
        predicate="${pred_ref[$i]}"
        if ! declare -F "${predicate}" >/dev/null 2>&1; then
            knit_fatal "Command \"${demangled}\" declares usability predicate \"${predicate}\", which is not a defined function."
        fi
        if ! "${predicate}" "${demangled}"; then
            __knit_ret="${desc_ref[$i]}"
            return 1
        fi
    done
    return 0
}

# ------------------------------------------------------------------------------
# @fn knit_hidden_if()
#
# Declare that the command currently being registered is hidden from its parent's
# "--help" whenever <predicate> returns 0. <predicate> is the name of a
# user-defined shell function that receives the demangled command name as its
# single argument and returns 0 ("hide") or non-zero ("show"). Unlike knit_hidden
# this is a dynamic, "--help"-only hide: the command remains fully invokable and
# is still visible to _knit_provenance_enabled and describe.
#
# Repeatable: multiple calls register multiple predicates and the command is
# hidden if any of them returns 0 (logical OR).
#
# knit_hidden and knit_hidden_if are mutually exclusive per command: if the
# command is already statically hidden (knit_hidden was called first), the dynamic
# predicate would be meaningless, so this call emits a warning and is ignored. The
# per-command storage array (_hidden_pred) is declared lazily on first use.
#
# @param predicate Name of the predicate function.
# ------------------------------------------------------------------------------
knit_hidden_if() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_hidden_if should be used after a call to \"knit_register\"."
    fi
    if [[ $# -ne 1 ]]; then
        knit_fatal "knit_hidden_if requires a predicate."
    fi
    local predicate="$1"
    local cmd="${_KNIT_CURRENT_COMMAND}"
    local is_hidden_name="_KNIT_CMD_${cmd}_is_hidden"
    if [[ "${!is_hidden_name}" == "true" ]]; then
        knit_warning "knit_hidden_if on command \"${_KNIT_CURRENT_COMMAND_DEMANGLED}\" is meaningless: the command is already unconditionally hidden by knit_hidden; ignoring."
        return 0
    fi
    knit_trace "Marking command ${_KNIT_CURRENT_COMMAND_DEMANGLED} hidden if \"${predicate}\"."
    local pred_name="_KNIT_CMD_${cmd}_hidden_pred"
    if [[ ! -v "${pred_name}" ]]; then
        declare -ga "${pred_name}=()"
    fi
    # shellcheck disable=SC2178 # nameref to the command's hide-predicate array
    local -n pred_ref="${pred_name}"
    pred_ref+=("${predicate}")
}

# ------------------------------------------------------------------------------
# @fn knit_hidden_if_not_usable()
#
# Shorthand for a knit_hidden_if whose predicate hides the command from "--help"
# exactly when at least one of its knit_usable_if predicates is false. Takes no
# arguments. Backed by the internal predicate _knit_hidden_if_not_usable_pred,
# appended to the command's _hidden_pred array; a command with no knit_usable_if
# predicates is always usable, hence never hidden by this shorthand.
#
# Subject to the same mutual exclusion with knit_hidden as knit_hidden_if.
# ------------------------------------------------------------------------------
knit_hidden_if_not_usable() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_hidden_if_not_usable should be used after a call to \"knit_register\"."
    fi
    knit_hidden_if _knit_hidden_if_not_usable_pred
}

# ------------------------------------------------------------------------------
# @fn _knit_hidden_if_not_usable_pred()
#
# Internal hide predicate backing knit_hidden_if_not_usable. Receives the
# demangled command name, runs the command's usability check, and inverts it:
# returns 0 ("hide") when the command is not usable, and non-zero ("show") when it
# is usable (or declares no usability predicates).
#
# @param demangled Demangled command name passed by _knit_command_hidden.
# @return 0 if the command is not usable (hide it), non-zero otherwise.
# ------------------------------------------------------------------------------
_knit_hidden_if_not_usable_pred() {
    local demangled="$1"
    local mangled="${demangled//:/__1__}"
    # shellcheck disable=SC2034 # set by _knit_command_check_usable via nameref
    local reason
    if _knit_command_check_usable reason "${mangled}"; then
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_command_hidden()
#
# The "--help" visibility test for a command. Return 0 (hidden) if the static
# _is_hidden boolean is true, or if any of the command's dynamic _hidden_pred
# predicates returns 0; return non-zero (shown) otherwise. Because knit_hidden and
# knit_hidden_if are mutually exclusive, at most one of the two arms is ever
# non-trivial for a given command.
#
# Each dynamic predicate is called as "<predicate> <demangled-cmd>" in the current
# shell (no fork). A predicate whose function does not exist is a warning (not
# fatal): hiding is guidance, not access control, so a vanished predicate is
# treated as "no" (do not hide) and "--help" still renders.
#
# @param cmd Command (mangled name) to test.
# @return 0 if the command should be hidden from "--help", non-zero otherwise.
# ------------------------------------------------------------------------------
_knit_command_hidden() {
    local cmd="$1"
    local is_hidden_name="_KNIT_CMD_${cmd}_is_hidden"
    if [[ "${!is_hidden_name}" == "true" ]]; then
        return 0
    fi
    local pred_name="_KNIT_CMD_${cmd}_hidden_pred"
    if [[ ! -v "${pred_name}" ]]; then
        return 1
    fi
    # shellcheck disable=SC2178 # nameref to the command's hide-predicate array
    local -n pred_ref="${pred_name}"
    local demangled="${cmd//__1__/:}"
    local predicate
    for predicate in "${pred_ref[@]}"; do
        if ! declare -F "${predicate}" >/dev/null 2>&1; then
            knit_warning "Command \"${demangled}\" declares hide predicate \"${predicate}\", which is not a defined function; not hiding."
            continue
        fi
        if "${predicate}" "${demangled}"; then
            return 0
        fi
    done
    return 1
}

# ------------------------------------------------------------------------------
# @fn knit_highlight_if()
#
# Declare that the command currently being registered has its name highlighted
# (bold) in its parent's "--help" whenever <predicate> returns 0 and the output
# is a terminal. <predicate> is the name of a user-defined shell function that
# receives the demangled command name as its single argument and returns 0
# ("highlight") or non-zero ("plain"). Highlighting is purely cosmetic: it never
# affects invokability, provenance, or describe.
#
# Repeatable: multiple calls register multiple predicates and the command is
# highlighted if any of them returns 0 (logical OR). The per-command storage
# array (_highlight_pred) is declared lazily on first use.
#
# @param predicate Name of the predicate function.
# ------------------------------------------------------------------------------
knit_highlight_if() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_highlight_if should be used after a call to \"knit_register\"."
    fi
    if [[ $# -ne 1 ]]; then
        knit_fatal "knit_highlight_if requires a predicate."
    fi
    local predicate="$1"
    local cmd="${_KNIT_CURRENT_COMMAND}"
    knit_trace "Marking command ${_KNIT_CURRENT_COMMAND_DEMANGLED} highlighted if \"${predicate}\"."
    local pred_name="_KNIT_CMD_${cmd}_highlight_pred"
    if [[ ! -v "${pred_name}" ]]; then
        declare -ga "${pred_name}=()"
    fi
    # shellcheck disable=SC2178 # nameref to the command's highlight-predicate array
    local -n pred_ref="${pred_name}"
    pred_ref+=("${predicate}")
}

# ------------------------------------------------------------------------------
# @fn _knit_command_highlighted()
#
# The "--help" highlight test for a command. Return 0 (highlight) if any of the
# command's dynamic _highlight_pred predicates returns 0; return non-zero (plain)
# otherwise, including when the command declares no highlight predicates.
#
# Each predicate is called as "<predicate> <demangled-cmd>" in the current shell
# (no fork). A predicate whose function does not exist is a warning (not fatal):
# highlighting is cosmetic, so a vanished predicate is treated as "no" (do not
# highlight) and "--help" still renders.
#
# @param cmd Command (mangled name) to test.
# @return 0 if the command name should be highlighted, non-zero otherwise.
# ------------------------------------------------------------------------------
_knit_command_highlighted() {
    local cmd="$1"
    local pred_name="_KNIT_CMD_${cmd}_highlight_pred"
    if [[ ! -v "${pred_name}" ]]; then
        return 1
    fi
    # shellcheck disable=SC2178 # nameref to the command's highlight-predicate array
    local -n pred_ref="${pred_name}"
    local demangled="${cmd//__1__/:}"
    local predicate
    for predicate in "${pred_ref[@]}"; do
        if ! declare -F "${predicate}" >/dev/null 2>&1; then
            knit_warning "Command \"${demangled}\" declares highlight predicate \"${predicate}\", which is not a defined function; not highlighting."
            continue
        fi
        if "${predicate}" "${demangled}"; then
            return 0
        fi
    done
    return 1
}

# ------------------------------------------------------------------------------
# @fn _knit_is_builtin()
#
# Mark the item currently being defined as a framework builtin. This is called by
# knit's own source files immediately after a registration or enum definition, so
# that "describe" (and --exclude-builtins) can tell knit's own commands/enums
# apart from user-declared ones. It has two behaviors:
#
#   - Inside a command registration (_KNIT_CURRENT_COMMAND set, i.e. between
#     knit_register/knit_register_wrapper/... and knit_done), it marks the current
#     command by setting _KNIT_CMD_<cmd>_is_builtin=true.
#   - Otherwise it marks the most recently defined enum (_KNIT_LAST_ENUM) by
#     adding it to the _KNIT_BUILTIN_ENUMS set.
# ------------------------------------------------------------------------------
_knit_is_builtin() {
    if [[ -v _KNIT_CURRENT_COMMAND ]]; then
        knit_trace "Marking command ${_KNIT_CURRENT_COMMAND_DEMANGLED} as builtin."
        printf -v "_KNIT_CMD_${_KNIT_CURRENT_COMMAND}_is_builtin" '%s' 'true'
    elif [[ -n "${_KNIT_LAST_ENUM}" ]]; then
        knit_trace "Marking enum ${_KNIT_LAST_ENUM} as builtin."
        _knit_set_add _KNIT_BUILTIN_ENUMS "${_KNIT_LAST_ENUM}"
    else
        knit_fatal "_knit_is_builtin called with no command being registered and no enum defined."
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_command_is_builtin()
#
# Test whether a command is a framework builtin, i.e. it was marked with
# _knit_is_builtin during its registration.
#
# @param cmd Command (mangled name) to test.
# @return 0 if the command is a builtin, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_command_is_builtin() {
    local var="_KNIT_CMD_${1}_is_builtin"
    [[ "${!var:-}" == "true" ]]
}

# ------------------------------------------------------------------------------
# @fn knit_with_provenance()
#
# Mark the command being registered as participating in the provenance graph: an
# invocation of it records a "call" edge and acts as an in-process parent frame
# for the commands it invokes. This is an explicit override of the default
# (which is by visibility — see _knit_provenance_enabled), so it forces a hidden
# command into the graph. The mark also propagates to unmarked lexical
# descendants (e.g. "a" marked "with" makes an unmarked "a:b" participate).
# ------------------------------------------------------------------------------
knit_with_provenance() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_with_provenance should be used after a call to \"knit_register\"."
    fi
    knit_trace "Marking command ${_KNIT_CURRENT_COMMAND_DEMANGLED} as recording provenance."
    printf -v "_KNIT_CMD_${_KNIT_CURRENT_COMMAND}_provenance" '%s' 'with'
}

# ------------------------------------------------------------------------------
# @fn knit_without_provenance()
#
# Mark the command being registered as excluded from the provenance graph: an
# invocation of it records no "call" edge and is transparent when a command it
# invokes resolves its parent (the child links to the nearest participating
# ancestor instead). This is an explicit override of the default, so it silences
# a visible command. The mark also propagates to unmarked lexical descendants
# (e.g. "a" marked "without" silences an unmarked "a:b"). Data-row recording
# (knit_with_table) is orthogonal and still happens.
# ------------------------------------------------------------------------------
knit_without_provenance() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_without_provenance should be used after a call to \"knit_register\"."
    fi
    knit_trace "Marking command ${_KNIT_CURRENT_COMMAND_DEMANGLED} as not recording provenance."
    printf -v "_KNIT_CMD_${_KNIT_CURRENT_COMMAND}_provenance" '%s' 'without'
}

# ------------------------------------------------------------------------------
# @fn knit_with_subcommand_title()
#
# Change the title of subcommands for the command being registered
# (default subcommand name is "Subcommands"). This is the title displayed when
# calling --help.
# ------------------------------------------------------------------------------
knit_with_subcommand_title() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_with_subcommand_name should be used after a call to \"knit_register\"."
    fi
    knit_trace "Changing subcommand title from '${_KNIT_CURRENT_COMMAND_DEMANGLED}' to '$1'."
    local cmd="${_KNIT_CURRENT_COMMAND}"
    printf -v "_KNIT_CMD_${cmd}_subcommand_title" '%s' "$1"
}

# ------------------------------------------------------------------------------
# @fn knit_with_required()
#
# This function should be called right after a call to knit_register (or one of
# its variants) to declare required parameters that the command expects. The
# parameter name may include a type annotation using the "name:type" syntax
# (e.g. "width:integer"). If no type is given, "string" is assumed.
#
# Example:
# ```
# knit_register "say_hello" "greet" "Say hello to someone"
# knit_with_required "name:string" "Name of the person to greet"
# knit_with_required "count:integer" "Number of times to greet"
# say_hello() {
#    ...
# }
# ```
# Indicates that the command "greet" requires a parameter --name (string) and
# --count (integer).
#
# @param param Parameter name followed by ":type".
# @param description Description of the parameter.
# @param --when Optional boolean constraint expression (jq syntax referring to
#        the command's other parameters); the parameter only applies when the
#        expression evaluates to true.
# ------------------------------------------------------------------------------
knit_with_required() {
    _knit_param_check_declaration "required" "$1" "$2"
    knit_check_arguments "when" "" "${@:3}" \
        || knit_fatal "knit_with_required takes a parameter, a description, and an optional --when."
    local param_spec="$1"
    local param_name="${param_spec%%:*}"
    local param_type="${param_spec#*:}"
    local param
    param=$(_knit_name_normalize "${param_name}")
    local ns demangled_cmd
    if [[ -v _KNIT_CURRENT_PARAMETER_SET ]]; then
        ns="_KNIT_PSET_${_KNIT_CURRENT_PARAMETER_SET}"
        demangled_cmd="${_KNIT_CURRENT_PARAMETER_SET}"
    else
        ns="_KNIT_CMD_${_KNIT_CURRENT_COMMAND}"
        demangled_cmd="${_KNIT_CURRENT_COMMAND_DEMANGLED}"
    fi
    knit_trace "Adding required parameter \"${param_name}\" (type: ${param_type}) to \"${demangled_cmd}\"."
    printf -v "${ns}_2_${param}_description" '%s' "$2"
    printf -v "${ns}_2_${param}_type"        '%s' "${param_type}"
    _knit_set_add "${ns}_required" "${param}"
    local when_expr
    when_expr=$(knit_get_parameter "when" "$@") || when_expr=""
    if [[ -n "${when_expr}" ]]; then
        printf -v "${ns}_2_${param}_when"     '%s' "${when_expr}"
        printf -v "${ns}_2_${param}_when_raw" '%s' "${when_expr}"
    fi
}

# ------------------------------------------------------------------------------
# @fn knit_with_optional()
#
# This function should be called right after a call to knit_register (or one of
# its variants) to declare optional parameters for the command. The parameter
# name may include a type annotation using the "name:type" syntax (e.g.
# "count:integer"). If no type is given, "string" is assumed.
#
# Example:
# ```
# knit_register "say_hello" "greet" "Say hello to someone"
# knit_with_optional "name:string" "world" "Name of the person to greet"
# knit_with_optional "count:integer" "1" "Number of times to greet"
# say_hello() {
#    ...
# }
# ```
# Indicates that the command "greet" has an optional parameter --name (string,
# default "world") and --count (integer, default "1").
#
# The default may be written as "ENV[NAME]" to mean "fall back to the value of
# the NAME environment variable when the parameter is not provided". This is
# resolved when the parameter is filled in, so a job whose environment is set up
# by a `knit setup` (e.g. `knit_with_optional "seed:integer" "ENV[MC_SEED]" ...`)
# picks up the value exported by that setup.
#
# @param param Parameter name followed by ":type".
# @param default Default value (or "ENV[NAME]" to read the NAME env variable).
# @param description Description of the parameter.
# @param --when Optional boolean constraint expression (jq syntax referring to
#        the command's other parameters); the parameter only applies when the
#        expression evaluates to true.
# ------------------------------------------------------------------------------
knit_with_optional() {
    _knit_param_check_declaration "optional" "$1" "$3"
    knit_check_arguments "when" "" "${@:4}" \
        || knit_fatal "knit_with_optional takes a parameter, a default, a description, and an optional --when."
    local param_spec="$1"
    local param_name="${param_spec%%:*}"
    local param_type="${param_spec#*:}"
    local param
    param=$(_knit_name_normalize "${param_name}")
    local ns demangled_cmd
    if [[ -v _KNIT_CURRENT_PARAMETER_SET ]]; then
        ns="_KNIT_PSET_${_KNIT_CURRENT_PARAMETER_SET}"
        demangled_cmd="${_KNIT_CURRENT_PARAMETER_SET}"
    else
        ns="_KNIT_CMD_${_KNIT_CURRENT_COMMAND}"
        demangled_cmd="${_KNIT_CURRENT_COMMAND_DEMANGLED}"
    fi
    knit_trace "Adding optional parameter \"${param_name}\" (type: ${param_type}) to \"${demangled_cmd}\"."
    printf -v "${ns}_2_${param}_description" '%s' "$3"
    printf -v "${ns}_2_${param}_default"     '%s' "$2"
    printf -v "${ns}_2_${param}_type"        '%s' "${param_type}"
    _knit_set_add "${ns}_optional" "${param}"
    local when_expr
    when_expr=$(knit_get_parameter "when" "$@") || when_expr=""
    if [[ -n "${when_expr}" ]]; then
        printf -v "${ns}_2_${param}_when"     '%s' "${when_expr}"
        printf -v "${ns}_2_${param}_when_raw" '%s' "${when_expr}"
    fi
}

# ------------------------------------------------------------------------------
# @fn knit_with_flag()
#
# This function should be called right after a call to knit_register (or one of
# its variants) to declare flag parameters that the command may accept.
#
# Example:
# ```
# knit_register "say_hello" "greet" "Say hello to someone"
# knit_with_flag "capitalize" "Make the output upper-case"
# say_hello() {
#    ...
# }
# ```
#
# @param param Parameter name.
# @param description Description of the parameter.
# @param --when Optional boolean constraint expression (jq syntax referring to
#        the command's other parameters); the parameter only applies when the
#        expression evaluates to true.
# ------------------------------------------------------------------------------
knit_with_flag() {
    _knit_param_check_declaration "flag" "$1" "$2"
    knit_check_arguments "when" "" "${@:3}" \
        || knit_fatal "knit_with_flag takes a flag name, a description, and an optional --when."
    local param
    param=$(_knit_name_normalize "$1")
    local ns demangled_cmd
    if [[ -v _KNIT_CURRENT_PARAMETER_SET ]]; then
        ns="_KNIT_PSET_${_KNIT_CURRENT_PARAMETER_SET}"
        demangled_cmd="${_KNIT_CURRENT_PARAMETER_SET}"
    else
        ns="_KNIT_CMD_${_KNIT_CURRENT_COMMAND}"
        demangled_cmd="${_KNIT_CURRENT_COMMAND_DEMANGLED}"
    fi
    knit_trace "Adding flag \"$1\" to \"${demangled_cmd}\"."
    printf -v "${ns}_2_${param}_description" '%s' "$2"
    _knit_set_add "${ns}_flags" "${param}"
    local when_expr
    when_expr=$(knit_get_parameter "when" "$@") || when_expr=""
    if [[ -n "${when_expr}" ]]; then
        printf -v "${ns}_2_${param}_when"     '%s' "${when_expr}"
        printf -v "${ns}_2_${param}_when_raw" '%s' "${when_expr}"
    fi
}

# ------------------------------------------------------------------------------
# @fn knit_with_parameter_set()
#
# Import all parameters from a previously defined parameter set into the command
# currently being registered. May be called multiple times with different sets.
# Conflicts between the set's parameters and parameters already declared for the
# command are reported as fatal errors.
#
# @param name Name of the parameter set to import.
# ------------------------------------------------------------------------------
knit_with_parameter_set() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_with_parameter_set should be used after a call to \"knit_register\"."
    fi
    _knit_wrapper_reject_declaration "knit_with_parameter_set"
    local set_name="$1"
    local normalized
    normalized=$(_knit_name_normalize "${set_name}")
    if [[ ! -v "_KNIT_PARAMETER_SETS[${normalized}]" ]]; then
        knit_fatal "Parameter set \"${set_name}\" is not defined."
    fi
    local cmd="${_KNIT_CURRENT_COMMAND}"
    local demangled_cmd="${_KNIT_CURRENT_COMMAND_DEMANGLED}"
    local pset_ns="_KNIT_PSET_${normalized}"
    local cmd_ns="_KNIT_CMD_${cmd}"
    local param

    while IFS= read -r param; do
        if _knit_set_find "${cmd_ns}_required" "${param}" \
        || _knit_set_find "${cmd_ns}_optional" "${param}" \
        || _knit_set_find "${cmd_ns}_flags"    "${param}"; then
            knit_fatal "Parameter \"${param}\" from set \"${set_name}\" conflicts with an existing parameter of \"${demangled_cmd}\"."
        fi
        local _src_desc="${pset_ns}_2_${param}_description"
        local _src_type="${pset_ns}_2_${param}_type"
        printf -v "${cmd_ns}_2_${param}_description" '%s' "${!_src_desc}"
        printf -v "${cmd_ns}_2_${param}_type"        '%s' "${!_src_type}"
        if [[ -v "${pset_ns}_2_${param}_when" ]]; then
            local _src_when="${pset_ns}_2_${param}_when"
            local _src_raw="${pset_ns}_2_${param}_when_raw"
            printf -v "${cmd_ns}_2_${param}_when"     '%s' "${!_src_when}"
            printf -v "${cmd_ns}_2_${param}_when_raw" '%s' "${!_src_raw}"
        fi
        _knit_set_add "${cmd_ns}_required" "${param}"
    done < <(_knit_set_iter "${pset_ns}_required")

    while IFS= read -r param; do
        if _knit_set_find "${cmd_ns}_required" "${param}" \
        || _knit_set_find "${cmd_ns}_optional" "${param}" \
        || _knit_set_find "${cmd_ns}_flags"    "${param}"; then
            knit_fatal "Parameter \"${param}\" from set \"${set_name}\" conflicts with an existing parameter of \"${demangled_cmd}\"."
        fi
        local _src_desc="${pset_ns}_2_${param}_description"
        local _src_type="${pset_ns}_2_${param}_type"
        local _src_dflt="${pset_ns}_2_${param}_default"
        printf -v "${cmd_ns}_2_${param}_description" '%s' "${!_src_desc}"
        printf -v "${cmd_ns}_2_${param}_type"        '%s' "${!_src_type}"
        printf -v "${cmd_ns}_2_${param}_default"     '%s' "${!_src_dflt}"
        if [[ -v "${pset_ns}_2_${param}_when" ]]; then
            local _src_when="${pset_ns}_2_${param}_when"
            local _src_raw="${pset_ns}_2_${param}_when_raw"
            printf -v "${cmd_ns}_2_${param}_when"     '%s' "${!_src_when}"
            printf -v "${cmd_ns}_2_${param}_when_raw" '%s' "${!_src_raw}"
        fi
        _knit_set_add "${cmd_ns}_optional" "${param}"
    done < <(_knit_set_iter "${pset_ns}_optional")

    while IFS= read -r param; do
        if _knit_set_find "${cmd_ns}_required" "${param}" \
        || _knit_set_find "${cmd_ns}_optional" "${param}" \
        || _knit_set_find "${cmd_ns}_flags"    "${param}"; then
            knit_fatal "Parameter \"${param}\" from set \"${set_name}\" conflicts with an existing parameter of \"${demangled_cmd}\"."
        fi
        local _src_desc="${pset_ns}_2_${param}_description"
        printf -v "${cmd_ns}_2_${param}_description" '%s' "${!_src_desc}"
        if [[ -v "${pset_ns}_2_${param}_when" ]]; then
            local _src_when="${pset_ns}_2_${param}_when"
            local _src_raw="${pset_ns}_2_${param}_when_raw"
            printf -v "${cmd_ns}_2_${param}_when"     '%s' "${!_src_when}"
            printf -v "${cmd_ns}_2_${param}_when_raw" '%s' "${!_src_raw}"
        fi
        _knit_set_add "${cmd_ns}_flags" "${param}"
    done < <(_knit_set_iter "${pset_ns}_flags")
}

# ------------------------------------------------------------------------------
# @fn knit_with_output()
#
# This function should be called right after a call to knit_register (or one of
# its variants) to declare an output that the command produces. The output name
# must include a type annotation using the "name:type" syntax (e.g.
# "result:integer").
#
# Example:
# ```
# knit_register "compute" "compute" "Compute something."
# knit_with_output "result:real" "0.0" "The computed result."
# compute() {
#    ...
# }
# ```
#
# @param param Output name followed by ":type".
# @param default Default value.
# @param description Description of the output.
# ------------------------------------------------------------------------------
knit_with_output() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_with_output should be used after a call to \"knit_register\"."
    fi
    _knit_wrapper_reject_declaration "knit_with_output"
    local param_spec="$1"
    if [[ "${param_spec}" != *:* ]]; then
        knit_fatal "Output \"${param_spec}\" is missing a type annotation (expected \"name:type\")."
    fi
    local param_name="${param_spec%%:*}"
    local param_type="${param_spec#*:}"
    if ! _knit_name_is_valid "${param_name}"; then
        knit_fatal "Output \"${param_name}\" does not have a valid name."
    fi
    if ! knit_type_exists "${param_type}"; then
        knit_fatal "Output \"${param_name}\" has unknown type \"${param_type}\"."
    fi
    if [ -z "$3" ]; then
        knit_warning "Not describing output \"${param_name}\" undermines its understandability."
    fi
    local cmd="${_KNIT_CURRENT_COMMAND}"
    local demangled_cmd="${_KNIT_CURRENT_COMMAND_DEMANGLED}"
    local output
    output=$(_knit_name_normalize "${param_name}")
    if _knit_set_find "_KNIT_CMD_${cmd}_outputs" "${output}"; then
        knit_fatal "Output \"${param_name}\" already declared for \"${demangled_cmd}\"."
    fi
    knit_trace "Adding output \"${param_name}\" (type: ${param_type}) to command \"${demangled_cmd}\"."
    printf -v "_KNIT_CMD_${cmd}_3_${output}_description" '%s' "$3"
    printf -v "_KNIT_CMD_${cmd}_3_${output}_default"     '%s' "$2"
    printf -v "_KNIT_CMD_${cmd}_3_${output}_type"        '%s' "${param_type}"
    _knit_set_add "_KNIT_CMD_${cmd}_outputs" "${output}"
}

# ------------------------------------------------------------------------------
# @fn knit_with_extra()
#
# Adds a description for extra parameters coming after "--".
#
# @param description Description of the extra parameters.
# ------------------------------------------------------------------------------
knit_with_extra() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_with_extra should be used after a call to \"knit_register\"."
    fi
    local cmd="${_KNIT_CURRENT_COMMAND}"
    printf -v "_KNIT_CMD_${cmd}_extra" '%s' "$1"
}

# ------------------------------------------------------------------------------
# @fn knit_with_dispatch()
#
# Mark the command currently being registered as a dispatcher: a command that
# takes a target after "--" and forwards the remaining arguments to it (e.g.
# "submit" dispatches to a job, "setup" to a setup. This changes how "--help"
# renders the usage line, both for the dispatcher itself
# (`cmd [OPTIONS] -- <placeholder> [OPTIONS]`) and for its subcommands, which
# are invoked through it rather than directly.
#
# The description is stored as the extra-arguments description (as with
# knit_with_extra), so the "Extra" help section and the "extra allowed after
# --" argument check keep working. If no description is given, the placeholder
# is used.
#
# @param placeholder  Name shown after "--" in the usage line (e.g. "job").
# @param description  Optional description of the extra arguments.
# ------------------------------------------------------------------------------
knit_with_dispatch() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_with_dispatch should be used after a call to \"knit_register\"."
    fi
    _knit_wrapper_reject_declaration "knit_with_dispatch"
    local cmd="${_KNIT_CURRENT_COMMAND}"
    printf -v "_KNIT_CMD_${cmd}_dispatch" '%s' "$1"
    printf -v "_KNIT_CMD_${cmd}_extra"    '%s' "${2:-$1}"
}

# ------------------------------------------------------------------------------
# @fn knit_with_table()
#
# Declare a database table for recording invocations of the command currently
# being registered. Must be called between knit_register and knit_done.
#
# If no table name is given, the demangled command name is used (e.g.
# "foo:bar" for a subcommand "foo bar"). An error is raised if the same table
# name is claimed by more than one command.
#
# At knit_done time a callback checks whether the table already exists with the
# correct schema. If absent it is created; if the schema has changed it is
# migrated. The table always has an "id" (uuid) column first, followed by all
# required parameters, optional parameters, flags, and outputs, each group
# sorted alphabetically.
#
# Example:
# ```
# knit_register my_func "run" "Run an experiment."
# knit_with_required "count:integer" "Number of iterations."
# knit_with_table           # uses table name "run"
# knit_with_table "my_runs" # uses table name "my_runs"
# my_func() { ... }
# knit_done
# ```
#
# @param table_name Optional name of the database table. Defaults to the
#                   colon-separated command name.
# ------------------------------------------------------------------------------
knit_with_table() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_with_table must be called between knit_register and knit_done."
    fi

    local table_name
    if [[ $# -ge 1 && -n "$1" ]]; then
        table_name="$1"
    else
        table_name="${_KNIT_CURRENT_COMMAND_DEMANGLED}"
    fi

    if [[ -v _KNIT_DB_REGISTERED_TABLES["${table_name}"] ]]; then
        knit_fatal "Table \"${table_name}\" is already used by command \"${_KNIT_DB_REGISTERED_TABLES[${table_name}]}\"."
    fi

    _KNIT_DB_REGISTERED_TABLES["${table_name}"]="${_KNIT_CURRENT_COMMAND_DEMANGLED}"

    local cmd="${_KNIT_CURRENT_COMMAND}"
    printf -v "_KNIT_CMD_${cmd}_table" '%s' "${table_name}"

    _knit_push_done_cb _knit_db_setup_table "${cmd}" "${table_name}"
}

# ------------------------------------------------------------------------------
# @fn _knit_run_before()
#
# In the context of a knit_register, install a callback to run before the
# command currently being registered.
#
# Example:
# ```
# knit_register ...
# knit_run_before echo "Running before command"
# ```
# ------------------------------------------------------------------------------
_knit_run_before() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "_knit_run_before should be used after a call to \"knit_register\"."
    fi
    knit_trace "Adding callback to run before ${_KNIT_CURRENT_COMMAND_DEMANGLED}."
    local cmd="${_KNIT_CURRENT_COMMAND}"
    local cb_list_name="_KNIT_CMD_${cmd}_before_cb"
    # shellcheck disable=SC2178
    local -n cb_list_ref="${cb_list_name}"
    local cb
    printf -v cb "%q " "$@"
    cb_list_ref+=("${cb}")
}

# ------------------------------------------------------------------------------
# @fn _knit_execute_before_commands()
#
# Evaluate the callbacks installed before a command. The callbacks are called
# with the calling command name (demangled) as context, as well as the list of
# parameters passed to the command.
#
# @param cmd Command (mangled name) for which to execute the before callbacks.
# @param ... Arguments of the command.
# ------------------------------------------------------------------------------
_knit_execute_before_commands() {
    local cmd="$1"
    shift
    local demangled_cmd
    demangled_cmd=$(_knit_command_demangle "${cmd}")
    knit_trace "Executing callbacks before ${demangled_cmd}."
    local cb_list_name="_KNIT_CMD_${cmd}_before_cb"
    # shellcheck disable=SC2178
    local -n cb_list_ref="${cb_list_name}"
    for cb in "${cb_list_ref[@]}"; do
        # shellcheck disable=SC2209 # callback string pre-escaped with printf %q by _knit_run_before
        eval "${cb} $*"
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_run_after()
#
# In the context of a knit_register, install a callback to run after the
# command currently being registered.
#
# Example:
# ```
# knit_register ...
# knit_run_after echo "Running after command"
# ```
# ------------------------------------------------------------------------------
_knit_run_after() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "_knit_run_after should be used after a call to \"knit_register\"."
    fi
    knit_trace "Adding callback to run after ${_KNIT_CURRENT_COMMAND_DEMANGLED}."
    local cmd="${_KNIT_CURRENT_COMMAND}"
    local cb_list_name="_KNIT_CMD_${cmd}_after_cb"
    # shellcheck disable=SC2178
    local -n cb_list_ref="${cb_list_name}"
    local cb
    printf -v cb "%q " "$@"
    cb_list_ref+=("${cb}")
}

# ------------------------------------------------------------------------------
# @fn _knit_execute_after_commands()
#
# Evaluate the callbacks installed after a command. The callbacks are called
# with the calling command name (demangled) as context, as well as the list of
# parameters passed to the command.
#
# @param cmd Command (mangled name) for which to execute the after callbacks.
# @param ... Arguments of the command.
# ------------------------------------------------------------------------------
_knit_execute_after_commands() {
    local cmd="$1"
    shift
    local demangled_cmd
    demangled_cmd=$(_knit_command_demangle "${cmd}")
    knit_trace "Executing callbacks after ${demangled_cmd}."
    local cb_list_name="_KNIT_CMD_${cmd}_after_cb"
    # shellcheck disable=SC2178
    local -n cb_list_ref="${cb_list_name}"
    for cb in "${cb_list_ref[@]}"; do
        # shellcheck disable=SC2209 # callback string pre-escaped with printf %q by _knit_run_after
        eval "${cb} $*"
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_push_done_cb()
#
# In the context of a knit_register, push a callback to be called at the next
# call to knit_done. Multiple callbacks may be pushed; they are all called in
# reverse order of installation. The callback list is cleared after knit_done.
#
# @param ... Callback function and its arguments.
# ------------------------------------------------------------------------------
_knit_push_done_cb() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "_knit_push_done_cb should be used after a call to \"knit_register\"."
    fi
    knit_trace "Pushing done callback in ${_KNIT_CURRENT_COMMAND_DEMANGLED}."
    local cb
    printf -v cb "%q " "$@"
    _KNIT_DONE_CBS+=("${cb}")
}

# ------------------------------------------------------------------------------
# @fn _knit_check_argument_type()
#
# Validate that the value provided for a parameter conforms to the parameter's
# declared type. On mismatch the script stops with a fatal error; for enum types
# the message lists the accepted values. Parameters with no recorded type (e.g.
# framework-internal ones) are left unchecked.
#
# @param cmd Command the parameter belongs to (mangled).
# @param demangled_cmd Human-readable command name (used in messages).
# @param name Parameter name (normalized).
# @param value Value provided for the parameter.
# ------------------------------------------------------------------------------
_knit_check_argument_type() {
    local cmd="$1"
    local demangled_cmd="$2"
    local name="$3"
    local value="$4"
    local param_type
    _knit_param_type param_type "${cmd}" "${name}"
    if [[ -z "${param_type}" ]] || knit_type_check "${param_type}" "${value}"; then
        return 0
    fi
    local alt_format
    _knit_str_underscores_to_hyphens alt_format "${name}"
    local resolved
    _knit_type_resolve_alias resolved "${param_type}" || resolved=""
    if [[ -n "${resolved}" ]] && [[ -v _KNIT_ENUMS["${resolved}"] ]]; then
        local values
        values=$(knit_enum_values "${resolved}" ", ")
        knit_fatal "Parameter --${alt_format} of \"${demangled_cmd}\" expects one of: ${values} (got \"${value}\")."
    fi
    knit_fatal "Parameter --${alt_format} of \"${demangled_cmd}\" expects a value of type \"${param_type}\" (got \"${value}\")."
}

# ------------------------------------------------------------------------------
# @fn _knit_check_command_arguments()
#
# Check that the arguments expected by the command are provided. This function
# will fail with a fatal error (i.e. the script will stop) if a required
# argument is not provided, if an argument provided does not match any expected,
# or if a value does not conform to its parameter's declared type.
#
# @param cmd Name of the command (mangled).
# @param ... Arguments to pass to the command.
# ------------------------------------------------------------------------------
_knit_check_command_arguments() {
    local cmd="$1"
    local demangled_cmd
    demangled_cmd=$(_knit_command_demangle "${cmd}")
    shift
    local args=("$@")
    # Check that all the required arguments have been provided
    local required_args_varname="_KNIT_CMD_${cmd}_required"
    local option
    while read -r option; do
        if [[ -v "_KNIT_CMD_${cmd}_2_${option}_when" ]]; then continue; fi
        if knit_get_parameter "${option}" "${args[@]}" > /dev/null; then
            continue
        fi
        local alt_format
        _knit_str_underscores_to_hyphens alt_format "${option}"
        knit_fatal "Command \"${demangled_cmd}\" requires a --${option} or --${alt_format} option."
    done < <(_knit_set_iter "${required_args_varname}")
    # Check that all the arguments provided are expected options or flags
    local optional_args_varname="_KNIT_CMD_${cmd}_optional"
    local flags_args_varname="_KNIT_CMD_${cmd}_flags"
    local extra_varname="_KNIT_CMD_${cmd}_extra"
    for ((i=0; i<${#args[@]}; i++)); do
        local arg="${args[i]}"
        if [[ "${arg}" == "--" ]]; then
            if [ -z "${!extra_varname}" ]; then
                knit_fatal "Unexpected extra arguments passed to \"${demangled_cmd}\" command."
            fi
            break
        fi
        if [[ "${arg}" != --* ]]; then
            knit_fatal "Unexpected argument \"${arg}\" passed to \"${demangled_cmd}\" command."
        fi
        local name
        name="$(_knit_arg_name "${arg}")"
        # Required/optional parameters consume the following token as their
        # value, unless the value was supplied inline as "--name=value". Flags
        # never consume a token. The consumed value is checked against the
        # parameter's declared type.
        if _knit_set_find "${required_args_varname}" "${name}" \
        || _knit_set_find "${optional_args_varname}" "${name}"; then
            local value
            if [[ "${arg}" == --*=* ]]; then
                value="${arg#*=}"
            else
                i=$((i+1))
                value="${args[i]}"
            fi
            _knit_check_argument_type "${cmd}" "${demangled_cmd}" "${name}" "${value}"
            continue
        fi
        if _knit_set_find "${flags_args_varname}" "${name}"; then
            continue
        fi
        knit_fatal "Unexpected argument \"${arg}\" passed to \"${demangled_cmd}\" command."
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_find_flag()
#
# This function takes a flag and checks if it appears in the remaining list of
# arguments, returning 0 if it does, 1 otherwise.
#
# Example:
# ```
# _knit_find_option "--help" aaa bbb ccc --help ddd
# ```
# will return 0 because "--help" was found.
#
# @param flag Flag to find.
# @param ... List of arguments to search from.
# @return 0 if the flag was found, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_find_flag() {
    local flag
    flag=$(_knit_arg_name "$1")
    shift
    local list=("$@")

    local item
    for item in "${list[@]}"; do
        if [[ "${item}" == "--" ]]; then
            break
        fi
        if [[ "${item}" != --* ]]; then
            continue
        fi
        if [[ "$(_knit_arg_name "${item}")" == "${flag}" ]]; then
            return 0
        fi
    done

    return 1
}

# ------------------------------------------------------------------------------
# @fn _knit_expand_command_arguments()
#
# Adds optional arguments that are not provided in the arguments, and converts
# flags into --flag true or --flag false.
#
# @param name Name of the command.
# @param ... Arguments to pass to the command.
# ------------------------------------------------------------------------------
_knit_expand_command_arguments() {
    local cmd="$1"
    shift
    # Separate arguments and extra (after -- )
    local args=()
    local extra_args=()
    local done_with_args="false"
    for arg in "$@"; do
        if [[ "${arg}" == "--" ]]; then
            done_with_args="true"
            extra_args+=("${arg}")
        elif [[ "${done_with_args}" == "false" ]]; then
            # The "--name=value" form is handled by knit_get_parameter and the
            # argument validators, so tokens are passed through verbatim here.
            args+=("${arg}")
        else
            extra_args+=("${arg}")
        fi
    done
    # Add optional arguments that have not been provided
    local optional_args_varname="_KNIT_CMD_${cmd}_optional"
    while read -r option; do
        if knit_get_parameter "${option}" "${args[@]}" > /dev/null; then
            continue
        fi
        local default_value
        _knit_param_default default_value "${cmd}" "${option}"
        # Resolve an "ENV[NAME]" default against the current environment (see
        # _knit_resolve_default); ordinary defaults are returned unchanged.
        default_value=$(_knit_resolve_default "${default_value}")
        args+=("--${option}" "${default_value}")
    done < <(_knit_set_iter "${optional_args_varname}")
    # Handle flags (add them as option with value "true" or "false")
    local flags_args_varname="_KNIT_CMD_${cmd}_flags"
    local flag
    while read -r flag; do
        if _knit_find_flag "--${flag}" "${args[@]}"; then
            local i
            for i in "${!args[@]}"; do
                # Match by normalized name so a flag registered as "no_setup"
                # is found whether the user wrote --no-setup or --no_setup.
                if [[ "${args[$i]}" == --* ]] \
                    && [[ "$(_knit_arg_name "${args[$i]}")" == "${flag}" ]]; then
                    # Insert "true" after the flag
                    args=("${args[@]:0:i+1}" "true" "${args[@]:i+1}")
                    break
                fi
            done
        else
            args+=("--${flag}" "false")
        fi
    done < <(_knit_set_iter "${flags_args_varname}")
    # Print the resulting arguments NUL-separated so the caller can use readarray -d ''
    for arg in "${args[@]}" "${extra_args[@]}"; do
        printf '%s\0' "${arg}"
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_help_render_entry()
#
# Render a single "--help" entry (an option row or a subcommand row) with an
# optional word-wrapped, hanging-indented description:
#
#   <head><first words of the description>
#   <indent spaces><more words>
#   ...
#
# where <head> is the fully-formatted leading column (indentation, the padded
# option/subcommand name, and — for options — the "[annotation] " prefix) and
# continuation lines are indented to <indent> columns so the wrapped text forms
# a clean hanging indent under the description column.
#
# Wrapping is applied only when a usable terminal width is known and the
# continuation column is wide enough; otherwise the entry falls back to a single
# line ("<head><description>"), byte-for-byte identical to the pre-wrapping
# output, so piped or redirected help stays unchanged.
#
# @param width       Terminal width in columns, or 0 for "no wrapping".
# @param head        Literal leading text printed before the description on the
#                    first line (may contain ANSI escape sequences).
# @param head_len    Display width of <head> (escape bytes excluded), i.e. the
#                    column at which the first-line description begins.
# @param indent      Number of spaces used to indent continuation lines.
# @param description Description text, wrapped at word boundaries.
# ------------------------------------------------------------------------------
_knit_help_render_entry() {
    local width="$1"
    local head="$2"
    local head_len="$3"
    local indent="$4"
    local description="$5"

    # Minimum description column width below which wrapping carries too few words
    # per line to be worthwhile; fall back to a single line instead.
    local min_desc_col=24

    # Fallback: no usable width, or the continuation column would be too narrow.
    # Reproduces the historical single-line layout exactly.
    if (( width <= 0 )) || (( width - indent < min_desc_col )); then
        printf "%s%s\n" "${head}" "${description}"
        return 0
    fi

    # Split the description into words, collapsing runs of whitespace.
    local words
    read -r -a words <<< "${description}"
    if (( ${#words[@]} == 0 )); then
        printf "%s\n" "${head}"
        return 0
    fi

    local indent_pad
    printf -v indent_pad "%*s" "${indent}" ""

    # First line: the head, then as many words as fit within the terminal width.
    # Continuation lines start at the indent column. At least one word is placed
    # per line even if it overflows, so a single long word cannot stall.
    local line="${head}"
    local col="${head_len}"
    local first_on_line="true"
    local word
    for word in "${words[@]}"; do
        if [[ "${first_on_line}" == "true" ]]; then
            line+="${word}"
            col=$((col + ${#word}))
            first_on_line="false"
        elif (( col + 1 + ${#word} <= width )); then
            line+=" ${word}"
            col=$((col + 1 + ${#word}))
        else
            printf "%s\n" "${line}"
            line="${indent_pad}${word}"
            col=$((indent + ${#word}))
        fi
    done
    printf "%s\n" "${line}"
}

# ------------------------------------------------------------------------------
# @fn _knit_print_options_block()
#
# Print the "Options"-style listing for a single command: a titled section with
# an hrule, then (optionally) the "--help" entry, then the command's required
# parameters, optional parameters, and flags, each column-aligned. Extracted so
# it can be printed both for a command's own options and, for a subcommand
# invoked through a dispatcher, for the dispatcher's options as well.
#
# @param cmd       Mangled command name whose options to print.
# @param title     Section title (e.g. "Options" or "submit options").
# @param with_help "true" to include the "--help" entry, "false" otherwise.
# ------------------------------------------------------------------------------
_knit_print_options_block() {
    local cmd="$1"
    local title="$2"
    local with_help="$3"

    local required_args_varname="_KNIT_CMD_${cmd}_required"
    local optional_args_varname="_KNIT_CMD_${cmd}_optional"
    local flags_args_varname="_KNIT_CMD_${cmd}_flags"

    local hrule
    printf -v hrule "%*s" "${#title}" ""
    hrule="${hrule// /-}"
    printf "%s\n%s\n" "${title}" "${hrule}"

    local max_opt_length=4 # size of "help"
    local opt
    local opt2
    while read -r opt; do
        opt2="--${opt} <value>"
        local opt_length=${#opt2}
        if (( opt_length > max_opt_length )); then
            max_opt_length=${opt_length}
        fi
    done < <(_knit_set_iter "${required_args_varname}")
    while read -r opt; do
        opt2="--${opt} <value>"
        local opt_length=${#opt2}
        if (( opt_length > max_opt_length )); then
            max_opt_length=${opt_length}
        fi
    done < <(_knit_set_iter "${optional_args_varname}")
    while read -r opt; do
        opt2="--${opt}"
        local opt_length=${#opt2}
        if (( opt_length > max_opt_length )); then
            max_opt_length=${opt_length}
        fi
    done < <(_knit_set_iter "${flags_args_varname}")

    local description
    local default

    # Word-wrap descriptions under the annotation column when a usable terminal
    # width is known; the helper falls back to today's single-line layout for
    # pipes/redirects and narrow terminals.
    local width
    _knit_terminal_width width
    local indent=$((2 + max_opt_length + 2))
    local head

    if [[ "${with_help}" == "true" ]]; then
        printf -v head "  %-${max_opt_length}s  " "--help"
        _knit_help_render_entry "${width}" "${head}" "${#head}" "${indent}" \
            "Print this help message and exit."
    fi
    while read -r opt; do
        _knit_param_description description "${cmd}" "${opt}"
        _knit_str_underscores_to_hyphens opt2 "${opt}"
        opt2="--${opt2}"
        local when_raw_var="_KNIT_CMD_${cmd}_2_${opt}_when_raw"
        local annotation="required"
        if [[ -v "${when_raw_var}" ]]; then
            annotation="required, when: ${!when_raw_var}"
        fi
        printf -v head "  %-${max_opt_length}s  [%s] " "${opt2} <value>" "${annotation}"
        _knit_help_render_entry "${width}" "${head}" "${#head}" "${indent}" "${description}"
    done < <(_knit_set_iter "${required_args_varname}")
    while read -r opt; do
        _knit_param_description description "${cmd}" "${opt}"
        _knit_param_default default "${cmd}" "${opt}"
        _knit_str_underscores_to_hyphens opt2 "${opt}"
        opt2="--${opt2}"
        local when_raw_var="_KNIT_CMD_${cmd}_2_${opt}_when_raw"
        local annotation="default: '${default}'"
        if [[ -v "${when_raw_var}" ]]; then
            annotation="default: '${default}', when: ${!when_raw_var}"
        fi
        printf -v head "  %-${max_opt_length}s  [%s] " "${opt2} <value>" "${annotation}"
        _knit_help_render_entry "${width}" "${head}" "${#head}" "${indent}" "${description}"
    done < <(_knit_set_iter "${optional_args_varname}")
    while read -r opt; do
        _knit_param_description description "${cmd}" "${opt}"
        _knit_str_underscores_to_hyphens opt2 "${opt}"
        opt2="--${opt2}"
        local when_raw_var="_KNIT_CMD_${cmd}_2_${opt}_when_raw"
        local annotation="flag"
        if [[ -v "${when_raw_var}" ]]; then
            annotation="flag, when: ${!when_raw_var}"
        fi
        printf -v head "  %-${max_opt_length}s  [%s] " "${opt2}" "${annotation}"
        _knit_help_render_entry "${width}" "${head}" "${#head}" "${indent}" "${description}"
    done < <(_knit_set_iter "${flags_args_varname}")
}

# ------------------------------------------------------------------------------
# @fn _knit_print_command_usage()
#
# Print the help message for a command/subcommand.
#
# @param ...cmds Command and subcommand names
# ------------------------------------------------------------------------------
_knit_print_command_usage() {
    local cmd
    cmd=$(_knit_command_mangle "$*")
    local display
    display=$(_knit_command_with_space "${cmd}")
    local extra_var="_KNIT_CMD_${cmd}_extra"
    local dispatch_var="_KNIT_CMD_${cmd}_dispatch"

    # A subcommand invoked through a dispatcher (e.g. a job under "submit") is
    # not run as "<parent> <name>" but as "<parent> [OPTIONS] -- <name>
    # [OPTIONS]". Detect that case from the parent's dispatch marker so the
    # usage line reflects the real grammar.
    local parent
    _knit_command_get_parents parent "${cmd}"
    local parent_is_dispatcher="false"
    if [[ -n "${parent}" ]]; then
        local parent_dispatch_var="_KNIT_CMD_${parent}_dispatch"
        if [[ -v "${parent_dispatch_var}" && -n "${!parent_dispatch_var}" ]]; then
            parent_is_dispatcher="true"
        fi
    fi

    if [[ "${cmd}" == "__main__" ]]; then
        printf "Usage: %s [OPTIONS]\n\n" "$0"
    elif [[ -n "${!dispatch_var}" ]]; then
        printf "Usage: %s %s [OPTIONS] -- <%s> [OPTIONS]\n\n" \
            "$0" "${display}" "${!dispatch_var}"
    elif [[ "${parent_is_dispatcher}" == "true" ]]; then
        local parent_display leaf
        parent_display=$(_knit_command_with_space "${parent}")
        _knit_command_get_last leaf "${cmd}"
        printf "Usage: %s %s [OPTIONS] -- %s [OPTIONS]\n\n" \
            "$0" "${parent_display}" "${leaf}"
    elif [ -z "${!extra_var}" ]; then
        printf "Usage: %s %s [OPTIONS]\n\n" "$0" "${display}"
    else
        printf "Usage: %s %s [OPTIONS] -- [EXTRA]\n\n" "$0" "${display}"
    fi

    local description_var="_KNIT_CMD_${cmd}_description"
    printf "  %s\n\n" "${!description_var}"

    _knit_print_options_block "${cmd}" "Options" "true"

    # For a subcommand invoked through a dispatcher, also list the dispatcher's
    # own options (e.g. "submit"'s --setup, "setup"'s --path), which are passed
    # before the "--".
    if [[ "${parent_is_dispatcher}" == "true" ]]; then
        local parent_display
        parent_display=$(_knit_command_with_space "${parent}")
        printf "\n"
        _knit_print_options_block "${parent}" "${parent_display} options" "false"
    fi

    # Free-form requirement notes (e.g. a job's knit_with_setup requirement).
    local -n notes_ref="_KNIT_CMD_${cmd}_notes"
    if [[ "${#notes_ref[@]}" -gt 0 ]]; then
        printf "\nRequirements\n------------\n"
        local note
        for note in "${notes_ref[@]}"; do
            printf "  %s\n" "${note}"
        done
    fi

    local subcommands=()
    local subcommands_full=()
    local subcommands_highlight=()
    local max_subcommand_len=0
    local c
    # Highlighting is cosmetic and applied only when stdout is a terminal and the
    # NO_COLOR environment variable is unset (the de-facto standard). When output
    # is piped or redirected, names are printed plain so scripts and tests are
    # unaffected.
    local use_color="false"
    if [[ -z "${NO_COLOR+x}" ]] && _knit_stdout_is_terminal; then
        use_color="true"
    fi
    # The direct children come straight from the tree adjacency, in registration
    # order: the root commands for "__main__", else the command's own list.
    local children_var
    if [[ "${cmd}" == "__main__" ]]; then
        children_var="_KNIT_ROOT_COMMANDS"
    else
        children_var="_KNIT_CMD_${cmd}_subcommands"
    fi
    local -n children_ref="${children_var}"
    # Before bootstrap, also omit any child that is not usable before bootstrap:
    # it cannot run yet (the runtime guard would refuse it), so listing it would
    # be misleading. After bootstrap every non-hidden child is listed. The usable
    # set is a connected subtree (validation rule 3), so this per-level test is
    # sufficient: a usable child shown at a deeper level always has a usable
    # (hence shown) parent.
    local pre_bootstrap="false"
    _knit_is_bootstrapped || pre_bootstrap="true"
    for c in "${children_ref[@]}"; do
        if _knit_command_hidden "${c}"; then
            continue
        fi
        if [[ "${pre_bootstrap}" == "true" ]] \
            && ! _knit_command_is_usable_before_bootstrap "${c}"; then
            continue
        fi
        local name
        _knit_command_get_last name "${c}"
        subcommands+=("${name}")
        subcommands_full+=("${c}")
        local highlight="false"
        if [[ "${use_color}" == "true" ]] && _knit_command_highlighted "${c}"; then
            highlight="true"
        fi
        subcommands_highlight+=("${highlight}")
        if ((max_subcommand_len < ${#name})); then
            max_subcommand_len=${#name}
        fi
    done
    if [ "${#subcommands[@]}" -gt "0" ]; then
        local sub_name="_KNIT_CMD_${cmd}_subcommand_title"
        sub_name=${!sub_name}
        local hrule
        printf -v hrule "%*s" "${#sub_name}" ""
        hrule="${hrule// /-}"
        printf "\n%s\n%s\n" "${sub_name}" "${hrule}"
        # Descriptions wrap under the description column when a usable terminal
        # width is known; the head (indent + right-justified name + gap) is a
        # fixed display width, so continuation lines hang at that same column.
        local width
        _knit_terminal_width width
        local sub_indent=$((2 + max_subcommand_len + 3))
        local i
        for ((i=0; i<${#subcommands[@]}; i++)); do
            local description_var="_KNIT_CMD_${subcommands_full[i]}_description"
            local description="${!description_var}"
            local head
            if [[ "${subcommands_highlight[i]}" == "true" ]]; then
                # Right-justify on the PLAIN name length (a %*s field width would
                # count the ANSI escape bytes and misalign the column), then emit
                # the bold name manually. The head's display width is unchanged.
                local pad
                printf -v pad "%*s" "$((max_subcommand_len - ${#subcommands[i]}))" ""
                head="  ${pad}${_KNIT_COLORS[bold]}${subcommands[i]}${_KNIT_COLORS[reset]}   "
            else
                printf -v head "  %${max_subcommand_len}s   " "${subcommands[i]}"
            fi
            _knit_help_render_entry "${width}" "${head}" "${sub_indent}" \
                "${sub_indent}" "${description}"
        done
    fi

    if [ -n "${!extra_var}" ]; then
        printf "\nExtra"
        printf "\n-----\n"
        printf "  %s\n" "${!extra_var}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_build_constraint_json()
#
# Build a jq JSON object from an expanded argument list, using type metadata to
# emit integers/reals/booleans as JSON native types and all other values as
# strings. Each parameter may be given as "--name value" or "--name=value"
# (flags already converted to "true"/"false" by _knit_expand_command_arguments).
#
# @param cmd Mangled command name (used for type lookups).
# @param ... Expanded argument list.
# ------------------------------------------------------------------------------
_knit_build_constraint_json() {
    local cmd="$1"
    shift
    local jq_args=("-n")
    local i=1
    while (( i <= $# )); do
        local token="${!i}"
        [[ "${token}" == "--" ]] && break
        local key val
        key=$(_knit_arg_name "${token}")
        if [[ "${token}" == --*=* ]]; then
            # Inline "--name=value": value is part of the token.
            val="${token#*=}"
            i=$(( i + 1 ))
        else
            # Separate "--name value": value is the following token.
            i=$(( i + 1 ))
            val="${!i}"
            i=$(( i + 1 ))
        fi
        local type_var="_KNIT_CMD_${cmd}_2_${key}_type"
        local param_type="${!type_var:-string}"
        case "${param_type}" in
            integer|real|boolean) jq_args+=("--argjson" "${key}" "${val}") ;;
            *)                    jq_args+=("--arg"      "${key}" "${val}") ;;
        esac
    done
    _knit_jq "${jq_args[@]}" "\$ARGS.named"
}

# ------------------------------------------------------------------------------
# @fn _knit_check_constraints()
#
# Evaluate all --when constraints declared for a command against the provided
# arguments. For each constrained parameter:
#   - If the condition evaluates to true and the parameter is required but absent
#     from the original (user-provided) arguments, a fatal error is raised.
#   - If the condition evaluates to false and the parameter is present in the
#     original arguments, a fatal error is raised.
# Returns 0 immediately when the experiment is not bootstrapped (jq unavailable).
#
# @param cmd Mangled command name.
# @param orig_ref Name of bash array holding the original (pre-expansion) args.
# @param exp_ref  Name of bash array holding the expanded args.
# ------------------------------------------------------------------------------
_knit_check_constraints() {
    if ! _knit_is_bootstrapped; then return 0; fi
    local cmd="$1"
    local -n _orig_ref="$2"
    local -n _exp_ref="$3"

    # Early exit if no constrained params exist (avoids needless jq invocation).
    local _has_constraints=false
    local _set_name _param
    for _set_name in required optional flags; do
        while IFS= read -r _param; do
            [[ -v "_KNIT_CMD_${cmd}_2_${_param}_when" ]] && { _has_constraints=true; break 2; }
        done < <(_knit_set_iter "_KNIT_CMD_${cmd}_${_set_name}")
    done
    [[ "${_has_constraints}" == "false" ]] && return 0

    local demangled_cmd
    demangled_cmd=$(_knit_command_demangle "${cmd}")

    local json
    json=$(_knit_build_constraint_json "${cmd}" "${_exp_ref[@]}")

    local set_name param when_var when_expr cond_result user_provided
    for set_name in required optional flags; do
        while IFS= read -r param; do
            when_var="_KNIT_CMD_${cmd}_2_${param}_when"
            [[ ! -v "${when_var}" ]] && continue
            when_expr="${!when_var}"
            cond_result=$(_knit_jq -n --argjson _obj "${json}" "\$_obj | ${when_expr}")
            if [[ "${cond_result}" != "true" && "${cond_result}" != "false" ]]; then
                knit_fatal "Constraint expression for --${param} in \"${demangled_cmd}\" did not evaluate to a boolean."
            fi
            user_provided=false
            if [[ "${set_name}" == "flags" ]]; then
                _knit_find_flag "--${param}" "${_orig_ref[@]}" && user_provided=true
            else
                knit_get_parameter "${param}" "${_orig_ref[@]}" > /dev/null && user_provided=true
            fi
            if [[ "${cond_result}" == "true" ]]; then
                if [[ "${set_name}" == "required" && "${user_provided}" == "false" ]]; then
                    local alt_format
                    _knit_str_underscores_to_hyphens alt_format "${param}"
                    knit_fatal "Command \"${demangled_cmd}\" requires --${param} or --${alt_format} when the constraint is satisfied."
                fi
            else
                if [[ "${user_provided}" == "true" ]]; then
                    knit_fatal "Parameter --${param} must not be provided for command \"${demangled_cmd}\" when the constraint is not satisfied."
                fi
            fi
        done < <(_knit_set_iter "_KNIT_CMD_${cmd}_${set_name}")
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_invoke_command()
#
# Invoke a command.
#
# Example:
# ```
# _knit_invoke_command "say" "hello" "--name" "Matthieu"
# ```
# Will invoke the command "say:hello" with arguments "--name" and "Matthieu".
#
# @param ...commands Commands and subcommands.
# @param ...args Arguments for the command.
# ------------------------------------------------------------------------------
_knit_invoke_command() {
    # Capture the call-site alias (set by knit_as) for this invocation before any
    # before-callback can invoke a nested command and consume it. One-shot: cleared
    # here so only this invocation's frame carries it, and pushed onto the frame's
    # alias slot at each push site below.
    local _knit_call_alias="${_KNIT_CALL_ALIAS}"
    _KNIT_CALL_ALIAS=""
    # find the command and subcommands
    local demangled_cmd=""
    while [[ $# -gt 0 ]]; do
        if [[ $1 == --* ]]; then
            break
        fi
        if [[ -n "${demangled_cmd}" ]]; then
            demangled_cmd+=" "
        fi
        demangled_cmd+="$1"
        shift
        # Stop consuming tokens once the accumulated command is a wrapper: a
        # wrapper forwards everything after its name verbatim, so its arguments
        # (which need not start with "--") must not be mistaken for further
        # subcommand names.
        if _knit_command_is_wrapper "$(_knit_command_mangle "${demangled_cmd}")"; then
            break
        fi
    done
    # create the mangled command name
    local cmd
    cmd=$(_knit_command_mangle "${demangled_cmd}")
    # check if the command exists
    if ! _knit_set_find _KNIT_COMMANDS "${cmd}"; then
        knit_fatal "Unknown command \"${demangled_cmd}\"."
    fi
    # Central runtime guard: before bootstrap, refuse any command not declared
    # usable before bootstrap, with one uniform message, rather than letting it
    # fail deep inside for want of a provisioned binary. Introspection stays
    # available: a "--help" invocation (the only help form, for both wrappers and
    # ordinary commands, is "$1 == --help") is never gated. Commands invoked as
    # part of the bootstrap command itself run before ".knit/" exists yet must be
    # allowed through, so the guard also stands down while bootstrapping.
    if [[ "${1:-}" != "--help" ]] \
        && [[ "${_KNIT_IS_BOOTSTRAPPING}" != "true" ]] \
        && ! _knit_command_is_usable_before_bootstrap "${cmd}" \
        && ! _knit_is_bootstrapped; then
        knit_fatal "Command \"${demangled_cmd}\" requires bootstrap. Run \"$0 bootstrap\" first."
    fi
    # Usability guard: a command may declare knit_usable_if predicates that must
    # all hold for it to run. Enforced here, after the bootstrap guard and before
    # the wrapper/normal split, so it covers every invocation path uniformly.
    # A "--help" invocation is exempt so usage stays introspectable even when the
    # command cannot currently run.
    if [[ "${1:-}" != "--help" ]]; then
        local _knit_usable_reason=""
        if ! _knit_command_check_usable _knit_usable_reason "${cmd}"; then
            knit_fatal "Command \"${demangled_cmd}\" cannot run: ${_knit_usable_reason}"
        fi
    fi
    # get the name of the corresponding function
    local func_name_var="_KNIT_CMD_${cmd}_function"
    local func="${!func_name_var}"
    # A wrapper forwards its arguments verbatim to the underlying function: no
    # --help interception, no argument validation, expansion, or --when checks.
    # Callbacks still run around it, and the invocation is recorded (as a single
    # "args" column) when the wrapper declared a table.
    if _knit_command_is_wrapper "${cmd}"; then
        local table_var="_KNIT_CMD_${cmd}_table"
        if [[ -n "${!table_var:-}" ]] && _knit_is_bootstrapped; then
            _knit_db_setup_table "${cmd}" "${!table_var}"
        fi
        _knit_execute_before_commands "${cmd}" "$@"
        declare -gA "_KNIT_CMD_${cmd}_output_value=()"
        unset "_KNIT_CMD_${cmd}_row_id"
        unset "_KNIT_CMD_${cmd}_recorded"
        # A wrapper forwards to an external tool that may source third-party
        # shell scripts which assign to common variable names without declaring
        # them local (e.g. Spack's setup-env.sh runs `for cmd in ...`). Under
        # bash dynamic scoping such a write would clobber our local "cmd" for the
        # post-body steps below, corrupting the recorded command. Snapshot the
        # command under a namespaced name the external body will not touch.
        local _knit_wrapper_cmd="${cmd}"
        _KNIT_EXECUTING_COMMAND+=("${cmd}")
        _KNIT_EXECUTING_ROW_ID+=("$(_knit_resolve_row_id "${cmd}")")
        _KNIT_EXECUTING_START_TIME+=("$(_knit_prov_now)")
        _KNIT_EXECUTING_ALIAS+=("${_knit_call_alias}")
        $func "$@"
        local wrapper_status=$?
        # Keep the command on the stack through the after-callbacks (see the
        # non-wrapper path below) so they too may call knit_output.
        _knit_execute_after_commands "${_knit_wrapper_cmd}" "$@"
        # Record while this frame is still on the executing stacks, so recording
        # reads the frame's resolved row id from _KNIT_EXECUTING_ROW_ID (and, in a
        # later milestone, resolves its parent from the frame below). Then pop.
        _knit_record_invocation "${_knit_wrapper_cmd}" "$@"
        unset '_KNIT_EXECUTING_COMMAND[-1]'
        unset '_KNIT_EXECUTING_ROW_ID[-1]'
        unset '_KNIT_EXECUTING_START_TIME[-1]'
        unset '_KNIT_EXECUTING_ALIAS[-1]'
        return "${wrapper_status}"
    fi
    # check if the first argument is --help
    if [ "$1" = "--help" ]; then
        _knit_print_command_usage "${cmd}"
        return 0
    fi
    # check the arguments
    _knit_check_command_arguments "${cmd}" "$@"
    # expand missing optional arguments and flags
    # shellcheck disable=SC2034 # passed by name to _knit_check_constraints
    local -a original_args=("$@")
    local -a args
    readarray -d '' -t args < <(_knit_expand_command_arguments "${cmd}" "$@")
    # validate --when constraints
    _knit_check_constraints "${cmd}" original_args args
    # Ensure the command's table exists before it runs. Table creation is
    # deferred at registration when the experiment is not yet bootstrapped, so
    # create/migrate it now, on first use, once we are bootstrapped.
    local table_var="_KNIT_CMD_${cmd}_table"
    if [[ -n "${!table_var:-}" ]] && _knit_is_bootstrapped; then
        _knit_db_setup_table "${cmd}" "${!table_var}"
    fi
    # call the "before" callbacks
    _knit_execute_before_commands "${cmd}" "${args[@]}"
    # Start each invocation with a clean recording slate (outputs + row id) so a
    # previous invocation in the same process cannot leak stale values.
    declare -gA "_KNIT_CMD_${cmd}_output_value=()"
    unset "_KNIT_CMD_${cmd}_row_id"
    unset "_KNIT_CMD_${cmd}_recorded"
    # call the function
    _KNIT_EXECUTING_COMMAND+=("${cmd}")
    _KNIT_EXECUTING_ROW_ID+=("$(_knit_resolve_row_id "${cmd}")")
    _KNIT_EXECUTING_START_TIME+=("$(_knit_prov_now)")
    _KNIT_EXECUTING_ALIAS+=("${_knit_call_alias}")
    $func "${args[@]}"
    local func_status=$?
    # call the "after" callbacks. The command stays on _KNIT_EXECUTING_COMMAND
    # for their duration (popped only afterwards) so an after-callback may call
    # knit_output, just like the command body can. The output map has already
    # been reset (before the body), so after-callback outputs are recorded.
    _knit_execute_after_commands "${cmd}" "${args[@]}"
    # Record this invocation as a database row (if the command declared a table)
    # while it is still on the executing stacks, so recording reads this frame's
    # resolved row id from _KNIT_EXECUTING_ROW_ID (see the wrapper path). Then pop.
    _knit_record_invocation "${cmd}" "${args[@]}"
    unset '_KNIT_EXECUTING_COMMAND[-1]'
    unset '_KNIT_EXECUTING_ROW_ID[-1]'
    unset '_KNIT_EXECUTING_START_TIME[-1]'
    unset '_KNIT_EXECUTING_ALIAS[-1]'
    return "${func_status}"
}

# ------------------------------------------------------------------------------
# @fn knit_get_parameter()
#
# Search the list of arguments for a specific parameter. If found, the function
# will print the value associated with the parameter (flags will lead to this
# function printing "true" or "false"). If not found, this function will print
# nothing and return 1.
#
# The parameter value may be supplied either as two tokens ("--name value") or
# inline with an equals sign ("--name=value"); both forms are recognized.
#
# @param param Parameter to search for (without the -- prefix).
# @param ... Arguments in which to search for the parameter.
# ------------------------------------------------------------------------------
knit_get_parameter() {
    local param
    _knit_str_hyphens_to_underscores param "$1"
    shift
    local list=("$@")
    local i
    for ((i=0; i < ${#list[@]}; i++)); do
        local item="${list[i]}"
        if [[ "${item}" == "--" ]]; then
            break
        fi
        # Only "--"-prefixed tokens can be parameter names; skipping bare values
        # avoids mistaking a value such as "frame-color" for a parameter name.
        if [[ "${item}" != --* ]]; then
            continue
        fi
        if [[ "$(_knit_arg_name "${item}")" != "${param}" ]]; then
            continue
        fi
        # Inline "--name=value": the value is part of the token.
        if [[ "${item}" == --*=* ]]; then
            printf "%s" "${item#*=}"
            return 0
        fi
        # Separate "--name value": the value is the following token.
        if ((i + 1 < ${#list[@]})); then
            printf "%s" "${list[i+1]}"
            return 0
        fi
        return 1
    done
    return 1
}

# ------------------------------------------------------------------------------
# @fn knit_output()
#
# Record a named output value from within a registered command function.
# Fails if called outside of an executing command, if the name was not declared
# with knit_with_output, or if the value does not match the declared type.
#
# @param name  Output name (hyphens and underscores are interchangeable).
# @param value Value to record.
# ------------------------------------------------------------------------------
knit_output() {
    local name="$1"
    local value="$2"
    # Suppressed on non-root ranks of a run: discard the output but warn, so users
    # learn to guard knit_output with a rank-0 check (only rank 0 records a run).
    if [[ -n "${_KNIT_RECORDING_SUPPRESSED}" ]]; then
        knit_warning "Recording is suppressed on this rank; output \"${name}\" is discarded. Guard knit_output with a rank-0 check (e.g. [[ \"\${KNIT_MPI_RANK}\" == 0 ]])."
        return 0
    fi
    if [[ ${#_KNIT_EXECUTING_COMMAND[@]} -eq 0 ]]; then
        knit_fatal "knit_output should be called from within a registered command function."
    fi
    local cmd="${_KNIT_EXECUTING_COMMAND[-1]}"
    local demangled_cmd
    demangled_cmd=$(_knit_command_demangle "${cmd}")
    local normalized
    normalized=$(_knit_name_normalize "${name}")
    if ! _knit_set_find "_KNIT_CMD_${cmd}_outputs" "${normalized}"; then
        knit_fatal "\"${name}\" is not a declared output of command \"${demangled_cmd}\"."
    fi
    local type
    _knit_output_type type "${cmd}" "${normalized}"
    if ! knit_type_check "${type}" "${value}"; then
        knit_fatal "Output \"${name}\" expects type \"${type}\" but got \"${value}\"."
    fi
    knit_trace "Setting output \"${name}\" = \"${value}\" for command \"${demangled_cmd}\"."
    local -n output_ref="_KNIT_CMD_${cmd}_output_value"
    # shellcheck disable=SC2034 # output_ref is a nameref
    output_ref["${normalized}"]="${value}"
}

# ------------------------------------------------------------------------------
# @fn _knit_set_row_id()
#
# Set the "id" value of the row that will be recorded for the currently
# executing command (see M10 run recording). Use this when a command already
# owns a canonical identifier — e.g. `knit submit` records the job UUID it
# generated — instead of letting recording mint a fresh uuid. Must be called
# from within an executing command function.
#
# @param id The uuid to record as the row's id.
# ------------------------------------------------------------------------------
_knit_set_row_id() {
    local id="$1"
    if [[ ${#_KNIT_EXECUTING_COMMAND[@]} -eq 0 ]]; then
        knit_fatal "_knit_set_row_id should be called from within a registered command function."
    fi
    local cmd="${_KNIT_EXECUTING_COMMAND[-1]}"
    printf -v "_KNIT_CMD_${cmd}_row_id" '%s' "${id}"
    # Keep the executing-row-id stack in sync so the id a nested child resolves as
    # its parent, and the id ultimately recorded, both reflect this override
    # rather than the fresh id resolved when the frame was pushed.
    _KNIT_EXECUTING_ROW_ID[-1]="${id}"
}

# ------------------------------------------------------------------------------
# @fn _knit_resolve_row_id()
#
# Resolve the row id for an invocation of a command, used when its frame is
# pushed onto _KNIT_EXECUTING_ROW_ID. The precedence is: an explicit id already
# set via _knit_set_row_id (_KNIT_CMD_<cmd>_row_id), otherwise a fresh uuidv7.
#
# Every invocation gets its own distinct id: the historical couplings that made a
# job body reuse its submission's UUID (KNIT_JOB_PREFIX) and an app's rank-0 row
# reuse its run's UUID (KNIT_RUN_ID) are gone — the provenance edge, not a shared
# id, links a child back to its parent.
#
# @param cmd Mangled command name.
# ------------------------------------------------------------------------------
_knit_resolve_row_id() {
    local cmd="$1"
    local rowid_var="_KNIT_CMD_${cmd}_row_id"
    if [[ -n "${!rowid_var:-}" ]]; then
        printf '%s' "${!rowid_var}"
    else
        _knit_uuidv7
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_record_row_now()
#
# Record the current invocation's database row immediately, instead of waiting
# for the automatic post-invocation recording. Use this when a command must
# persist its row before doing blocking work whose side effects update that same
# row — e.g. knit submit records the submission before a --wait dispatch, so the
# job's own state transitions (running/completed) land on an existing row.
# Recording is idempotent: the automatic recording afterwards sees this one and
# does not insert a duplicate. Must be called from within an executing command.
#
# @param ... The invocation arguments (params/flags to record).
# ------------------------------------------------------------------------------
_knit_record_row_now() {
    if [[ ${#_KNIT_EXECUTING_COMMAND[@]} -eq 0 ]]; then
        knit_fatal "_knit_record_row_now should be called from within a registered command function."
    fi
    _knit_record_invocation "${_KNIT_EXECUTING_COMMAND[-1]}" "$@"
}

# ------------------------------------------------------------------------------
# @fn knit_as()
#
# Name a call so distinct invocations of the same command can be told apart in a
# query. Used at a call site as `knit_as <alias> <cmd> …`: it records <alias> on
# the provenance "call" edge of the delegated invocation, then runs
# `knit <cmd> …`. A later query addresses each call independently by its alias
# (an edge property). Without knit_as a call edge has a NULL alias.
#
# ```
# knit_as fast run --procs 8 -- mcrank
# knit_as slow run --procs 1 -- mcrank
# ```
#
# The alias is one-shot: it lands only on the directly named call's edge, never
# on the nested edges that call's body records. It is validated at the call site:
# it must be non-empty, must not be a registered table name (which would collide
# with a node label in a query), and must not already have been used within the
# current invocation (two edges sharing an alias would be indistinguishable).
#
# @param alias The name to record on the call edge.
# @param cmd   The command to invoke (followed by its arguments).
# @param ...   Arguments for the command.
# ------------------------------------------------------------------------------
knit_as() {
    local alias="$1"
    if [[ -z "${alias}" ]]; then
        knit_fatal "knit_as requires a non-empty alias."
    fi
    shift
    if [[ $# -eq 0 ]]; then
        knit_fatal "knit_as requires a command to invoke (usage: knit_as <alias> <cmd> …)."
    fi
    if [[ -v _KNIT_DB_REGISTERED_TABLES["${alias}"] ]]; then
        knit_fatal "knit_as alias \"${alias}\" collides with a registered table name."
    fi
    # Reuse is scoped to the calling invocation (its row id, empty at root), so the
    # same alias may be used under different parents but not twice under one.
    local parent_id=""
    if [[ ${#_KNIT_EXECUTING_ROW_ID[@]} -gt 0 ]]; then
        parent_id="${_KNIT_EXECUTING_ROW_ID[-1]}"
    fi
    local used_key="${parent_id}:${alias}"
    if [[ -v _KNIT_USED_ALIASES["${used_key}"] ]]; then
        knit_fatal "knit_as alias \"${alias}\" is already used in this invocation."
    fi
    _KNIT_USED_ALIASES["${used_key}"]="1"
    # Hand the alias to the next invocation, which captures and clears it.
    _KNIT_CALL_ALIAS="${alias}"
    knit "$@"
}

# ------------------------------------------------------------------------------
# @fn _knit_provenance_enabled()
#
# Decide whether an invocation of a command participates in the provenance graph:
# a participating command records a "call" edge and acts as an in-process source
# frame for the commands it invokes; a non-participating one is transparent (no
# edge, and skipped when a callee resolves its edge source — see
# _knit_resolve_source_context).
#
# The effective setting is resolved in this order (innermost/most-specific wins):
#
#   1. the command's own explicit mark (knit_with_provenance -> "with",
#      knit_without_provenance -> "without"), if any;
#   2. otherwise the nearest marked lexical ancestor's mark, walking the
#      colon-nested command name up via _knit_command_get_parents (e.g.
#      "a:b:c" -> "a:b" -> "a"), so one mark on a parent governs a whole subtree;
#   3. otherwise the default by visibility: hidden commands (marked via
#      knit_hidden, e.g. the "_run" worker) are transparent so internal plumbing
#      never shows up in the graph; every other (visible) command participates.
#
# Inheritance is over the lexical command hierarchy (the names), not the runtime
# call stack. Data-row recording (knit_with_table) is orthogonal to this.
#
# Returns 0 (success) when the command participates, 1 otherwise.
#
# @param cmd Mangled command name.
# ------------------------------------------------------------------------------
_knit_provenance_enabled() {
    local cmd="$1"
    # 1./2. Own explicit mark, then the nearest marked lexical ancestor.
    local c="${cmd}"
    while [[ -n "${c}" ]]; do
        local mark_var="_KNIT_CMD_${c}_provenance"
        case "${!mark_var:-}" in
            with)    return 0 ;;
            without) return 1 ;;
        esac
        _knit_command_get_parents c "${c}"
    done
    # 3. Default by visibility.
    local hidden_var="_KNIT_CMD_${cmd}_is_hidden"
    [[ "${!hidden_var:-false}" != "true" ]]
}

# ------------------------------------------------------------------------------
# @fn _knit_resolve_source_context()
#
# Resolve the source of the currently-recording invocation's "call" edge (the
# caller), writing the source's row id and demangled command name into the two
# named output variables. The recording invocation is the edge's target. The
# precedence (innermost wins) is:
#
#   1. In-process caller frame — the nearest participating frame below the top of
#      _KNIT_EXECUTING_COMMAND (transparent frames, per _knit_provenance_enabled,
#      are skipped). Covers in-process nesting and setup dispatch (boundaries
#      B1/B4). Its id comes from the parallel _KNIT_EXECUTING_ROW_ID stack.
#   2. Exported env — KNIT_SOURCE_ID / KNIT_SOURCE_COMMAND, set by a caller across
#      a process boundary (a job's batch script, a run's launcher subshell;
#      boundaries B2/B3, wired in later milestones) and read by the first command
#      in the re-entered process, which has no in-process caller.
#   3. Root — neither available: both outputs are empty.
#
# The current frame is the top of the stacks (it is recorded before being
# popped), so the in-process search starts one below the top.
#
# @param out_id   Name of the variable to receive the source row id.
# @param out_name Name of the variable to receive the source command name.
# ------------------------------------------------------------------------------
_knit_resolve_source_context() {
    local -n _knit_rsc_out_id="$1"
    local -n _knit_rsc_out_name="$2"
    _knit_rsc_out_id=""
    _knit_rsc_out_name=""

    # 1. Nearest participating in-process caller frame (below the current top).
    local i
    for (( i = ${#_KNIT_EXECUTING_COMMAND[@]} - 2; i >= 0; i-- )); do
        local pcmd="${_KNIT_EXECUTING_COMMAND[i]}"
        if _knit_provenance_enabled "${pcmd}"; then
            _knit_rsc_out_id="${_KNIT_EXECUTING_ROW_ID[i]}"
            _knit_rsc_out_name="$(_knit_command_demangle "${pcmd}")"
            return 0
        fi
    done

    # 2. Context exported across a process boundary.
    if [[ -n "${KNIT_SOURCE_ID:-}" || -n "${KNIT_SOURCE_COMMAND:-}" ]]; then
        _knit_rsc_out_id="${KNIT_SOURCE_ID:-}"
        _knit_rsc_out_name="${KNIT_SOURCE_COMMAND:-}"
        return 0
    fi

    # 3. Root invocation: source stays empty.
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_record_invocation()
#
# Record the just-completed invocation of a command: its data row (when the
# command declared a table with knit_with_table) and, when the command
# participates in the provenance graph (see _knit_provenance_enabled), a "call"
# edge from its source (the caller). Both are written only when the experiment is
# bootstrapped.
#
# The row id is the id resolved when this frame was pushed (see
# _knit_resolve_row_id) and read back from the top of _KNIT_EXECUTING_ROW_ID, so
# it matches the id a nested callee already saw as its source. Recording
# therefore runs while the frame is still on the stacks (before it is popped).
#
# The four cases:
#   - transparent (hidden) command with no table: nothing to record;
#   - transparent command with a table: the data row only (excluded from the
#     graph — provenance participation and data-row recording are orthogonal);
#   - participating command with a table: the data row and the "call" edge in one
#     transaction (_knit_db_record_invocation);
#   - participating command with no table: the "call" edge on its own
#     (_knit_prov_record_edge), whose target id joins to no data row (dangling).
#
# The edge's start_time was captured when the frame was pushed (top of
# _KNIT_EXECUTING_START_TIME); its end_time is captured here, after the body and
# after-callbacks.
#
# @param cmd Mangled command name.
# @param ... The expanded invocation arguments.
# ------------------------------------------------------------------------------
_knit_record_invocation() {
    # Global kill switch: KNIT_DISABLE_RECORDING=true disables all recording (data
    # rows and provenance edges), so a command or chain can be exercised without
    # leaving rows to clean up afterwards. Placed here so it also covers the eager
    # _knit_record_row_now path (knit submit's early recording).
    [[ "${KNIT_DISABLE_RECORDING:-}" == "true" ]] && return 0
    # Suppressed on non-root ranks of a run: record no row and no edge, so a run's
    # per-app row is written exactly once (by rank 0) even though every rank
    # re-enters the app.
    [[ -n "${_KNIT_RECORDING_SUPPRESSED}" ]] && return 0
    local cmd="$1"
    shift
    _knit_is_bootstrapped || return 0

    local table_var="_KNIT_CMD_${cmd}_table"
    local table="${!table_var:-}"

    # A hidden command is transparent to the provenance graph (no edge); it may
    # still record a data row if it declared a table (orthogonal). A hidden,
    # table-less command has nothing to record at all.
    local prov_enabled="false"
    _knit_provenance_enabled "${cmd}" && prov_enabled="true"
    if [[ -z "${table}" && "${prov_enabled}" != "true" ]]; then
        return 0
    fi

    # Record each invocation once. A command may record its row early via
    # _knit_record_row_now (knit submit records the submission before a blocking
    # --wait dispatch, so the job can transition the row's state as it runs); the
    # automatic post-invocation call then finds the flag set and does not insert
    # a duplicate.
    local recorded_var="_KNIT_CMD_${cmd}_recorded"
    [[ -n "${!recorded_var:-}" ]] && return 0

    # The id was resolved at push time and lives on the top of the row-id stack;
    # read it back so the recorded id matches the one a nested child already saw.
    local id
    if [[ ${#_KNIT_EXECUTING_ROW_ID[@]} -gt 0 ]]; then
        id="${_KNIT_EXECUTING_ROW_ID[-1]}"
    else
        # Defensive: recording outside the normal push/pop should not happen, but
        # never write a row without an id.
        id="$(_knit_uuidv7)"
    fi

    # Expose the resolved id so a dispatcher can read it after this body returns
    # (see _KNIT_LAST_ROW_ID; knit setup writes it to .setup.id).
    _KNIT_LAST_ROW_ID="${id}"

    printf -v "${recorded_var}" '%s' "1"

    # Transparent command: record only the data row (no edge), exactly as before
    # provenance existed.
    if [[ "${prov_enabled}" != "true" ]]; then
        _knit_db_record_invocation "${cmd}" "${table}" "${id}" "" "" "" "" "" "" "$@"
        return 0
    fi

    # Participating command: resolve the edge source (the caller), the call edge's
    # timestamps, and the call-site alias (from this frame's slot, set by knit_as),
    # then write the edge (with the data row, if any).
    _knit_prov_ensure_table
    local source_id source_name
    _knit_resolve_source_context source_id source_name
    local start_time=""
    if [[ ${#_KNIT_EXECUTING_START_TIME[@]} -gt 0 ]]; then
        start_time="${_KNIT_EXECUTING_START_TIME[-1]}"
    fi
    local end_time
    end_time="$(_knit_prov_now)"
    local alias=""
    if [[ ${#_KNIT_EXECUTING_ALIAS[@]} -gt 0 ]]; then
        alias="${_KNIT_EXECUTING_ALIAS[-1]}"
    fi

    if [[ -n "${table}" ]]; then
        _knit_db_record_invocation "${cmd}" "${table}" "${id}" \
            "${source_id}" "${source_name}" "call" "${start_time}" "${end_time}" \
            "${alias}" "$@"
    else
        # No data row: record the edge on its own; its target id joins to nothing.
        local target_name
        target_name="$(_knit_command_demangle "${cmd}")"
        _knit_prov_record_edge "${source_id}" "${source_name}" "${id}" \
            "${target_name}" "call" "${start_time}" "${end_time}" "${alias}"
    fi
}

# ------------------------------------------------------------------------------
# @fn knit_extra_index()
#
# Print the index at which extra arguments start (i.e. arguments passed after
# "--" in the list of arguments). This index will be the size of the list if no
# extra arguments are found. The way this function can be used is as follows.
#
# ```
# local args=("$@")
# local extra_index=$(knit_extra_index "${args[@]}")
# local extra=("${args[@]:extra_index}")
# ```
#
# @param ... List of arguments.
# ------------------------------------------------------------------------------
knit_extra_index() {
    local list=("$@")
    local index="${#list[@]}"
    local i
    for ((i=0; i<${#list[@]}; i++)) do
        if [[ "${list[i]}" == "--" ]]; then
            index=$((i+1))
            break
        fi
    done
    echo "${index}"
}

# ------------------------------------------------------------------------------
# @fn knit_check_arguments()
#
# Validate that a plain (non-registered) function received only expected
# arguments. This is the counterpart, for ordinary helper functions, of the
# validation that the command registration system performs automatically. It is
# intended for functions that parse their own "$@" with knit_get_parameter
# but don't go through knit_register.
#
# The expected parameters are described by two space-separated lists: options
# (which take a value, as "--name value" or "--name=value") and flags (which do
# not). Everything from a literal "--" onwards is treated as extra arguments and
# is not validated. Hyphens and underscores in names are interchangeable, as
# elsewhere in the framework.
#
# On the first unexpected argument the function logs an error attributed to the
# calling function and returns 1. It returns 0 if every argument is recognized.
#
# Example:
# ```
# _knit_submit_local() {
#     local -a args=("$@")
#     knit_check_arguments "stdout stderr stdin walltime" "" "${args[@]}" \
#         || return 1
#     ...
# }
# ```
#
# @param options Space-separated names of options that take a value.
# @param flags   Space-separated names of flags that take no value.
# @param ...     The arguments to validate (typically "$@").
# ------------------------------------------------------------------------------
knit_check_arguments() {
    local caller="${FUNCNAME[1]:-knit_check_arguments}"
    local options flags __opts __flags
    _knit_str_hyphens_to_underscores __opts "$1"
    _knit_str_hyphens_to_underscores __flags "$2"
    options=" ${__opts} "
    flags=" ${__flags} "
    shift 2
    local args=("$@")
    local i
    for ((i=0; i<${#args[@]}; i++)); do
        local arg="${args[i]}"
        # Anything from "--" onwards is extra and is not validated.
        if [[ "${arg}" == "--" ]]; then
            break
        fi
        if [[ "${arg}" != --* ]]; then
            knit_error "${caller}: unexpected argument \"${arg}\"."
            return 1
        fi
        local name
        name="$(_knit_arg_name "${arg}")"
        # An option in "--name value" form consumes the following token as its
        # value, so skip it without validating it (a value may legitimately
        # start with "--"). In "--name=value" form the value is inline.
        if [[ "${options}" == *" ${name} "* ]]; then
            [[ "${arg}" == --*=* ]] || i=$((i+1))
            continue
        fi
        if [[ "${flags}" == *" ${name} "* ]]; then
            continue
        fi
        knit_error "${caller}: unexpected argument \"${arg}\"."
        return 1
    done
    return 0
}

# ------------------------------------------------------------------------------
# @fn knit_set_program_description()
#
# Set the description of the program.
# ------------------------------------------------------------------------------
knit_set_program_description() {
    printf -v "_KNIT_CMD___main___description" '%s' "$1"
}
