#!/bin/bash

## @file remove.sh

# ------------------------------------------------------------------------------
# The `remove` command group erases recorded entities (a setup, a resource, a
# job, a run, an app invocation, a plain command invocation, or an artifact)
# together with their provenance edges and, transitively, everything downstream
# of them. It reads and writes the experiment database, so every subcommand is a
# post-bootstrap builtin: it is NOT marked knit_usable_before_bootstrap (the
# central runtime guard refuses it until the experiment is bootstrapped, which is
# also what makes the --when selector constraints legal), it declares no table
# with knit_with_table (remove must never record a row it is meant to be
# deleting), and it runs knit_without_provenance so it emits no `call` edge of
# its own.
#
# This file currently provides the command surface only: registration, the
# shared selector/flag declarations, and stub bodies that validate the
# exactly-one-selector contract and then report that removal is not yet
# implemented. The resolution, closure, mapping, refusal, reporting, and
# deletion machinery is added in later milestones.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# @fn _knit_remove_declare_selectors()
#
# Declare a remove subcommand's selector parameters, each as an optional string
# with a --when constraint that enforces mutual exclusion: a selector applies
# only when every other selector of the same subcommand is empty, so providing
# two at once is fatal. This makes the exactly-one contract's exclusion half
# declarative; the presence half (rejecting zero selectors) is a body check
# (_knit_remove_require_one_selector). Call it between knit_register and
# knit_done, so the knit_with_optional calls attach to the command being
# registered.
#
# @param[in] kind The entity kind, used in the parameter descriptions.
# @param[in] ... The selector names to declare (a subset of id, name, type,
#        group, path).
# ------------------------------------------------------------------------------
_knit_remove_declare_selectors() {
    local kind="$1"; shift
    local -a selectors=("$@")
    local sel other clause desc
    for sel in "${selectors[@]}"; do
        clause=""
        for other in "${selectors[@]}"; do
            [[ "${other}" == "${sel}" ]] && continue
            [[ -n "${clause}" ]] && clause+=" and "
            clause+=".${other} == \"\""
        done
        case "${sel}" in
            id)    desc="Erase the ${kind} with this row id." ;;
            name)  desc="Erase the ${kind} with this instance name." ;;
            type)  desc="Erase every ${kind} of this type." ;;
            group) desc="Erase every job in this group." ;;
            path)  desc="Erase the artifact at this artifacts-relative path." ;;
            *)     desc="Erase the ${kind} selected by --${sel}." ;;
        esac
        knit_with_optional "${sel}:string" "" "${desc}" --when "${clause}"
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_declare_flags()
#
# Declare the flags shared by every remove subcommand. Call it between
# knit_register and knit_done.
# ------------------------------------------------------------------------------
_knit_remove_declare_flags() {
    knit_with_flag "yes" \
        "Proceed without the confirmation prompt (the report is still printed)."
    knit_with_flag "dry-run" \
        "Print what would be erased and exit without prompting or deleting."
    knit_with_flag "keep-files" \
        "Erase the database rows and edges but leave on-disk artifact entries in place."
    knit_with_flag "from-root" \
        "Widen the erase set to the whole call/produced lineage of the selection."
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_require_one_selector()
#
# Enforce the presence half of the exactly-one-selector contract: at least one
# of the named selectors must be provided. The mutual-exclusion half (at most
# one) is enforced declaratively by the --when constraints the selectors carry,
# so this only refuses the all-empty case. The selector names are given as
# leading arguments up to a literal "--", after which come the command
# invocation arguments.
#
# @param[in] ... The selector names, then "--", then the invocation arguments.
# @return Fatal if no selector was provided; otherwise 0.
# ------------------------------------------------------------------------------
_knit_remove_require_one_selector() {
    local -a selectors=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        selectors+=("$1"); shift
    done
    shift  # drop the "--"
    local sel value count=0
    for sel in "${selectors[@]}"; do
        value="$(knit_get_parameter "${sel}" "$@")" || value=""
        [[ -n "${value}" ]] && count=$((count + 1))
    done
    if (( count == 0 )); then
        knit_fatal "remove: exactly one selector is required (one of: ${selectors[*]/#/--})."
    fi
}

# ------------------------------------------------------------------------------
# Registration of the remove command group.
# ------------------------------------------------------------------------------
knit_register remove knit_empty \
    "Erase recorded entities and their provenance from the database."
_knit_is_builtin
knit_without_provenance
knit_done

# ------------------------------------------------------------------------------
# Registration of 'remove setup'.
# ------------------------------------------------------------------------------
knit_register "remove:setup" _knit_remove_setup \
    "Erase a setup instance and everything that used it."
_knit_is_builtin
knit_without_provenance
_knit_remove_declare_selectors "setup" id name type
_knit_remove_declare_flags
# ------------------------------------------------------------------------------
# @fn _knit_remove_setup()
#
# Body of 'remove setup' (surface stub): enforce the selector contract, then
# report that removal is not yet implemented.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_setup() {
    _knit_remove_require_one_selector id name type -- "$@"
    knit_fatal "remove: not yet implemented"
}
knit_done

# ------------------------------------------------------------------------------
# Registration of 'remove resource'.
# ------------------------------------------------------------------------------
knit_register "remove:resource" _knit_remove_resource \
    "Erase a fetched resource instance and everything that used it."
_knit_is_builtin
knit_without_provenance
_knit_remove_declare_selectors "resource" id name type
_knit_remove_declare_flags
# ------------------------------------------------------------------------------
# @fn _knit_remove_resource()
#
# Body of 'remove resource' (surface stub): enforce the selector contract, then
# report that removal is not yet implemented.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_resource() {
    _knit_remove_require_one_selector id name type -- "$@"
    knit_fatal "remove: not yet implemented"
}
knit_done

# ------------------------------------------------------------------------------
# Registration of 'remove job'.
# ------------------------------------------------------------------------------
knit_register "remove:job" _knit_remove_job \
    "Erase a job (submission and body); the setup and resource it used stay."
_knit_is_builtin
knit_without_provenance
_knit_remove_declare_selectors "job" id name type group
_knit_remove_declare_flags
# ------------------------------------------------------------------------------
# @fn _knit_remove_job()
#
# Body of 'remove job' (surface stub): enforce the selector contract, then
# report that removal is not yet implemented.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_job() {
    _knit_remove_require_one_selector id name type group -- "$@"
    knit_fatal "remove: not yet implemented"
}
knit_done

# ------------------------------------------------------------------------------
# Registration of 'remove run'.
# ------------------------------------------------------------------------------
knit_register "remove:run" _knit_remove_run \
    "Erase a single run and its per-app row; the enclosing job stays."
_knit_is_builtin
knit_without_provenance
_knit_remove_declare_selectors "run" id name
_knit_remove_declare_flags
# ------------------------------------------------------------------------------
# @fn _knit_remove_run()
#
# Body of 'remove run' (surface stub): enforce the selector contract, then
# report that removal is not yet implemented.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_run() {
    _knit_remove_require_one_selector id name -- "$@"
    knit_fatal "remove: not yet implemented"
}
knit_done

# ------------------------------------------------------------------------------
# Registration of 'remove app'.
# ------------------------------------------------------------------------------
knit_register "remove:app" _knit_remove_app \
    "Erase an app-invocation row directly."
_knit_is_builtin
knit_without_provenance
_knit_remove_declare_selectors "app" id name
_knit_remove_declare_flags
# ------------------------------------------------------------------------------
# @fn _knit_remove_app()
#
# Body of 'remove app' (surface stub): enforce the selector contract, then
# report that removal is not yet implemented.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_app() {
    _knit_remove_require_one_selector id name -- "$@"
    knit_fatal "remove: not yet implemented"
}
knit_done

# ------------------------------------------------------------------------------
# Registration of 'remove command'.
# ------------------------------------------------------------------------------
knit_register "remove:command" _knit_remove_command \
    "Erase a plain command invocation row (also covers wrapper rows)."
_knit_is_builtin
knit_without_provenance
_knit_remove_declare_selectors "command" id name
_knit_remove_declare_flags
# ------------------------------------------------------------------------------
# @fn _knit_remove_command()
#
# Body of 'remove command' (surface stub): enforce the selector contract, then
# report that removal is not yet implemented.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_command() {
    _knit_remove_require_one_selector id name -- "$@"
    knit_fatal "remove: not yet implemented"
}
knit_done

# ------------------------------------------------------------------------------
# Registration of 'remove artifact'.
# ------------------------------------------------------------------------------
knit_register "remove:artifact" _knit_remove_artifact \
    "Name a produced artifact directly; meaningful only with --from-root."
_knit_is_builtin
knit_without_provenance
_knit_remove_declare_selectors "artifact" id path
_knit_remove_declare_flags
# ------------------------------------------------------------------------------
# @fn _knit_remove_artifact()
#
# Body of 'remove artifact' (surface stub): enforce the selector contract, then
# report that removal is not yet implemented.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_artifact() {
    _knit_remove_require_one_selector id path -- "$@"
    knit_fatal "remove: not yet implemented"
}
knit_done
