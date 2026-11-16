#!/bin/bash

## @file claim.sh

# ------------------------------------------------------------------------------
# @var _KNIT_CLAIMS
#
# Associative array mapping registered claim names (normalized to underscores) to
# 1. It is the in-memory registry of declared claims, held at registration time
# rather than in the database, so `claim list` can show a claim that is declared
# but has never recorded a row.
# ------------------------------------------------------------------------------
declare -gA _KNIT_CLAIMS

# ------------------------------------------------------------------------------
# The "claim" group command. A claim is registered as the subcommand
# `claim:<name>` (see knit_register_claim), so the "claim" parent must exist
# before any claim is declared. It is an empty namespace command: a builtin that
# only groups its subcommands (the evaluation verbs in §6 and every user claim),
# records nothing, and emits no provenance. The claim evaluation verbs read the
# database, so they are not usable before bootstrap; the central runtime guard
# refuses them until the experiment is bootstrapped.
# ------------------------------------------------------------------------------
knit_register claim knit_empty \
    "Evaluate and list executable claims about the experiment."
_knit_is_builtin
knit_without_provenance
knit_done

# ------------------------------------------------------------------------------
# @fn knit_register_claim()
#
# Register a claim, i.e. a subcommand of the "claim" command that evaluates a
# plain-English finding about the experiment and reports a verdict through its
# return code. Mirrors knit_register_job: it registers `claim:<name>`, backs it
# with a per-claim table named after the claim itself, records the name in
# _KNIT_CLAIMS, and marks the command type "claim" so the evaluation verbs can
# find it.
#
# A claim differs from an ordinary command in two ways. First, it stores the raw
# statement template (its third argument) so the evaluation verbs can render the
# finding with the claim's parameters and outputs interpolated. Second, it is
# marked knit_without_provenance automatically: a claim observes the database and
# is not part of the campaign DAG, so it emits no provenance edges. The author
# writes neither the table nor the provenance mark.
#
# A call to this function must be followed by any knit_with_* declarations, the
# definition of <fn>, and a call to knit_done.
#
# The names "check" and "list" are reserved: "claim check" evaluates a binding
# and "claim list" lists recorded findings, so a claim registered under one of
# these would mangle to the same command name and shadow the verb. Registering
# such a claim is fatal.
#
# @param[in] name        Short name for the claim (used as the subcommand name).
# @param[in] fn          Name of the Bash function implementing the checker.
# @param[in] statement   Plain-English statement template; each "@name" token is
#                        interpolated at render time with the value of the
#                        condition parameter or output named "name".
#
# Example:
# ```
# knit_register_claim "a-beats-b" "a_beats_b" \
#     "Algo A beats algo B by @p percent on @d."
# knit_with_required "d:string"  "Dataset name."
# knit_with_output   "p:integer" "0" "Measured margin, percent."
# a_beats_b() {
#   ...
# }
# knit_done
# ```
# ------------------------------------------------------------------------------
knit_register_claim() {
    local name="$1"
    local fn="$2"
    local statement="$3"
    case "${name}" in
        check|list)
            knit_fatal "Claim name \"${name}\" is reserved (it would shadow a \"claim\" subcommand)."
            ;;
    esac
    knit_register "claim:${name}" "${fn}" "${statement}"
    # Canonical (underscore) name: used both for the per-claim table and the
    # registry key so they stay stable whether the claim is registered or
    # evaluated with hyphens or underscores (the registered spelling is kept for
    # display).
    local normalized_name
    _knit_name_normalize normalized_name "${name}"
    # Record each claim's evaluations in a table named after the claim itself (not
    # the "claim:<name>" command name), so the table reads naturally and needs no
    # SQL quoting of the colon. Recording a row is conditional on "--record" (see
    # the evaluation verb); declaring the table here only sets up its schema.
    knit_with_table "${normalized_name}"
    _KNIT_CLAIMS["${normalized_name}"]=1
    printf -v "_KNIT_CMD_${_KNIT_CURRENT_COMMAND}_type" '%s' 'claim'
    # The raw statement template, stored per claim so the evaluation verbs can
    # render the finding with the claim's parameters and outputs interpolated.
    printf -v "_KNIT_CLAIM_${_KNIT_CURRENT_COMMAND}_statement" '%s' "${statement}"
    # A claim observes the database and is not part of the campaign DAG, so it
    # records no provenance edge. The author does not write this.
    knit_without_provenance
}

# ------------------------------------------------------------------------------
# @fn _knit_claim_token_value()
#
# Resolve a single statement token name to its value, for _knit_claim_render. The
# raw name is normalized (hyphens to underscores) and looked up, in order, among
# the command's declared outputs, then its condition parameters (required,
# optional) and flags:
#
#   - an output takes its recorded value from the command's output-value store
#     (set by knit_output in the checker body), falling back to its declared
#     default when the checker did not set it;
#   - a condition parameter or flag takes its value from the invocation arguments
#     (an argument the author or reviewer passed on the command line), empty when
#     absent.
#
# A name that is neither a declared output nor a declared parameter is a fatal
# error: it is almost always a typo in the statement template.
#
# @param[out] __knit_ret Name of the variable to hold the resolved value.
# @param[in] cmd      The claim command (mangled name).
# @param[in] raw_name The token name as written in the template (pre-normalize).
# @param[in] ...      The invocation arguments (for condition parameters/flags).
# ------------------------------------------------------------------------------
_knit_claim_token_value() {
    local -n __knit_ret=$1
    local cmd="$2"
    local raw_name="$3"
    shift 3

    local name
    _knit_name_normalize name "${raw_name}"

    # An output: its recorded value, else its declared default.
    if _knit_set_find "_KNIT_CMD_${cmd}_outputs" "${name}"; then
        # shellcheck disable=SC2178 # nameref to the command's output-value array
        local -n _claim_outvals="_KNIT_CMD_${cmd}_output_value"
        if [[ -v _claim_outvals["${name}"] ]]; then
            __knit_ret="${_claim_outvals["${name}"]}"
        else
            local def
            _knit_output_default def "${cmd}" "${name}"
            __knit_ret="${def}"
        fi
        return 0
    fi

    # A condition parameter or flag: its value from the invocation arguments.
    # "__knit_pval" is prefixed because a caller passes its own output variable
    # (commonly "value") as the nameref target; a plain "value" local would shadow
    # it and the final assignment would write to the shadow, not the caller.
    if _knit_set_find "_KNIT_CMD_${cmd}_required" "${name}" \
        || _knit_set_find "_KNIT_CMD_${cmd}_optional" "${name}" \
        || _knit_set_find "_KNIT_CMD_${cmd}_flags" "${name}"; then
        local __knit_pval
        __knit_pval="$(knit_get_parameter "${name}" "$@")" || __knit_pval=""
        __knit_ret="${__knit_pval}"
        return 0
    fi

    local display
    _knit_command_display display "${cmd}"
    knit_fatal "claim \"%s\": statement references \"@%s\", which is not a declared parameter or output." \
        "${display}" "${raw_name}"
}

# ------------------------------------------------------------------------------
# @fn _knit_claim_render()
#
# Render a claim statement template into a plain-English sentence by interpolating
# its tokens. Each "@name" or "@{name}" token is replaced with the value of the
# condition parameter or output named "name" (see _knit_claim_token_value). A
# literal "@" is written "@@".
#
# Token syntax (design §3.3):
#   - a bare token is "@" followed by a run of identifier characters
#     ([A-Za-z0-9_]); the first non-identifier character — whitespace or
#     punctuation — ends it, so a statement can end in a token ("by @s%" keeps
#     the "%"), and the value can be made to abut following text with the brace
#     form;
#   - "@{name}" delimits the name explicitly, so a value can abut an identifier
#     character ("@{s}x" interpolates "s" then the literal "x");
#   - "@@" renders a single literal "@".
#
# A lone "@" that begins neither a token nor "@@" (e.g. "@" at end of string, or
# "@ ") is a fatal error, as is an unterminated "@{" and an empty token name:
# each is a malformed template.
#
# @param[out] __knit_ret Name of the variable to hold the rendered sentence.
# @param[in] template The statement template.
# @param[in] cmd      The claim command (mangled name).
# @param[in] ...      The invocation arguments (for condition parameters/flags).
# ------------------------------------------------------------------------------
_knit_claim_render() {
    local -n __knit_ret=$1
    local template="$2"
    local cmd="$3"
    shift 3

    # "__knit_rendered" is prefixed because a caller passes its own output
    # variable (commonly "out") as the nameref target; a plain "out" accumulator
    # would shadow it and the final assignment would write to the shadow (see the
    # same guard in _knit_command_display).
    local __knit_rendered="" i=0 n="${#template}"
    while (( i < n )); do
        local ch="${template:i:1}"
        if [[ "${ch}" != "@" ]]; then
            __knit_rendered+="${ch}"
            (( ++i ))
            continue
        fi

        # "@@" is a literal "@".
        if [[ "${template:i+1:1}" == "@" ]]; then
            __knit_rendered+="@"
            (( i += 2 ))
            continue
        fi

        local name="" j
        if [[ "${template:i+1:1}" == "{" ]]; then
            # Braced form "@{name}": the name is everything up to the next "}".
            j=$(( i + 2 ))
            while (( j < n )) && [[ "${template:j:1}" != "}" ]]; do
                name+="${template:j:1}"
                (( ++j ))
            done
            if (( j >= n )); then
                knit_fatal "claim statement: unterminated \"@{\" token in \"%s\"." \
                    "${template}"
            fi
            i=$(( j + 1 ))
        else
            # Bare form "@name": a run of identifier characters.
            j=$(( i + 1 ))
            while (( j < n )) && [[ "${template:j:1}" =~ [A-Za-z0-9_] ]]; do
                name+="${template:j:1}"
                (( ++j ))
            done
            i="${j}"
        fi

        if [[ -z "${name}" ]]; then
            knit_fatal "claim statement: empty \"@\" token in \"%s\" (write \"@@\" for a literal \"@\")." \
                "${template}"
        fi

        local tokval
        _knit_claim_token_value tokval "${cmd}" "${name}" "$@"
        __knit_rendered+="${tokval}"
    done

    __knit_ret="${__knit_rendered}"
}

# ------------------------------------------------------------------------------
# @fn _knit_claim_verdict_from_code()
#
# Map a checker's exit code to a claim verdict (design §3.4): 0 holds, 1 refuted,
# 2 insufficient. Any other code is a checker error (the checker itself failed),
# which is not a verdict; the result variable is left empty so the caller can
# report it distinctly.
#
# @param[out] __knit_ret Name of the variable to hold the verdict label.
# @param[in] code The checker's exit code.
# ------------------------------------------------------------------------------
_knit_claim_verdict_from_code() {
    local -n __knit_ret=$1
    case "$2" in
        0) __knit_ret="holds" ;;
        1) __knit_ret="refuted" ;;
        2) __knit_ret="insufficient" ;;
        *) __knit_ret="" ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_claim_print()
#
# Print a rendered claim statement prefixed with its verdict marker: a green "✓"
# when the claim holds, a red "✗" when it is refuted, and an amber "?" with a
# short "— insufficient data" note when there is not enough data to decide. The
# marker is colored only when stdout is a terminal and NO_COLOR is unset (the same
# gate as the rest of knit); otherwise the plain glyph is printed. The glyph
# itself never changes, so a non-colored terminal still shows "✓" / "✗" / "?".
#
# @param[in] verdict  The verdict label (holds, refuted, or insufficient).
# @param[in] sentence The rendered statement.
# ------------------------------------------------------------------------------
_knit_claim_print() {
    local verdict="$1"
    local sentence="$2"
    local glyph color note=""
    case "${verdict}" in
        holds)        glyph="✓"; color="green" ;;
        refuted)      glyph="✗"; color="red" ;;
        insufficient) glyph="?"; color="yellow"; note=" — insufficient data" ;;
        *)            glyph="?"; color="yellow" ;;
    esac
    if [[ -z "${NO_COLOR+x}" ]] && _knit_stdout_is_terminal; then
        printf '%s%s%s %s%s\n' \
            "${_KNIT_COLORS[${color}]}" "${glyph}" "${_KNIT_COLORS[reset]}" \
            "${sentence}" "${note}"
    else
        printf '%s %s%s\n' "${glyph}" "${sentence}" "${note}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_claim_check()
#
# Body of the "claim check" dispatcher. Evaluates one claim binding against the
# current database and reports the verdict: it reads the claim name and its
# parameters after "--", runs the claim's checker read-only (recording nothing),
# maps the checker's exit code to a verdict (design §3.4), renders the claim's
# statement with the binding's parameters and the checker's measured outputs, and
# prints the sentence with its verdict marker. The process exit code is set to the
# checker's exit code, so a holding claim returns 0, a refuted one 1, an
# insufficient one 2, and a checker error propagates its own code.
#
# The checker runs under KNIT_DISABLE_RECORDING, which suppresses the row write
# (and only the row write — knit_output still populates the output store), so a
# plain "claim check" observes and reports but stores nothing.
# ------------------------------------------------------------------------------
_knit_claim_check() {
    # Everything after "--" is the claim name followed by its own parameters.
    local -a args=("$@")
    local extra_index
    extra_index=$(knit_extra_index "${args[@]}")
    local -a extra=("${args[@]:extra_index}")
    if [[ ${#extra[@]} -eq 0 ]]; then
        knit_fatal "claim check requires a claim name (pass it after \"--\")."
    fi

    # The claim name as typed (kept for the "unknown" error) and its canonical
    # (underscore) form, which drives lookup and the registered command name.
    local claim_typed="${extra[0]}"
    local claim_name
    _knit_name_normalize claim_name "${claim_typed}"
    local -a claim_args=("${extra[@]:1}")

    if [[ ! -v _KNIT_CLAIMS["${claim_name}"] ]]; then
        knit_fatal "Unknown claim \"${claim_typed}\"."
    fi

    local claim_cmd
    _knit_command_mangle claim_cmd "claim:${claim_name}"

    # Evaluate the claim read-only: run its checker to populate the output store
    # and yield a verdict exit code, but record no row. KNIT_DISABLE_RECORDING
    # suppresses the row write without suppressing knit_output, so the measured
    # outputs stay available to render the statement.
    local verdict_code=0
    KNIT_DISABLE_RECORDING=true \
        _knit_invoke_command "claim" "${claim_name}" "${claim_args[@]}" \
        || verdict_code=$?

    local verdict
    _knit_claim_verdict_from_code verdict "${verdict_code}"
    if [[ -z "${verdict}" ]]; then
        # The checker itself failed (an exit code other than 0/1/2); report it
        # distinctly and never as a verdict, and propagate its code.
        knit_error "claim \"%s\": checker exited with status %s (a checker error, not a verdict)." \
            "${claim_typed}" "${verdict_code}"
        return "${verdict_code}"
    fi

    # Render the statement with the binding's parameters (expanded so an omitted
    # optional shows its default) and the checker's freshly-set outputs.
    local -a render_args
    readarray -d '' -t render_args < \
        <(_knit_expand_command_arguments "${claim_cmd}" "${claim_args[@]}")
    local statement_var="_KNIT_CLAIM_${claim_cmd}_statement"
    local sentence
    _knit_claim_render sentence "${!statement_var}" "${claim_cmd}" \
        "${render_args[@]}"

    _knit_claim_print "${verdict}" "${sentence}"
    return "${verdict_code}"
}

# ------------------------------------------------------------------------------
# The "claim check" dispatcher. A claim is evaluated through it rather than
# directly: "claim check [OPTIONS] -- <claim> [parameters]" — no command takes a
# positional argument, so the claim name and its parameters follow "--" (the same
# shape as "submit"). It is a read-only builtin that records nothing and emits no
# provenance; the verdict is its exit code.
# ------------------------------------------------------------------------------
knit_register "claim:check" _knit_claim_check \
    "Evaluate a claim for one binding and report its verdict."
_knit_is_builtin
knit_without_provenance
knit_with_dispatch "claim" "Claim name followed by its parameters."
knit_done
