#!/bin/bash

# ------------------------------------------------------------------------------
# List of registered commands.
# ------------------------------------------------------------------------------
_KNIT_COMMANDS=()

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
# @fn __knit_name_is_valid()
#
# Checks that a parameter or command name is valid, i.e. it has to start with a
# letter, followed by any number of alphanumerical characters and hyphens and
# underscores.
#
# @param param Parameter name to normalize.
# ------------------------------------------------------------------------------
__knit_name_is_valid() {
    if [[ "$1" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_-]*$ ]]; then
        return 0
    else
        return 1
    fi
}

# ------------------------------------------------------------------------------
# @fn __knit_param_check_declaration()
#
# This function carries out all the checks for a parameter to be declared by
# knit_with_required/optional/flag.
#
# @param suffix Suffix ("required", "optional", or "flag") to use for variables.
# @param param Parameter name.
# @param description Description of the parameter.
# ------------------------------------------------------------------------------
__knit_param_check_declaration() {
    local suffix="$1"
    local param="$2"
    local description="$3"

    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_with_${suffix} should be used after a call to \"knit_register\"."
    fi

    if ! __knit_name_is_valid "${param}"; then
        knit_fatal "Parameter \"${param}\" does not have a valid name."
    fi

    if [ -z "${description}" ]; then
        knit_warning "Not describing parameter \"${param}\" undermines its understandability."
    fi

    local cmd="${_KNIT_CURRENT_COMMAND}"
    local demangled_cmd
    demangled_cmd=$(__knit_command_demangle "${cmd}")
    local normalized
    normalized=$(__knit_name_normalize "${param}")

    if _knit_set_find "_KNIT_CMD_${cmd}_required" "${normalized}" \
    || _knit_set_find "_KNIT_CMD_${cmd}_optional" "${normalized}" \
    || _knit_set_find "_KNIT_CMD_${cmd}_flags" "${normalized}"; then
        knit_fatal "Parameter \"${param}\" already declared for \"${demangled_cmd}\"."
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
    printf "%s" "_KNIT_CMD_${cmd}_2_${param}_description"
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
    printf "%s" "_KNIT_CMD_${cmd}_2_${param}_default"
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
    local description
    description=$(printf '%q' "$3")
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
    eval "_KNIT_CMD_${cmd}_function=${name}"
    eval "_KNIT_CMD_${cmd}_description=${description}"
    eval "_KNIT_CMD_${cmd}_extra=''"
    eval "_KNIT_CMD_${cmd}_is_hidden=false"
    eval "_KNIT_CMD_${cmd}_before_cb=()"
    eval "_KNIT_CMD_${cmd}_after_cb=()"
    eval "_KNIT_CMD_${cmd}_sucommand_names=\"Subcommands\""
    _KNIT_CURRENT_FUNCTION="${name}"
    _KNIT_CURRENT_COMMAND="${cmd}"
    _KNIT_CURRENT_COMMAND_DEMANGLED="${demangled_cmd}"
}

# ------------------------------------------------------------------------------
# @fn knit_done()
#
# Finishes to register a function.
# ------------------------------------------------------------------------------
knit_done() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_warning "\"knit_done\" called without a matching \"knit_register\"."
    fi
    local name="${_KNIT_CURRENT_FUNCTION}"
    if ! declare -F "${name}" > /dev/null; then
        knit_fatal "Function \"${name}\" being registered is not defined."
    fi
    unset _KNIT_CURRENT_FUNCTION
    unset _KNIT_CURRENT_COMMAND
    unset _KNIT_CURRENT_COMMAND_DEMANGLED
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
    eval "${cmd_hidden_name}=true"
}

# ------------------------------------------------------------------------------
# @fn knit_with_subcommand_name()
#
# Change the names of subcommands for the command being registered
# (default subcommand name is "Subcommands").
# ------------------------------------------------------------------------------
knit_with_subcommand_name() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_with_subcommand_name should be used after a call to \"knit_register\"."
    fi
    knit_trace "Changin subcommand names from ${_KNIT_CURRENT_COMMAND_DEMANGLED} as to $1."
    local cmd="${_KNIT_CURRENT_COMMAND}"
    eval "_KNIT_CMD_${cmd}_sucommand_names=\"$1\""
}

# ------------------------------------------------------------------------------
# @fn knit_with_required()
#
# This function should be called right after a call to knit_register (or one of
# its variants) to declare required parameters that the command expects.
#
# Example:
# ```
# knit_register "say_hello" "greet" "Say hello to someone"
# knit_with_required "name" "Name of the person to greet"
# say_hello() {
#    ...
# }
# ```
# Indicates that the command "greet" requires a parameter --name.
#
# @param param Parameter name.
# @param description Description of the parameter.
# ------------------------------------------------------------------------------
knit_with_required() {
    __knit_param_check_declaration "required" "$1" "$2"
    local param
    param=$(__knit_name_normalize "$1")
    local cmd="${_KNIT_CURRENT_COMMAND}"
    local demangled_cmd="${_KNIT_CURRENT_COMMAND_DEMANGLED}"
    local description
    description=$(printf '%q' "$2")
    local description_var
    description_var=$(__knit_param_description_var "${cmd}" "${param}")
    knit_trace "Adding required parameter \"$1\" to command \"${demangled_cmd}\"."
    eval "${description_var}=${description}"
    _knit_set_add "_KNIT_CMD_${cmd}_required" "${param}"
}

# ------------------------------------------------------------------------------
# @fn knit_with_optional()
#
# This function should be called right after a call to knit_register (or one of
# its variants) to declare optional parameters for the command.
#
# Example:
# ```
# knit_register "say_hello" "greet" "Say hello to someone"
# knit_with_optional "name" "world" "Name of the person to greet"
# say_hello() {
#    ...
# }
# ```
# Indicates that the command "greet" has an optional parameter --name with
# default value "world".
#
# @param param Parameter name.
# @param default Default value.
# @param description Description of the parameter.
# ------------------------------------------------------------------------------
knit_with_optional() {
    __knit_param_check_declaration "optional" "$1" "$3"
    local param
    param=$(__knit_name_normalize "$1")
    local cmd="${_KNIT_CURRENT_COMMAND}"
    local demangled_cmd="${_KNIT_CURRENT_COMMAND_DEMANGLED}"
    local default
    default=$(printf '%q' "$2")
    local description
    description=$(printf '%q' "$3")
    local description_var
    description_var=$(__knit_param_description_var "${cmd}" "${param}")
    local default_var
    default_var=$(__knit_param_default_var "${cmd}" "${param}")
    knit_trace "Adding optional parameter \"$1\" to command \"${demangled_cmd}\"."
    eval "${description_var}=$description"
    eval "${default_var}=$default"
    _knit_set_add "_KNIT_CMD_${cmd}_optional" "${param}"
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
# ------------------------------------------------------------------------------
knit_with_flag() {
    __knit_param_check_declaration "flag" "$1" "$2"
    local param
    param=$(__knit_name_normalize "$1")
    local cmd="${_KNIT_CURRENT_COMMAND}"
    local demangled_cmd="${_KNIT_CURRENT_COMMAND_DEMANGLED}"
    local description
    description=$(printf '%q' "$2")
    local description_var
    description_var=$(__knit_param_description_var "${cmd}" "${param}")
    knit_trace "Adding flag \"$1\" to command \"${demangled_cmd}\"."
    eval "${description_var}=${description}"
    _knit_set_add "_KNIT_CMD_${cmd}_flags" "${param}"
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
    local description
    description=$(printf "%q" "$1")
    eval "_KNIT_CMD_${cmd}_extra=${description}"
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
    local demanled_cmd
    demangled_cmd=$(__knit_command_demangle "${cmd}")
    knit_trace "Executing callbacks before ${demanled_cmd}."
    local cb_list_name="_KNIT_CMD_${cmd}_before_cb"
    # shellcheck disable=SC2178
    local -n cb_list_ref="${cb_list_name}"
    for cb in "${cb_list_ref[@]}"; do
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
    local demanled_cmd
    demangled_cmd=$(__knit_command_demangle "${cmd}")
    knit_trace "Executing callbacks after ${demanled_cmd}."
    local cb_list_name="_KNIT_CMD_${cmd}_after_cb"
    # shellcheck disable=SC2178
    local -n cb_list_ref="${cb_list_name}"
    for cb in "${cb_list_ref[@]}"; do
        eval "${cb} $*"
    done
}

# ------------------------------------------------------------------------------
# @fn __knit_check_command_arguments()
#
# Check that the arguments expected by the command are provided. This function
# will fail with a fatal error (i.e. the script will stop) if a required
# argument is not provided, or if an argument provided does not match any
# any expected.
#
# @param cmd Name of the command (mangled).
# @param ... Arguments to pass to the command.
# ------------------------------------------------------------------------------
__knit_check_command_arguments() {
    local cmd="$1"
    local demangled_cmd
    demangled_cmd=$(__knit_command_demangle "${cmd}")
    shift
    local args=("$@")
    # Check that all the required arguments have been provided
    local required_args_varname="_KNIT_CMD_${cmd}_required"
    local -n required_args_ref="${required_args_varname}"
    local option
    for option in "${required_args_ref[@]}"; do
        if knit_get_parameter "${option}" "${args[@]}" > /dev/null; then
            continue
        fi
        local alt_format
        alt_format=$(_knit_str_underscores_to_hyphens "${option}")
        knit_fatal "Command \"${demangled_cmd}\" requires a --${option} or --${alt_format} option."
    done
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
        arg="$(__knit_name_normalize "${arg:2}")"
        if _knit_set_find "${required_args_varname}" "${arg}"; then
            ((i++))
            continue
        fi
        if _knit_set_find "${optional_args_varname}" "${arg}"; then
            ((i++))
            continue
        fi
        if _knit_set_find "${flags_args_varname}" "${arg}"; then
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
    local flag="$1"
    shift
    local list=("$@")

    local formatted_flag
    local item
    local arg
    formatted_flag=$(_knit_str_hyphens_to_underscores "${flag}")
    for item in "${list[@]}"; do
        if [[ "${item}" == "--" ]]; then
            break
        fi
        arg=$(_knit_str_hyphens_to_underscores "${item}")
        if [[ "${arg}" == "${formatted_flag}" ]]; then
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
            if [[ "$arg" == --*=* ]]; then
                local key="${arg%%=*}"
                local value="${arg#*=}"
                args+=("${key}" "${value}")
            else
                args+=("${arg}")
            fi
        else
            extra_args+=("${arg}")
        fi
    done
    # Add optional arguments that have not been provided
    local optional_args_varname="_KNIT_CMD_${cmd}_optional"
    local -n optional_args_ref="${optional_args_varname}"
    for option in "${optional_args_ref[@]}"; do
        if knit_get_parameter "${option}" "${args[@]}" > /dev/null; then
            continue
        fi
        local default_value
        default_value=$(__knit_param_default "${cmd}" "${option}")
        args+=("--${option}" "${default_value}")
    done
    # Handle flags (add them as option with value "true" or "false")
    local flags_args_varname="_KNIT_CMD_${cmd}_flags"
    local -n flags_args_ref="${flags_args_varname}"
    local flag
    for flag in "${flags_args_ref[@]}"; do
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
    done
    # Print the resulting arguments
    for arg in "${args[@]}" "${extra_args[@]}"; do
        printf "%q " "${arg}"
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
    local -n required_args_ref="${required_args_varname}"
    local optional_args_varname="_KNIT_CMD_${cmd}_optional"
    local -n optional_args_ref="${optional_args_varname}"
    local flags_args_varname="_KNIT_CMD_${cmd}_flags"
    local -n flags_args_ref="${flags_args_varname}"
    local max_opt_length=4 # size of "help"
    local opt
    local opt2
    for opt in "${required_args_ref[@]}"; do
        opt2="--${opt} <value>"
        local opt_length=${#opt2}
        if (( opt_length > max_opt_length )); then
            max_opt_length=${opt_length}
        fi
    done
    for opt in "${optional_args_ref[@]}"; do
        opt2="--${opt} <value>"
        local opt_length=${#opt2}
        if (( opt_length > max_opt_length )); then
            max_opt_length=${opt_length}
        fi
    done
    for opt in "${flags_args_ref[@]}"; do
        opt2="--${opt}"
        local opt_length=${#opt2}
        if (( opt_length > max_opt_length )); then
            max_opt_length=${opt_length}
        fi
    done

    local description
    local default

    printf "  %-${max_opt_length}s  %s\n" "--help" "Print this help message and exit."
    for opt in "${required_args_ref[@]}"; do
        description=$(__knit_param_description "${cmd}" "${opt}")
        opt2="--$(_knit_str_underscores_to_hyphens "${opt}")"
        printf "  %-${max_opt_length}s  %s\n" "${opt2} <value>" "[required] ${description}"
    done
    for opt in "${optional_args_ref[@]}"; do
        description=$(__knit_param_description "${cmd}" "${opt}")
        default=$(__knit_param_default "${cmd}" "${opt}")
        opt2="--$(_knit_str_underscores_to_hyphens "${opt}")"
        printf "  %-${max_opt_length}s  %s\n" "${opt2} <value>" "[default: '${default}'] ${description}"
    done
    max_opt_length=$((max_opt_length - 8))
    for opt in "${flags_args_ref[@]}"; do
        description=$(__knit_param_description "${cmd}" "${opt}")
        opt2="--$(_knit_str_underscores_to_hyphens "${opt}")"
        printf "  %-${max_opt_length}s  %s\n" "${opt2}" "        [flag] ${description}"
    done

    local subcommands=()
    local subcommands_full=()
    local max_subcommand_len=0
    local c
    if [[ "${cmd}" != "__main__" ]]; then # non-root command
        for c in "${_KNIT_COMMANDS[@]}"; do
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
        done
    else # root command
        for c in "${_KNIT_COMMANDS[@]}"; do
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
        done
    fi
    if [ "${#subcommands[@]}" -gt "0" ]; then
        local sub_name="_KNIT_CMD_${cmd}_sucommand_names"
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
    __knit_check_command_arguments "${cmd}" "$@"
    # expand missing optional arguments and flags
    local args
    args=$(__knit_expand_command_arguments "${cmd}" "$@")
    eval "args=(${args})"
    # call the "before" callbacks
    __knit_execute_before_commands "${cmd}" "${args[@]}"
    # call the function
    $func "${args[@]}"
    # call the "after" callbacks
    __knit_execute_after_commands "${cmd}" "${args[@]}"
}

# ------------------------------------------------------------------------------
# @fn knit_get_parameter()
#
# Search the list of arguments for a specific parameter. If found, the function
# will print the value associated with the parameter (flags will lead to this
# function printing "true" or "false"). If not found, this function will print
# nothing and return 1.
#
# @param param Parameter to search for (without the -- prefix).
# @param ... Arguments in which to search for the parameter.
# ------------------------------------------------------------------------------
knit_get_parameter() {
    local param
    param=$(_knit_str_hyphens_to_underscores "--$1")
    shift
    local list=("$@")
    local i
    for ((i=0; i < ${#list[@]}; i++)); do
        if [[ "${list[i]}" == "--" ]]; then
            break
        fi
        local arg
        arg=$(_knit_str_hyphens_to_underscores "${list[i]}")
        if [[ "${arg}" == "${param}" ]]; then
            if ((i + 1 < ${#list[@]})); then
                printf "%s" "${list[i+1]}"
                return 0
            else
                return 1
            fi
        fi
    done
    return 1
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
# @fn knit_set_program_description()
#
# Set the description of the program.
# ------------------------------------------------------------------------------
knit_set_program_description() {
    local description
    description=$(printf "%q" "$1")
    eval "_KNIT_CMD___main___description=${description}"
}
