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
# @fn knit_empty()
#
# Empty function to register commands with no behaviors.
# ------------------------------------------------------------------------------
knit_empty() {
    :
}

# ------------------------------------------------------------------------------
# @fn __knit_command_mangle()
#
# Mangles a command, i.e. converts "command:subcommand:subcommand" into
# "command__1__subcommand__1__subcommand" so the name can be used in variable
# names. Also converts spaces into __1__.
#
# @param cmd Command to mangle.
# ------------------------------------------------------------------------------
__knit_command_mangle() {
    local cmd="$*"
    local mangled
    mangled=$(echo "$cmd" | sed -E 's/[: ]+/__1__/g')
    printf "%s" "${mangled}"
}

# ------------------------------------------------------------------------------
# @fn __knit_command_demangle()
#
# Demangles a command, i.e. converts "command__1__subcommand__1__subcommand"
# back into "command:subcommand:subcommand".
#
# @param cmd Command to demangle.
# ------------------------------------------------------------------------------
__knit_command_demangle() {
    local cmd="$1"
    local demangled="${cmd//__1__/:}"
    printf "%s" "${demangled}"
}

# ------------------------------------------------------------------------------
# @fn __knit_command_with_space()
#
# Prints a mangled command (or a command with ":" in it) with spaces between
# subcommands.
#
# @param cmd Command to print with spaces.
# ------------------------------------------------------------------------------
__knit_command_with_space() {
    local cmd="$1"
    echo "$cmd" | sed -E 's/__1__|:/ /g'
}

# ------------------------------------------------------------------------------
# @fn __knit_name_normalize()
#
# Normalizes a parameter or command name, i.e. converts its hyphens into
# underscores.
#
# @param name Name to normalize.
# ------------------------------------------------------------------------------
__knit_name_normalize() {
    _knit_str_hyphens_to_underscores "$1"
}

# ------------------------------------------------------------------------------
# @fn __knit_arg_name()
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
__knit_arg_name() {
    local name="${1#--}"
    name="${name%%=*}"
    _knit_str_hyphens_to_underscores "${name}"
}

# ------------------------------------------------------------------------------
# @fn __knit_name_is_valid()
#
# Checks that a parameter or command name is valid, i.e. it has to start with a
# letter, followed by any number of alphanumerical characters and hyphens and
# underscores. The names "true", "false", "null", "and", "or", and "not" are
# reserved for use in --when constraint expressions and are not allowed.
#
# @param param Parameter name to normalize.
# ------------------------------------------------------------------------------
__knit_name_is_valid() {
    if [[ ! "$1" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_-]*$ ]]; then
        return 1
    fi
    case "$1" in
        true|false|null|and|or|not) return 1 ;;
    esac
    return 0
}

# ------------------------------------------------------------------------------
# @fn __knit_preprocess_constraint()
#
# Preprocess a user-written constraint expression for use with jq. Bare
# identifiers (parameter names) are prefixed with "." so they refer to jq
# object fields. jq keywords and identifiers inside string literals are left
# unchanged. Requires Perl.
#
# Example:
# ```
# __knit_preprocess_constraint "x > 42 and z == \"foo\""
# # prints: .x > 42 and .z == "foo"
# ```
#
# @param expr Constraint expression to preprocess.
# ------------------------------------------------------------------------------
__knit_preprocess_constraint() {
    local expr="$1"
    printf '%s' "${expr}" | perl -pe '
        my %kw = map { $_ => 1 } qw(true false null and or not);
        s/"[^"\\]*(?:\\.[^"\\]*)*"(*SKIP)(*FAIL)|(?<![.\w])([a-zA-Z_][a-zA-Z0-9_]*)/$kw{$1} ? $1 : ".$1"/ge
    '
}

# ------------------------------------------------------------------------------
# @fn __knit_param_check_declaration()
#
# This function carries out all the checks for a parameter to be declared by
# knit_with_required/optional/flag. The parameter name must include a type
# annotation in the form "name:type" (e.g. "width:integer").
#
# @param suffix Suffix ("required", "optional", or "flag") to use for variables.
# @param param Parameter name followed by ":type".
# @param description Description of the parameter.
# ------------------------------------------------------------------------------
__knit_param_check_declaration() {
    local suffix="$1"
    local param="$2"
    local description="$3"

    if [[ ! -v _KNIT_CURRENT_COMMAND ]] && [[ ! -v _KNIT_CURRENT_PARAMETER_SET ]]; then
        knit_fatal "knit_with_${suffix} should be used after a call to \"knit_register\" or \"knit_define_parameter_set\"."
    fi

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

    if ! __knit_name_is_valid "${param_name}"; then
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
        context_name=$(__knit_command_demangle "${_KNIT_CURRENT_COMMAND}")
        ns="_KNIT_CMD_${_KNIT_CURRENT_COMMAND}"
    fi
    local normalized
    normalized=$(__knit_name_normalize "${param_name}")

    if _knit_set_find "${ns}_required" "${normalized}" \
    || _knit_set_find "${ns}_optional" "${normalized}" \
    || _knit_set_find "${ns}_flags"    "${normalized}"; then
        knit_fatal "Parameter \"${param_name}\" already declared for \"${context_name}\"."
    fi
}

# ------------------------------------------------------------------------------
# @fn __knit_param_description_var()
#
# This function prints the name of the variable that contains the description of
# a parameter for a given command.
#
# @param cmd Command to which the parameter belongs (must be mangled).
# @param param Name of the parameter (must be normalized).
# ------------------------------------------------------------------------------
__knit_param_description_var() {
    local cmd="$1"
    local param="$2"
    printf "_KNIT_CMD_%s_2_%s_description" "${cmd}" "${param}"
}

# ------------------------------------------------------------------------------
# @fn __knit_param_description()
#
# This function prints the description of a parameter for a given command.
#
# @param cmd Command to which the parameter belongs (must be mangled).
# @param param Name of the parameter (must be normalized).
# ------------------------------------------------------------------------------
__knit_param_description() {
    local description_var
    description_var=$(__knit_param_description_var "$@")
    printf "%s" "${!description_var}"
}

# ------------------------------------------------------------------------------
# @fn __knit_param_default_var()
#
# This function prints the name of the variable that contains the default value
# of a parameter for a given command.
#
# @param cmd Command to which the parameter belongs (must be mangled).
# @param param Name of the parameter (must be normalized).
# ------------------------------------------------------------------------------
__knit_param_default_var() {
    local cmd="$1"
    local param="$2"
    printf "_KNIT_CMD_%s_2_%s_default" "${cmd}" "${param}"
}

# ------------------------------------------------------------------------------
# @fn __knit_param_type_var()
#
# This function prints the name of the variable that contains the type of a
# parameter for a given command.
#
# @param cmd Command to which the parameter belongs (must be mangled).
# @param param Name of the parameter (must be normalized).
# ------------------------------------------------------------------------------
__knit_param_type_var() {
    local cmd="$1"
    local param="$2"
    printf "_KNIT_CMD_%s_2_%s_type" "${cmd}" "${param}"
}

# ------------------------------------------------------------------------------
# @fn __knit_param_default()
#
# This function prints the default value of a parameter for a given command.
#
# @param cmd Command to which the parameter belongs (must be mangled).
# @param param Name of the parameter (must be normalized).
# ------------------------------------------------------------------------------
__knit_param_default() {
    local default_var
    default_var=$(__knit_param_default_var "$@")
    printf "%s" "${!default_var}"
}

# ------------------------------------------------------------------------------
# @fn __knit_param_type()
#
# This function prints the type of a parameter for a given command.
#
# @param cmd Command to which the parameter belongs (must be mangled).
# @param param Name of the parameter (must be normalized).
# ------------------------------------------------------------------------------
__knit_param_type() {
    local type_var
    type_var=$(__knit_param_type_var "$@")
    printf "%s" "${!type_var}"
}

# ------------------------------------------------------------------------------
# @fn __knit_output_description_var()
#
# This function prints the name of the variable that contains the description
# of an output for a given command.
#
# @param cmd Command to which the output belongs (must be mangled).
# @param output Name of the output (must be normalized).
# ------------------------------------------------------------------------------
__knit_output_description_var() {
    local cmd="$1"
    local output="$2"
    printf "_KNIT_CMD_%s_3_%s_description" "${cmd}" "${output}"
}

# ------------------------------------------------------------------------------
# @fn __knit_output_description()
#
# This function prints the description of an output for a given command.
#
# @param cmd Command to which the output belongs (must be mangled).
# @param output Name of the output (must be normalized).
# ------------------------------------------------------------------------------
__knit_output_description() {
    local description_var
    description_var=$(__knit_output_description_var "$@")
    printf "%s" "${!description_var}"
}

# ------------------------------------------------------------------------------
# @fn __knit_output_default_var()
#
# This function prints the name of the variable that contains the default value
# of an output for a given command.
#
# @param cmd Command to which the output belongs (must be mangled).
# @param output Name of the output (must be normalized).
# ------------------------------------------------------------------------------
__knit_output_default_var() {
    local cmd="$1"
    local output="$2"
    printf "_KNIT_CMD_%s_3_%s_default" "${cmd}" "${output}"
}

# ------------------------------------------------------------------------------
# @fn __knit_output_default()
#
# This function prints the default value of an output for a given command.
#
# @param cmd Command to which the output belongs (must be mangled).
# @param output Name of the output (must be normalized).
# ------------------------------------------------------------------------------
__knit_output_default() {
    local default_var
    default_var=$(__knit_output_default_var "$@")
    printf "%s" "${!default_var}"
}

# ------------------------------------------------------------------------------
# @fn __knit_output_type_var()
#
# This function prints the name of the variable that contains the type of an
# output for a given command.
#
# @param cmd Command to which the output belongs (must be mangled).
# @param output Name of the output (must be normalized).
# ------------------------------------------------------------------------------
__knit_output_type_var() {
    local cmd="$1"
    local output="$2"
    printf "_KNIT_CMD_%s_3_%s_type" "${cmd}" "${output}"
}

# ------------------------------------------------------------------------------
# @fn __knit_output_type()
#
# This function prints the type of an output for a given command.
#
# @param cmd Command to which the output belongs (must be mangled).
# @param output Name of the output (must be normalized).
# ------------------------------------------------------------------------------
__knit_output_type() {
    local type_var
    type_var=$(__knit_output_type_var "$@")
    printf "%s" "${!type_var}"
}

# ------------------------------------------------------------------------------
# @fn __knit_command_get_parents()
#
# Takes a command in the form "aaa:bbb:ccc" or "aaa bbb ccc" or
# "aaa__1__bbb__1__cccc" and return the parent commands (e.g. "aaa:bbb" or
# "aaa bbb" or "aaa__1__bbb".
# ------------------------------------------------------------------------------
__knit_command_get_parents() {
    local cmd="$*"
    if [[ "$cmd" =~ ^(.*)([[:space:]]|:|__1__)[^[:space:]:__1__]*$ ]]; then
        printf "%s" "${BASH_REMATCH[1]}"
    fi
}

# ------------------------------------------------------------------------------
# @fn __knit_command_get_last()
#
# Takes a command in the form "aaa:bbb:ccc" or "aaa bbb ccc" or
# "aaa__1__bbb__1__cccc" and return the last command (e.g. "ccc" in all the
# cases above).
# ------------------------------------------------------------------------------
__knit_command_get_last() {
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
    cmd=$(__knit_command_mangle "${demangled_cmd}")
    local parent_cmd
    parent_cmd=$(__knit_command_get_parents "$cmd")
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
    printf -v "_KNIT_CMD_${cmd}_is_hidden"       '%s' 'false'
    declare -ga "_KNIT_CMD_${cmd}_before_cb"
    declare -ga "_KNIT_CMD_${cmd}_after_cb"
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
        # shellcheck disable=SC2209 # callback string pre-escaped with printf %q by __knit_push_done_cb
        eval "${_KNIT_DONE_CBS[$i]}"
    done
    unset _KNIT_DONE_CBS
    unset _KNIT_CURRENT_FUNCTION
    unset _KNIT_CURRENT_COMMAND
    unset _KNIT_CURRENT_COMMAND_DEMANGLED
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
    if ! __knit_name_is_valid "${set_name}"; then
        knit_fatal "Parameter set name \"${set_name}\" is not valid."
    fi
    local normalized
    normalized=$(__knit_name_normalize "${set_name}")
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
    __knit_param_check_declaration "required" "$1" "$2"
    knit_check_arguments "when" "" "${@:3}" \
        || knit_fatal "knit_with_required takes a parameter, a description, and an optional --when."
    local param_spec="$1"
    local param_name="${param_spec%%:*}"
    local param_type="${param_spec#*:}"
    local param
    param=$(__knit_name_normalize "${param_name}")
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
        local preprocessed
        preprocessed=$(__knit_preprocess_constraint "${when_expr}")
        printf -v "${ns}_2_${param}_when"     '%s' "${preprocessed}"
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
# @param param Parameter name followed by ":type".
# @param default Default value.
# @param description Description of the parameter.
# @param --when Optional boolean constraint expression (jq syntax referring to
#        the command's other parameters); the parameter only applies when the
#        expression evaluates to true.
# ------------------------------------------------------------------------------
knit_with_optional() {
    __knit_param_check_declaration "optional" "$1" "$3"
    knit_check_arguments "when" "" "${@:4}" \
        || knit_fatal "knit_with_optional takes a parameter, a default, a description, and an optional --when."
    local param_spec="$1"
    local param_name="${param_spec%%:*}"
    local param_type="${param_spec#*:}"
    local param
    param=$(__knit_name_normalize "${param_name}")
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
        local preprocessed
        preprocessed=$(__knit_preprocess_constraint "${when_expr}")
        printf -v "${ns}_2_${param}_when"     '%s' "${preprocessed}"
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
    __knit_param_check_declaration "flag" "$1" "$2"
    knit_check_arguments "when" "" "${@:3}" \
        || knit_fatal "knit_with_flag takes a flag name, a description, and an optional --when."
    local param
    param=$(__knit_name_normalize "$1")
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
        local preprocessed
        preprocessed=$(__knit_preprocess_constraint "${when_expr}")
        printf -v "${ns}_2_${param}_when"     '%s' "${preprocessed}"
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
    local set_name="$1"
    local normalized
    normalized=$(__knit_name_normalize "${set_name}")
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
    local param_spec="$1"
    if [[ "${param_spec}" != *:* ]]; then
        knit_fatal "Output \"${param_spec}\" is missing a type annotation (expected \"name:type\")."
    fi
    local param_name="${param_spec%%:*}"
    local param_type="${param_spec#*:}"
    if ! __knit_name_is_valid "${param_name}"; then
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
    output=$(__knit_name_normalize "${param_name}")
    if _knit_set_find "_KNIT_CMD_${cmd}_outputs" "${output}"; then
        knit_fatal "Output \"${param_name}\" already declared for \"${demangled_cmd}\"."
    fi
    local description_var
    description_var=$(__knit_output_description_var "${cmd}" "${output}")
    local default_var
    default_var=$(__knit_output_default_var "${cmd}" "${output}")
    local type_var
    type_var=$(__knit_output_type_var "${cmd}" "${output}")
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

    __knit_push_done_cb _knit_db_setup_table "${cmd}" "${table_name}"
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
    cb=$(printf "%q " "$@")
    cb_list_ref+=("${cb}")
}

# ------------------------------------------------------------------------------
# @fn __knit_execute_before_commands()
#
# Evaluate the callbacks installed before a command. The callbacks are called
# with the calling command name (demangled) as context, as well as the list of
# parameters passed to the command.
#
# @param cmd Command (mangled name) for which to execute the before callbacks.
# @param ... Arguments of the command.
# ------------------------------------------------------------------------------
__knit_execute_before_commands() {
    local cmd="$1"
    shift
    local demangled_cmd
    demangled_cmd=$(__knit_command_demangle "${cmd}")
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
    cb=$(printf "%q " "$@")
    cb_list_ref+=("${cb}")
}

# ------------------------------------------------------------------------------
# @fn __knit_execute_after_commands()
#
# Evaluate the callbacks installed after a command. The callbacks are called
# with the calling command name (demangled) as context, as well as the list of
# parameters passed to the command.
#
# @param cmd Command (mangled name) for which to execute the after callbacks.
# @param ... Arguments of the command.
# ------------------------------------------------------------------------------
__knit_execute_after_commands() {
    local cmd="$1"
    shift
    local demangled_cmd
    demangled_cmd=$(__knit_command_demangle "${cmd}")
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
# @fn __knit_push_done_cb()
#
# In the context of a knit_register, push a callback to be called at the next
# call to knit_done. Multiple callbacks may be pushed; they are all called in
# reverse order of installation. The callback list is cleared after knit_done.
#
# @param ... Callback function and its arguments.
# ------------------------------------------------------------------------------
__knit_push_done_cb() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "__knit_push_done_cb should be used after a call to \"knit_register\"."
    fi
    knit_trace "Pushing done callback in ${_KNIT_CURRENT_COMMAND_DEMANGLED}."
    local cb
    cb=$(printf "%q " "$@")
    _KNIT_DONE_CBS+=("${cb}")
}

# ------------------------------------------------------------------------------
# @fn _knit_check_command_arguments()
#
# Check that the arguments expected by the command are provided. This function
# will fail with a fatal error (i.e. the script will stop) if a required
# argument is not provided, or if an argument provided does not match any
# any expected.
#
# @param cmd Name of the command (mangled).
# @param ... Arguments to pass to the command.
# ------------------------------------------------------------------------------
_knit_check_command_arguments() {
    local cmd="$1"
    local demangled_cmd
    demangled_cmd=$(__knit_command_demangle "${cmd}")
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
        name="$(__knit_arg_name "${arg}")"
        # Required/optional parameters consume the following token as their
        # value, unless the value was supplied inline as "--name=value". Flags
        # never consume a token.
        if _knit_set_find "${required_args_varname}" "${name}"; then
            [[ "${arg}" == --*=* ]] || i=$((i+1))
            continue
        fi
        if _knit_set_find "${optional_args_varname}" "${name}"; then
            [[ "${arg}" == --*=* ]] || i=$((i+1))
            continue
        fi
        if _knit_set_find "${flags_args_varname}" "${name}"; then
            continue
        fi
        knit_fatal "Unexpected argument \"${arg}\" passed to \"${demangled_cmd}\" command."
    done
}

# ------------------------------------------------------------------------------
# @fn __knit_find_flag()
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
__knit_find_flag() {
    local flag
    flag=$(__knit_arg_name "$1")
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
        if [[ "$(__knit_arg_name "${item}")" == "${flag}" ]]; then
            return 0
        fi
    done

    return 1
}

# ------------------------------------------------------------------------------
# @fn __knit_expand_command_arguments()
#
# Adds optional arguments that are not provided in the arguments, and converts
# flags into --flag true or --flag false.
#
# @param name Name of the command.
# @param ... Arguments to pass to the command.
# ------------------------------------------------------------------------------
__knit_expand_command_arguments() {
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
        default_value=$(__knit_param_default "${cmd}" "${option}")
        args+=("--${option}" "${default_value}")
    done < <(_knit_set_iter "${optional_args_varname}")
    # Handle flags (add them as option with value "true" or "false")
    local flags_args_varname="_KNIT_CMD_${cmd}_flags"
    local flag
    while read -r flag; do
        if __knit_find_flag "--${flag}" "${args[@]}"; then
            local i
            for i in "${!args[@]}"; do
                if [[ "${args[$i]}" == "--${flag}" ]]; then
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
# @fn __knit_print_command_usage()
#
# Print the help message for a command/subcommand.
#
# @param ...cmds Command and subcommand names
# ------------------------------------------------------------------------------
__knit_print_command_usage() {
    local demanled_cmd="$*"
    local cmd
    cmd=$(__knit_command_mangle "${demangled_cmd}")
    local extra_var="_KNIT_CMD_${cmd}_extra"
    if [[ "${demanled_cmd}" == "__main__" ]]; then
        printf "Usage: %s [OPTIONS]\n\n" "$0"
    elif [ -z "${!extra_var}" ]; then
        printf "Usage: %s %s [OPTIONS]\n\n" "$0" "${demangled_cmd}"
    else
        printf "Usage: %s %s [OPTIONS] -- [EXTRA]\n\n" "$0" "${demangled_cmd}"
    fi

    local description_var="_KNIT_CMD_${cmd}_description"
    printf "  %s\n\n" "${!description_var}"

    printf "Options\n-------\n"
    local required_args_varname="_KNIT_CMD_${cmd}_required"
    local optional_args_varname="_KNIT_CMD_${cmd}_optional"
    local flags_args_varname="_KNIT_CMD_${cmd}_flags"
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

    printf "  %-${max_opt_length}s  %s\n" "--help" "Print this help message and exit."
    while read -r opt; do
        description=$(__knit_param_description "${cmd}" "${opt}")
        opt2="--$(_knit_str_underscores_to_hyphens "${opt}")"
        local when_raw_var="_KNIT_CMD_${cmd}_2_${opt}_when_raw"
        local annotation="required"
        if [[ -v "${when_raw_var}" ]]; then
            annotation="required, when: ${!when_raw_var}"
        fi
        printf "  %-${max_opt_length}s  [%s] %s\n" "${opt2} <value>" "${annotation}" "${description}"
    done < <(_knit_set_iter "${required_args_varname}")
    while read -r opt; do
        description=$(__knit_param_description "${cmd}" "${opt}")
        default=$(__knit_param_default "${cmd}" "${opt}")
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
        description=$(__knit_param_description "${cmd}" "${opt}")
        opt2="--$(_knit_str_underscores_to_hyphens "${opt}")"
        local when_raw_var="_KNIT_CMD_${cmd}_2_${opt}_when_raw"
        local annotation="flag"
        if [[ -v "${when_raw_var}" ]]; then
            annotation="flag, when: ${!when_raw_var}"
        fi
        printf "  %-${max_opt_length}s  %s\n" "${opt2}" "        [${annotation}] ${description}"
    done < <(_knit_set_iter "${flags_args_varname}")

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
        hrule=$(printf "%*s" "${#sub_name}" "" | tr ' ' '-')
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
# @fn __knit_build_constraint_json()
#
# Build a jq JSON object from an expanded argument list, using type metadata to
# emit integers/reals/booleans as JSON native types and all other values as
# strings. Each parameter may be given as "--name value" or "--name=value"
# (flags already converted to "true"/"false" by __knit_expand_command_arguments).
#
# @param cmd Mangled command name (used for type lookups).
# @param ... Expanded argument list.
# ------------------------------------------------------------------------------
__knit_build_constraint_json() {
    local cmd="$1"
    shift
    local jq_args=("-n")
    local i=1
    while (( i <= $# )); do
        local token="${!i}"
        [[ "${token}" == "--" ]] && break
        local key val
        key=$(__knit_arg_name "${token}")
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
# @fn __knit_check_constraints()
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
__knit_check_constraints() {
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
    demangled_cmd=$(__knit_command_demangle "${cmd}")

    local json
    json=$(__knit_build_constraint_json "${cmd}" "${_exp_ref[@]}")

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
                __knit_find_flag "--${param}" "${_orig_ref[@]}" && user_provided=true
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
    done
    # create the mangled command name
    local cmd
    cmd=$(__knit_command_mangle "${demangled_cmd}")
    # check if the command exists
    if ! _knit_set_find _KNIT_COMMANDS "${cmd}"; then
        knit_fatal "Unknown command \"${demangled_cmd}\"."
    fi
    # get the name of the corresponding function
    local func_name_var="_KNIT_CMD_${cmd}_function"
    local func="${!func_name_var}"
    # check if the first argument is --help
    if [ "$1" = "--help" ]; then
        __knit_print_command_usage "${cmd}"
        return 0
    fi
    # check the arguments
    _knit_check_command_arguments "${cmd}" "$@"
    # expand missing optional arguments and flags
    # shellcheck disable=SC2034 # passed by name to __knit_check_constraints
    local -a original_args=("$@")
    local -a args
    readarray -d '' -t args < <(__knit_expand_command_arguments "${cmd}" "$@")
    # validate --when constraints
    __knit_check_constraints "${cmd}" original_args args
    # call the "before" callbacks
    __knit_execute_before_commands "${cmd}" "${args[@]}"
    # Start each invocation with a clean recording slate (outputs + row id) so a
    # previous invocation in the same process cannot leak stale values.
    declare -gA "_KNIT_CMD_${cmd}_output_value=()"
    unset "_KNIT_CMD_${cmd}_row_id"
    # call the function
    _KNIT_EXECUTING_COMMAND+=("${cmd}")
    $func "${args[@]}"
    local func_status=$?
    unset '_KNIT_EXECUTING_COMMAND[-1]'
    # call the "after" callbacks
    __knit_execute_after_commands "${cmd}" "${args[@]}"
    # Record this invocation as a database row if the command declared a table.
    __knit_record_invocation "${cmd}" "${args[@]}"
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
        if [[ "$(__knit_arg_name "${item}")" != "${param}" ]]; then
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
    if [[ ${#_KNIT_EXECUTING_COMMAND[@]} -eq 0 ]]; then
        knit_fatal "knit_output should be called from within a registered command function."
    fi
    local cmd="${_KNIT_EXECUTING_COMMAND[-1]}"
    local demangled_cmd
    demangled_cmd=$(__knit_command_demangle "${cmd}")
    local normalized
    normalized=$(__knit_name_normalize "${name}")
    if ! _knit_set_find "_KNIT_CMD_${cmd}_outputs" "${normalized}"; then
        knit_fatal "\"${name}\" is not a declared output of command \"${demangled_cmd}\"."
    fi
    local type_var
    type_var=$(__knit_output_type_var "${cmd}" "${normalized}")
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
# @fn __knit_record_invocation()
#
# Record the just-completed invocation of a command as one row in its table,
# when the command declared one with knit_with_table and the experiment is
# bootstrapped. The row id is, in order of precedence: an explicit id set via
# _knit_set_row_id; the job UUID from KNIT_JOB_PREFIX (the execution side of a
# job); otherwise a fresh uuid.
#
# @param cmd Mangled command name.
# @param ... The expanded invocation arguments.
# ------------------------------------------------------------------------------
__knit_record_invocation() {
    local cmd="$1"
    shift
    local table_var="_KNIT_CMD_${cmd}_table"
    local table="${!table_var:-}"
    [[ -z "${table}" ]] && return 0
    _knit_is_bootstrapped || return 0

    local id
    local rowid_var="_KNIT_CMD_${cmd}_row_id"
    if [[ -n "${!rowid_var:-}" ]]; then
        id="${!rowid_var}"
    elif [[ -n "${KNIT_JOB_PREFIX:-}" ]]; then
        id="$(basename "${KNIT_JOB_PREFIX}")"
    else
        id="$(_knit_uuidv7)"
    fi

    _knit_db_record_row "${cmd}" "${table}" "${id}" "$@"
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
        name="$(__knit_arg_name "${arg}")"
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
