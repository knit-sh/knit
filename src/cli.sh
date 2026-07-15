#!/bin/bash

## @file cli.sh

# ------------------------------------------------------------------------------
# List of registered commands.
# ------------------------------------------------------------------------------
declare -gA _KNIT_COMMANDS

# ------------------------------------------------------------------------------
# Set of defined parameter set names (normalized).
# ------------------------------------------------------------------------------
declare -gA _KNIT_PARAMETER_SETS

# ------------------------------------------------------------------------------
# Stack of currently-executing command names (mangled). Used by knit_output.
# ------------------------------------------------------------------------------
declare -ga _KNIT_EXECUTING_COMMAND=()

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
    _knit_str_hyphens_to_underscores "$1"
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
    _knit_str_hyphens_to_underscores "${name}"
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
# @fn _knit_param_description_var()
#
# This function prints the name of the variable that contains the description of
# a parameter for a given command.
#
# @param cmd Command to which the parameter belongs (must be mangled).
# @param param Name of the parameter (must be normalized).
# ------------------------------------------------------------------------------
_knit_param_description_var() {
    local cmd="$1"
    local param="$2"
    printf "_KNIT_CMD_%s_2_%s_description" "${cmd}" "${param}"
}

# ------------------------------------------------------------------------------
# @fn _knit_param_description()
#
# This function prints the description of a parameter for a given command.
#
# @param cmd Command to which the parameter belongs (must be mangled).
# @param param Name of the parameter (must be normalized).
# ------------------------------------------------------------------------------
_knit_param_description() {
    local description_var
    description_var=$(_knit_param_description_var "$@")
    printf "%s" "${!description_var}"
}

# ------------------------------------------------------------------------------
# @fn _knit_param_default_var()
#
# This function prints the name of the variable that contains the default value
# of a parameter for a given command.
#
# @param cmd Command to which the parameter belongs (must be mangled).
# @param param Name of the parameter (must be normalized).
# ------------------------------------------------------------------------------
_knit_param_default_var() {
    local cmd="$1"
    local param="$2"
    printf "_KNIT_CMD_%s_2_%s_default" "${cmd}" "${param}"
}

# ------------------------------------------------------------------------------
# @fn _knit_param_type_var()
#
# This function prints the name of the variable that contains the type of a
# parameter for a given command.
#
# @param cmd Command to which the parameter belongs (must be mangled).
# @param param Name of the parameter (must be normalized).
# ------------------------------------------------------------------------------
_knit_param_type_var() {
    local cmd="$1"
    local param="$2"
    printf "_KNIT_CMD_%s_2_%s_type" "${cmd}" "${param}"
}

# ------------------------------------------------------------------------------
# @fn _knit_param_default()
#
# This function prints the default value of a parameter for a given command.
#
# @param cmd Command to which the parameter belongs (must be mangled).
# @param param Name of the parameter (must be normalized).
# ------------------------------------------------------------------------------
_knit_param_default() {
    local default_var
    default_var=$(_knit_param_default_var "$@")
    printf "%s" "${!default_var}"
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
# This function prints the type of a parameter for a given command.
#
# @param cmd Command to which the parameter belongs (must be mangled).
# @param param Name of the parameter (must be normalized).
# ------------------------------------------------------------------------------
_knit_param_type() {
    local type_var
    type_var=$(_knit_param_type_var "$@")
    printf "%s" "${!type_var}"
}

# ------------------------------------------------------------------------------
# @fn _knit_output_description_var()
#
# This function prints the name of the variable that contains the description
# of an output for a given command.
#
# @param cmd Command to which the output belongs (must be mangled).
# @param output Name of the output (must be normalized).
# ------------------------------------------------------------------------------
_knit_output_description_var() {
    local cmd="$1"
    local output="$2"
    printf "_KNIT_CMD_%s_3_%s_description" "${cmd}" "${output}"
}

# ------------------------------------------------------------------------------
# @fn _knit_output_description()
#
# This function prints the description of an output for a given command.
#
# @param cmd Command to which the output belongs (must be mangled).
# @param output Name of the output (must be normalized).
# ------------------------------------------------------------------------------
_knit_output_description() {
    local description_var
    description_var=$(_knit_output_description_var "$@")
    printf "%s" "${!description_var}"
}

# ------------------------------------------------------------------------------
# @fn _knit_output_default_var()
#
# This function prints the name of the variable that contains the default value
# of an output for a given command.
#
# @param cmd Command to which the output belongs (must be mangled).
# @param output Name of the output (must be normalized).
# ------------------------------------------------------------------------------
_knit_output_default_var() {
    local cmd="$1"
    local output="$2"
    printf "_KNIT_CMD_%s_3_%s_default" "${cmd}" "${output}"
}

# ------------------------------------------------------------------------------
# @fn _knit_output_default()
#
# This function prints the default value of an output for a given command.
#
# @param cmd Command to which the output belongs (must be mangled).
# @param output Name of the output (must be normalized).
# ------------------------------------------------------------------------------
_knit_output_default() {
    local default_var
    default_var=$(_knit_output_default_var "$@")
    printf "%s" "${!default_var}"
}

# ------------------------------------------------------------------------------
# @fn _knit_output_type_var()
#
# This function prints the name of the variable that contains the type of an
# output for a given command.
#
# @param cmd Command to which the output belongs (must be mangled).
# @param output Name of the output (must be normalized).
# ------------------------------------------------------------------------------
_knit_output_type_var() {
    local cmd="$1"
    local output="$2"
    printf "_KNIT_CMD_%s_3_%s_type" "${cmd}" "${output}"
}

# ------------------------------------------------------------------------------
# @fn _knit_output_type()
#
# This function prints the type of an output for a given command.
#
# @param cmd Command to which the output belongs (must be mangled).
# @param output Name of the output (must be normalized).
# ------------------------------------------------------------------------------
_knit_output_type() {
    local type_var
    type_var=$(_knit_output_type_var "$@")
    printf "%s" "${!type_var}"
}

# ------------------------------------------------------------------------------
# @fn _knit_command_get_parents()
#
# Takes a command in the form "aaa:bbb:ccc" or "aaa bbb ccc" or
# "aaa__1__bbb__1__cccc" and return the parent commands (e.g. "aaa:bbb" or
# "aaa bbb" or "aaa__1__bbb".
# ------------------------------------------------------------------------------
_knit_command_get_parents() {
    local cmd="$*"
    if [[ "$cmd" =~ ^(.*)([[:space:]]|:|__1__)[^[:space:]:__1__]*$ ]]; then
        printf "%s" "${BASH_REMATCH[1]}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_command_get_last()
#
# Takes a command in the form "aaa:bbb:ccc" or "aaa bbb ccc" or
# "aaa__1__bbb__1__cccc" and return the last command (e.g. "ccc" in all the
# cases above).
# ------------------------------------------------------------------------------
_knit_command_get_last() {
    local cmd="$*"
    if [[ "$cmd" =~ (.*)([[:space:]]|:|__1__)([^[:space:]:__1__]+)$ ]]; then
        printf "%s" "${BASH_REMATCH[3]}"
    else
        printf "%s" "${cmd}"
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
    parent_cmd=$(_knit_command_get_parents "$cmd")
    if [ -n "${parent_cmd}" ]  &&  ! _knit_set_find _KNIT_COMMANDS "${parent_cmd}"; then
        knit_fatal "Cannot register command \"${demangled_cmd}\" because its parent has not been registered."
    fi
    if _knit_set_find _KNIT_COMMANDS "${cmd}"; then
        knit_fatal "Command \"${demangled_cmd}\" is already registered."
    fi
    _knit_set_add _KNIT_COMMANDS "${cmd}"
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
    declare -ga "_KNIT_CMD_${cmd}_before_cb"
    declare -ga "_KNIT_CMD_${cmd}_after_cb"
    declare -ga "_KNIT_CMD_${cmd}_notes"
    printf -v "_KNIT_CMD_${cmd}_sucommand_title" '%s' 'Subcommands'
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
# Mark a command as hidden, i.e. it will not appear in usage help messages.
# ------------------------------------------------------------------------------
knit_hidden() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_hidden should be used after a call to \"knit_register\"."
    fi
    knit_trace "Marking command ${_KNIT_CURRENT_COMMAND_DEMANGLED} as hidden."
    local cmd="${_KNIT_CURRENT_COMMAND}"
    local cmd_hidden_name="_KNIT_CMD_${cmd}_is_hidden"
    printf -v "${cmd_hidden_name}" '%s' 'true'
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
    printf -v "_KNIT_CMD_${cmd}_sucommand_title" '%s' "$1"
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
    local description_var
    description_var=$(_knit_output_description_var "${cmd}" "${output}")
    local default_var
    default_var=$(_knit_output_default_var "${cmd}" "${output}")
    local type_var
    type_var=$(_knit_output_type_var "${cmd}" "${output}")
    knit_trace "Adding output \"${param_name}\" (type: ${param_type}) to command \"${demangled_cmd}\"."
    printf -v "${description_var}" '%s' "$3"
    printf -v "${default_var}"     '%s' "$2"
    printf -v "${type_var}"        '%s' "${param_type}"
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
    param_type=$(_knit_param_type "${cmd}" "${name}")
    if [[ -z "${param_type}" ]] || knit_type_check "${param_type}" "${value}"; then
        return 0
    fi
    local alt_format
    alt_format=$(_knit_str_underscores_to_hyphens "${name}")
    local resolved
    resolved=$(_knit_type_resolve_alias "${param_type}") || resolved=""
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
        alt_format=$(_knit_str_underscores_to_hyphens "${option}")
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
        default_value=$(_knit_param_default "${cmd}" "${option}")
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

    if [[ "${with_help}" == "true" ]]; then
        printf "  %-${max_opt_length}s  %s\n" "--help" "Print this help message and exit."
    fi
    while read -r opt; do
        description=$(_knit_param_description "${cmd}" "${opt}")
        opt2="--$(_knit_str_underscores_to_hyphens "${opt}")"
        local when_raw_var="_KNIT_CMD_${cmd}_2_${opt}_when_raw"
        local annotation="required"
        if [[ -v "${when_raw_var}" ]]; then
            annotation="required, when: ${!when_raw_var}"
        fi
        printf "  %-${max_opt_length}s  [%s] %s\n" "${opt2} <value>" "${annotation}" "${description}"
    done < <(_knit_set_iter "${required_args_varname}")
    while read -r opt; do
        description=$(_knit_param_description "${cmd}" "${opt}")
        default=$(_knit_param_default "${cmd}" "${opt}")
        opt2="--$(_knit_str_underscores_to_hyphens "${opt}")"
        local when_raw_var="_KNIT_CMD_${cmd}_2_${opt}_when_raw"
        local annotation="default: '${default}'"
        if [[ -v "${when_raw_var}" ]]; then
            annotation="default: '${default}', when: ${!when_raw_var}"
        fi
        printf "  %-${max_opt_length}s  [%s] %s\n" "${opt2} <value>" "${annotation}" "${description}"
    done < <(_knit_set_iter "${optional_args_varname}")
    max_opt_length=$((max_opt_length - 8))
    while read -r opt; do
        description=$(_knit_param_description "${cmd}" "${opt}")
        opt2="--$(_knit_str_underscores_to_hyphens "${opt}")"
        local when_raw_var="_KNIT_CMD_${cmd}_2_${opt}_when_raw"
        local annotation="flag"
        if [[ -v "${when_raw_var}" ]]; then
            annotation="flag, when: ${!when_raw_var}"
        fi
        printf "  %-${max_opt_length}s  %s\n" "${opt2}" "        [${annotation}] ${description}"
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
    parent=$(_knit_command_get_parents "${cmd}")
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
        leaf=$(_knit_command_get_last "${cmd}")
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
    local max_subcommand_len=0
    local c
    if [[ "${cmd}" != "__main__" ]]; then # non-root command
        while read -r c; do
            local hidden_var_name="_KNIT_CMD_${c}_is_hidden"
            if [[ "${!hidden_var_name}" == "true" ]]; then
                continue
            fi
            if [[ "${c}" == "${cmd}" ]]; then
                continue
            fi
            if [[ "${c:0:${#cmd}}" != "$cmd" ]]; then
                continue
            fi
            local name="${c:$((${#cmd}+5))}"
            if [[ "${name}" =~ "__1__" ]]; then
                continue
            fi
            subcommands+=("${name}")
            subcommands_full+=("${c}")
            if ((max_subcommand_len < ${#name})); then
                max_subcommand_len=${#name}
            fi
        done < <(_knit_set_iter _KNIT_COMMANDS)
    else # root command
        while read -r c; do
            local hidden_var_name="_KNIT_CMD_${c}_is_hidden"
            if [[ "${!hidden_var_name}" == "true" ]]; then
                continue
            fi
            if [[ "${c}" =~ "__1__" ]]; then
                continue
            fi
            subcommands+=("${c}")
            subcommands_full+=("${c}")
            if ((max_subcommand_len < ${#c})); then
                max_subcommand_len=${#c}
            fi
        done < <(_knit_set_iter _KNIT_COMMANDS)
    fi
    if [ "${#subcommands[@]}" -gt "0" ]; then
        local sub_name="_KNIT_CMD_${cmd}_sucommand_title"
        sub_name=${!sub_name}
        local hrule
        printf -v hrule "%*s" "${#sub_name}" ""
        hrule="${hrule// /-}"
        printf "\n%s\n%s\n" "${sub_name}" "${hrule}"
        local i
        for ((i=0; i<${#subcommands[@]}; i++)); do
            local description_var="_KNIT_CMD_${subcommands_full[i]}_description"
            local description="${!description_var}"
            printf "  %$((max_subcommand_len))s   %s\n" "${subcommands[i]}" "${description}"
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
                    alt_format=$(_knit_str_underscores_to_hyphens "${param}")
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
        $func "$@"
        local wrapper_status=$?
        # Keep the command on the stack through the after-callbacks (see the
        # non-wrapper path below) so they too may call knit_output.
        _knit_execute_after_commands "${_knit_wrapper_cmd}" "$@"
        unset '_KNIT_EXECUTING_COMMAND[-1]'
        _knit_record_invocation "${_knit_wrapper_cmd}" "$@"
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
    $func "${args[@]}"
    local func_status=$?
    # call the "after" callbacks. The command stays on _KNIT_EXECUTING_COMMAND
    # for their duration (popped only afterwards) so an after-callback may call
    # knit_output, just like the command body can. The output map has already
    # been reset (before the body), so after-callback outputs are recorded.
    _knit_execute_after_commands "${cmd}" "${args[@]}"
    unset '_KNIT_EXECUTING_COMMAND[-1]'
    # Record this invocation as a database row if the command declared a table.
    _knit_record_invocation "${cmd}" "${args[@]}"
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
    param=$(_knit_str_hyphens_to_underscores "$1")
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
    local type_var
    type_var=$(_knit_output_type_var "${cmd}" "${normalized}")
    local type="${!type_var}"
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
# @fn _knit_record_invocation()
#
# Record the just-completed invocation of a command as one row in its table,
# when the command declared one with knit_with_table and the experiment is
# bootstrapped. The row id is, in order of precedence: an explicit id set via
# _knit_set_row_id; the run UUID from KNIT_RUN_ID (rank 0's per-app row of a
# `knit run`, so it shares the runs-table row's id); the job UUID from
# KNIT_JOB_PREFIX (the execution side of a job); otherwise a fresh uuid.
#
# @param cmd Mangled command name.
# @param ... The expanded invocation arguments.
# ------------------------------------------------------------------------------
_knit_record_invocation() {
    # Suppressed on non-root ranks of a run: record no row, so a run's per-app row
    # is written exactly once (by rank 0) even though every rank re-enters the app.
    [[ -n "${_KNIT_RECORDING_SUPPRESSED}" ]] && return 0
    local cmd="$1"
    shift
    local table_var="_KNIT_CMD_${cmd}_table"
    local table="${!table_var:-}"
    [[ -z "${table}" ]] && return 0
    _knit_is_bootstrapped || return 0

    # Record each invocation once. A command may record its row early via
    # _knit_record_row_now (knit submit records the submission before a blocking
    # --wait dispatch, so the job can transition the row's state as it runs); the
    # automatic post-invocation call then finds the flag set and does not insert
    # a duplicate.
    local recorded_var="_KNIT_CMD_${cmd}_recorded"
    [[ -n "${!recorded_var:-}" ]] && return 0

    local id
    local rowid_var="_KNIT_CMD_${cmd}_row_id"
    if [[ -n "${!rowid_var:-}" ]]; then
        id="${!rowid_var}"
    elif [[ -n "${KNIT_RUN_ID:-}" ]]; then
        # Rank 0 of a `knit run`: the launcher forwarded the run UUID the
        # dispatcher exported, so the per-app row shares the runs-table row's id.
        id="${KNIT_RUN_ID}"
    elif [[ -n "${KNIT_JOB_PREFIX:-}" ]]; then
        id="$(basename "${KNIT_JOB_PREFIX}")"
    else
        id="$(_knit_uuidv7)"
    fi

    printf -v "${recorded_var}" '%s' "1"
    # Provenance edge context (parent id/name, edge type, timestamps) is not yet
    # threaded through here — that lands in a later milestone. Pass an empty edge
    # type so only the data row is recorded, exactly as before provenance existed.
    _knit_db_record_invocation "${cmd}" "${table}" "${id}" "" "" "" "" "" "$@"
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
    local options flags
    options=" $(_knit_str_hyphens_to_underscores "$1") "
    flags=" $(_knit_str_hyphens_to_underscores "$2") "
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
