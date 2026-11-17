#!/bin/bash

## @file claim.sh

# ------------------------------------------------------------------------------
# @var KNIT_CLAIM_HOLDS
#
# Verdict exit code a claim checker returns when the finding holds for the
# evaluated binding. Return it from a checker body instead of a bare 0, so the
# verdict reads for itself: `return "${KNIT_CLAIM_HOLDS}"`. See the verdict table
# in the claim documentation (design §3.4).
# ------------------------------------------------------------------------------
declare -g KNIT_CLAIM_HOLDS
KNIT_CLAIM_HOLDS=0

# ------------------------------------------------------------------------------
# @var KNIT_CLAIM_REFUTED
#
# Verdict exit code a claim checker returns when the finding is false for the
# evaluated binding: `return "${KNIT_CLAIM_REFUTED}"`.
# ------------------------------------------------------------------------------
declare -g KNIT_CLAIM_REFUTED
KNIT_CLAIM_REFUTED=1

# ------------------------------------------------------------------------------
# @var KNIT_CLAIM_INSUFFICIENT
#
# Verdict exit code a claim checker returns when there is not enough data to
# decide the finding yet: `return "${KNIT_CLAIM_INSUFFICIENT}"`. The honesty
# signal — "you cannot make this claim yet" — distinct from a refutation.
# ------------------------------------------------------------------------------
declare -g KNIT_CLAIM_INSUFFICIENT
KNIT_CLAIM_INSUFFICIENT=2

# ------------------------------------------------------------------------------
# @var _KNIT_CLAIM_STATEMENT_COLUMN
#
# Name of the framework column holding a recorded evaluation's resolved English
# statement. Declared as an output on every claim so the per-claim table carries
# the column and the standard row recorder fills it.
# ------------------------------------------------------------------------------
declare -g _KNIT_CLAIM_STATEMENT_COLUMN
_KNIT_CLAIM_STATEMENT_COLUMN="__statement__"

# ------------------------------------------------------------------------------
# @var _KNIT_CLAIM_VERDICT_COLUMN
#
# Name of the framework column holding a recorded evaluation's verdict (holds,
# refuted, or insufficient). Declared as an output on every claim, like
# _KNIT_CLAIM_STATEMENT_COLUMN.
# ------------------------------------------------------------------------------
declare -g _KNIT_CLAIM_VERDICT_COLUMN
_KNIT_CLAIM_VERDICT_COLUMN="__verdict__"

# ------------------------------------------------------------------------------
# @var _KNIT_CLAIM_EVALUATING
#
# Set to "1" by "claim check" for the duration of a claim's evaluation, so the
# claim's before-callback (_knit_claim_before_cb) can tell an evaluation through
# "claim check" from a direct, unguarded invocation of the claim subcommand. A
# direct invocation would auto-record a row and bypass the "--record" gate, so it
# is refused.
# ------------------------------------------------------------------------------
declare -g _KNIT_CLAIM_EVALUATING
_KNIT_CLAIM_EVALUATING=""

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
# knit_with_output   "p:integer" "Measured margin, percent."
# a_beats_b() {
#   ...
#   knit_output p "${margin}"
#   if (( margin > 0 )); then
#       return "${KNIT_CLAIM_HOLDS}"
#   fi
#   return "${KNIT_CLAIM_REFUTED}"
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
    # The claim's outcome lives in the "__verdict__" column (holds/refuted/
    # insufficient), so a numeric exit status recorded alongside would be
    # redundant: opt the table out of the reserved "__exit_status__" column.
    _knit_without_exit_status
    # Two framework columns carried by every claim table (design §5), declared as
    # outputs so the table schema gains them and the standard row recorder fills
    # them from the output store: the resolved English statement, and the verdict.
    # They are written only on "claim check --record" (see _knit_claim_record).
    knit_with_output "${_KNIT_CLAIM_STATEMENT_COLUMN}:string" \
        "Resolved English statement of a recorded evaluation (framework-filled)."
    knit_with_output "${_KNIT_CLAIM_VERDICT_COLUMN}:string" \
        "Verdict of a recorded evaluation: holds, refuted, or insufficient (framework-filled)."
    _KNIT_CLAIMS["${normalized_name}"]=1
    printf -v "_KNIT_CMD_${_KNIT_CURRENT_COMMAND}_type" '%s' 'claim'
    # The raw statement template, stored per claim so the evaluation verbs can
    # render the finding with the claim's parameters and outputs interpolated.
    printf -v "_KNIT_CLAIM_${_KNIT_CURRENT_COMMAND}_statement" '%s' "${statement}"
    # A claim observes the database and is not part of the campaign DAG, so it
    # records no provenance edge. The author does not write this.
    knit_without_provenance
    # A claim is evaluated only through "claim check"; a direct invocation of the
    # subcommand would auto-record a row and bypass the "--record" gate, so refuse
    # it (see _knit_claim_before_cb).
    knit_run_before _knit_claim_before_cb
}

# ------------------------------------------------------------------------------
# @fn _knit_claim_before_cb()
#
# Before-callback installed on every claim by knit_register_claim. It refuses a
# direct invocation of the claim subcommand: a claim is evaluated through
# "claim check", which sets _KNIT_CLAIM_EVALUATING for the duration of the run
# and controls whether a row is recorded ("--record"). Invoked directly, the
# claim would run through the ordinary command path and auto-record a row,
# defeating the read-only-by-default contract.
# ------------------------------------------------------------------------------
_knit_claim_before_cb() {
    if [[ "${_KNIT_CLAIM_EVALUATING}" != "1" ]]; then
        knit_fatal "A claim is evaluated via \"claim check [--record] -- <claim> [parameters]\", not invoked directly."
    fi
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

    # An output: its recorded value, else its declared "--unset" fallback (empty
    # when none was declared). A visible "never measured" marker and a claim-check
    # warning for an unset, fallback-less token are a later milestone.
    if _knit_set_find "_KNIT_CMD_${cmd}_outputs" "${name}"; then
        # shellcheck disable=SC2178 # nameref to the command's output-value array
        local -n _claim_outvals="_KNIT_CMD_${cmd}_output_value"
        if [[ -v _claim_outvals["${name}"] ]]; then
            __knit_ret="${_claim_outvals["${name}"]}"
        else
            local def
            _knit_output_unset_value def "${cmd}" "${name}"
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
        "${KNIT_CLAIM_HOLDS}")        __knit_ret="holds" ;;
        "${KNIT_CLAIM_REFUTED}")      __knit_ret="refuted" ;;
        "${KNIT_CLAIM_INSUFFICIENT}") __knit_ret="insufficient" ;;
        *)                            __knit_ret="" ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_claim_glyph()
#
# Map a verdict label to its marker glyph and color name: holds -> green "✓",
# refuted -> red "✗", insufficient (and any unexpected label) -> amber "?". Shared
# by the "claim check" report line and the "claim list" rows so the two cannot
# drift.
#
# @param[out] __knit_ret1 Name of the variable to hold the glyph.
# @param[out] __knit_ret2 Name of the variable to hold the color name.
# @param[in] verdict The verdict label.
# ------------------------------------------------------------------------------
_knit_claim_glyph() {
    local -n __knit_ret1=$1
    local -n __knit_ret2=$2
    case "$3" in
        holds)        __knit_ret1="✓"; __knit_ret2="green" ;;
        refuted)      __knit_ret1="✗"; __knit_ret2="red" ;;
        insufficient) __knit_ret1="?"; __knit_ret2="yellow" ;;
        *)            __knit_ret1="?"; __knit_ret2="yellow" ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_claim_paint()
#
# Render a glyph with its color, honoring the same gate as the rest of knit: the
# color is applied only when stdout is a terminal and NO_COLOR is unset; otherwise
# the plain glyph is returned unchanged. The glyph itself never changes, so a
# non-colored terminal still shows "✓" / "✗" / "?".
#
# @param[out] __knit_ret Name of the variable to hold the (maybe colored) glyph.
# @param[in] glyph The marker glyph.
# @param[in] color The color name (a key of _KNIT_COLORS).
# ------------------------------------------------------------------------------
_knit_claim_paint() {
    local -n __knit_ret=$1
    local glyph="$2"
    local color="$3"
    if [[ -z "${NO_COLOR+x}" ]] && _knit_stdout_is_terminal; then
        __knit_ret="${_KNIT_COLORS[${color}]}${glyph}${_KNIT_COLORS[reset]}"
    else
        __knit_ret="${glyph}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_claim_print()
#
# Print a rendered claim statement prefixed with its verdict marker: a green "✓"
# when the claim holds, a red "✗" when it is refuted, and an amber "?" with a
# short "— insufficient data" note when there is not enough data to decide. The
# marker is colored only when stdout is a terminal and NO_COLOR is unset (the same
# gate as the rest of knit); otherwise the plain glyph is printed.
#
# @param[in] verdict  The verdict label (holds, refuted, or insufficient).
# @param[in] sentence The rendered statement.
# ------------------------------------------------------------------------------
_knit_claim_print() {
    local verdict="$1"
    local sentence="$2"
    local glyph color note=""
    _knit_claim_glyph glyph color "${verdict}"
    [[ "${verdict}" == "insufficient" ]] && note=" — insufficient data"
    local marker
    _knit_claim_paint marker "${glyph}" "${color}"
    printf '%s %s%s\n' "${marker}" "${sentence}" "${note}"
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
# The checker always runs under KNIT_DISABLE_RECORDING, which suppresses the row
# write (and only the row write — knit_output still populates the output store),
# so evaluation itself stores nothing and the measured outputs stay available to
# render the statement. With "--record", the evaluation is additionally persisted
# as one row by _knit_claim_record after the verdict is known; a plain check
# writes nothing.
# ------------------------------------------------------------------------------
_knit_claim_check() {
    # Recording is off by default and on only with "--record".
    local record
    record=$(knit_get_parameter "record" "$@") || record="false"

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
    # and yield a verdict exit code, but record no row here. KNIT_DISABLE_RECORDING
    # suppresses the row write without suppressing knit_output. _KNIT_CLAIM_EVALUATING
    # lets the claim's before-callback allow this guarded invocation (a direct one
    # is refused).
    local verdict_code=0
    _KNIT_CLAIM_EVALUATING=1
    KNIT_DISABLE_RECORDING=true \
        _knit_invoke_command "claim" "${claim_name}" "${claim_args[@]}" \
        || verdict_code=$?
    _KNIT_CLAIM_EVALUATING=""

    local verdict
    _knit_claim_verdict_from_code verdict "${verdict_code}"
    if [[ -z "${verdict}" ]]; then
        # The checker itself failed (an exit code other than 0/1/2); report it
        # distinctly and never as a verdict, record nothing (even with --record),
        # and propagate its code.
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

    # Persist the evaluation when asked. Only a decided verdict reaches here, so a
    # checker error never records (handled above).
    if [[ "${record}" == "true" ]]; then
        _knit_claim_record "${claim_cmd}" "${sentence}" "${verdict}" \
            "${render_args[@]}"
    fi

    _knit_claim_print "${verdict}" "${sentence}"
    return "${verdict_code}"
}

# ------------------------------------------------------------------------------
# @fn _knit_claim_record()
#
# Record one evaluation of a claim as a row in the claim's table. The row carries
# what the standard recorder writes — the "id" (a fresh uuidv7), one column per
# condition parameter (read from the expanded binding), one column per measured
# output (read from the output store the checker just populated) — plus the two
# framework columns: the resolved English statement and the verdict. The two are
# stashed into the output store so the standard recorder emits them as their
# declared output columns; no provenance edge is written (a claim is out of the
# graph). The table is append-only, so repeated records append.
#
# Honors the global KNIT_DISABLE_RECORDING kill switch, like every other write.
#
# @param[in] cmd      The claim command (mangled name).
# @param[in] sentence The resolved English statement.
# @param[in] verdict  The verdict label (holds, refuted, or insufficient).
# @param[in] ...      The expanded binding (condition parameters).
# ------------------------------------------------------------------------------
_knit_claim_record() {
    local cmd="$1"
    local sentence="$2"
    local verdict="$3"
    shift 3
    [[ "${KNIT_DISABLE_RECORDING:-}" == "true" ]] && return 0

    local table_var="_KNIT_CMD_${cmd}_table"
    local table="${!table_var}"

    # Stash the two framework values into the output store so the standard row
    # recorder emits them as the "__statement__" / "__verdict__" output columns,
    # alongside the checker's measured outputs already in the store.
    # shellcheck disable=SC2178 # nameref to the command's output-value array
    local -n _claim_store="_KNIT_CMD_${cmd}_output_value"
    _claim_store["${_KNIT_CLAIM_STATEMENT_COLUMN}"]="${sentence}"
    _claim_store["${_KNIT_CLAIM_VERDICT_COLUMN}"]="${verdict}"

    local id
    id=$(_knit_uuidv7)
    # No provenance edge (empty edge_type) and no exit-status column (the claim
    # table opted out): record the row on its own.
    _knit_db_record_invocation "${cmd}" "${table}" "${id}" "" "" "" "" "" "" "" \
        "$@"
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
knit_with_flag "record" \
    "Also record the evaluation as a row in the claim's table (off by default)."
knit_with_dispatch "claim" "Claim name followed by its parameters."
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_claim_row_time()
#
# Decode the creation time of a recorded claim row from its uuidv7 "id": the
# leading 48 bits (the first 12 hex digits, ignoring dashes) are a big-endian Unix
# millisecond timestamp. The result is a local "YYYY-MM-DD HH:MM:SS" string, empty
# when the id does not start with 12 hex digits or when date(1) cannot format it.
#
# @param[out] __knit_ret Name of the variable to hold the formatted time.
# @param[in] id The row id (a uuidv7).
# ------------------------------------------------------------------------------
_knit_claim_row_time() {
    local -n __knit_ret=$1
    local hex="${2//-/}"
    hex="${hex:0:12}"
    if [[ ! "${hex}" =~ ^[0-9a-fA-F]{12}$ ]]; then
        __knit_ret=""
        return 0
    fi
    local sec=$(( 16#${hex} / 1000 ))
    __knit_ret="$(date -d "@${sec}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" \
        || __knit_ret=""
}

# ------------------------------------------------------------------------------
# @fn _knit_claim_list_one()
#
# List one claim's recorded evaluations under a header line (the claim's
# registered spelling). Each recorded row prints, newest-first (uuidv7 ids sort by
# time, so "ORDER BY id DESC" is newest-first), as an indented line: the verdict
# marker, the resolved statement, the binding (its condition parameters, as
# "name=value"), and the row's time. A claim with no recorded rows (or whose table
# is absent) prints "(no recorded evaluations)", so a declared-but-unevaluated
# claim still appears.
#
# @param[in] claim The claim name (normalized to underscores).
# ------------------------------------------------------------------------------
_knit_claim_list_one() {
    local claim="$1"
    local cmd
    _knit_command_mangle cmd "claim:${claim}"
    local table_var="_KNIT_CMD_${cmd}_table"
    local table="${!table_var}"

    # Header: the claim's own name (its registered spelling), not the full
    # "claim:<name>" command path — the leaf display basename set at registration.
    local display_var="_KNIT_CMD_${cmd}_display"
    printf '%s\n' "${!display_var}"

    # Build a SQL expression for the binding: each condition parameter rendered as
    # "name=value", joined with ", ". Empty (the SQL literal '') for a claim with
    # no condition parameters.
    local -a pcols=()
    local p
    while IFS= read -r p; do
        [[ -z "${p}" ]] && continue
        pcols+=("${p}")
    done < <({ _knit_set_iter "_KNIT_CMD_${cmd}_required"
               _knit_set_iter "_KNIT_CMD_${cmd}_optional"; } | sort)
    local binding_expr="''"
    if (( ${#pcols[@]} > 0 )); then
        local ident c=0
        binding_expr=""
        for p in "${pcols[@]}"; do
            _knit_db_sql_ident ident "${p}"
            (( c > 0 )) && binding_expr+=" || ', ' || "
            binding_expr+="'${p}=' || coalesce(${ident},'')"
            (( ++c ))
        done
    fi

    # One pipe-joined record per row: id, verdict, binding, then the statement
    # LAST so a "|" inside the English statement is absorbed by the final read
    # field rather than shifting columns.
    local verdict_ident statement_ident table_ident sql
    _knit_db_sql_ident verdict_ident "${_KNIT_CLAIM_VERDICT_COLUMN}"
    _knit_db_sql_ident statement_ident "${_KNIT_CLAIM_STATEMENT_COLUMN}"
    _knit_db_sql_ident table_ident "${table}"
    sql="SELECT id || '|' || coalesce(${verdict_ident},'') || '|' || \
(${binding_expr}) || '|' || coalesce(${statement_ident},'') \
FROM ${table_ident} ORDER BY id DESC;"

    local have_rows=0 id verdict binding statement glyph color marker time bindstr
    while IFS='|' read -r id verdict binding statement; do
        [[ -z "${id}" ]] && continue
        have_rows=1
        _knit_claim_glyph glyph color "${verdict}"
        _knit_claim_paint marker "${glyph}" "${color}"
        _knit_claim_row_time time "${id}"
        bindstr=""
        [[ -n "${binding}" ]] && bindstr="  [${binding}]"
        printf '  %s %s%s  %s\n' "${marker}" "${statement}" "${bindstr}" "${time}"
    done < <(_knit_sqlite3 "${sql}" 2>/dev/null)

    (( have_rows )) || printf '  (no recorded evaluations)\n'
}

# ------------------------------------------------------------------------------
# @fn _knit_claim_list()
#
# Body of "claim list": print the recorded evaluations of every declared claim,
# grouped per claim and newest-first within each (see _knit_claim_list_one). The
# claim set is the in-memory _KNIT_CLAIMS registry, so a claim declared but never
# recorded still appears. "--type <claim>" limits the listing to one claim type
# (the registered claim name; an unknown type is fatal). It is "--type", not
# "--name", because a claim is identified by its registered name, like "run" and
# "command" in "knit remove" — "--name" is reserved for per-instance aliases.
# ------------------------------------------------------------------------------
_knit_claim_list() {
    local type_filter
    type_filter=$(knit_get_parameter "type" "$@") || type_filter=""

    local -a claim_names=()
    if [[ -n "${type_filter}" ]]; then
        local normalized
        _knit_name_normalize normalized "${type_filter}"
        if [[ ! -v _KNIT_CLAIMS["${normalized}"] ]]; then
            knit_fatal "Unknown claim \"${type_filter}\"."
        fi
        claim_names=("${normalized}")
    else
        if (( ${#_KNIT_CLAIMS[@]} == 0 )); then
            printf 'No claims are declared.\n'
            return 0
        fi
        mapfile -t claim_names < <(printf '%s\n' "${!_KNIT_CLAIMS[@]}" | sort)
    fi

    local first=1 claim
    for claim in "${claim_names[@]}"; do
        (( first )) || printf '\n'
        first=0
        _knit_claim_list_one "${claim}"
    done
}

# ------------------------------------------------------------------------------
# The "claim list" subcommand: an ordinary read-only builtin (records nothing,
# emits no provenance) that lists the recorded evaluations of the declared claims.
# ------------------------------------------------------------------------------
knit_register "claim:list" _knit_claim_list \
    "List the recorded evaluations of the declared claims."
_knit_is_builtin
knit_without_provenance
knit_with_optional "type:string" "" "List only this claim type (its registered name)."
knit_done
