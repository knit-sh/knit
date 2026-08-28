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
# This file currently provides the command surface plus selection resolution:
# registration, the shared selector/flag declarations, the resolvers that turn a
# selector into the set of starting row ids, and bodies that validate the
# exactly-one-selector contract, resolve the selection, and print the starting
# ids. The closure, mapping, refusal, reporting, and deletion machinery is added
# in later milestones.
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
# @fn _knit_remove_table_kind()
#
# Resolve a table name to the remove entity kind of the rows it holds, returned
# through a caller-named variable. The framework tables map directly (jobs -> job,
# runs -> run, artifacts -> artifact); any other table maps through its owning
# command's _KNIT_CMD_<cmd>_type marker (setup / resource / app, or command for a
# plain command). A wrapper table is reported as "command" because remove:command
# covers wrappers. An unregistered table (no owning command) yields the empty
# string.
#
# @param[out] __knit_ret Name of the variable to hold the kind (empty if unknown).
# @param[in] table The table name to classify.
# ------------------------------------------------------------------------------
_knit_remove_table_kind() {
    local -n __knit_ret=$1; shift
    local table="$1"
    case "${table}" in
        "${_KNIT_JOBS_TABLE}")      __knit_ret="job";      return 0 ;;
        "${_KNIT_RUNS_TABLE}")      __knit_ret="run";      return 0 ;;
        "${_KNIT_ARTIFACTS_TABLE}") __knit_ret="artifact"; return 0 ;;
    esac
    if [[ ! -v _KNIT_DB_REGISTERED_TABLES["${table}"] ]]; then
        __knit_ret=""
        return 0
    fi
    local owner mangled type_var kind
    owner="${_KNIT_DB_REGISTERED_TABLES["${table}"]}"
    mangled="$(_knit_command_mangle "${owner}")"
    type_var="_KNIT_CMD_${mangled}_type"
    kind="${!type_var:-command}"
    [[ "${kind}" == "wrapper" ]] && kind="command"
    __knit_ret="${kind}"
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_id_table()
#
# Find which table a row id lives in, returned through a caller-named variable, by
# probing every registered table for the id. Row ids are globally unique across
# tables, so the first hit is authoritative. A table that was registered but never
# created is probed harmlessly (the error is silenced). The empty string means the
# id was not found in any table.
#
# @param[out] __knit_ret Name of the variable to hold the table name (empty if none).
# @param[in] id The row id to locate.
# ------------------------------------------------------------------------------
_knit_remove_id_table() {
    local -n __knit_ret=$1; shift
    local id="$1"
    __knit_ret=""
    local id_esc; _knit_sql_escape id_esc "${id}"
    # __-prefixed against a nameref-shadow collision: a caller passes its own
    # "table" temp as the output nameref, so the loop variable must not be "table".
    local __table ident hit
    for __table in "${!_KNIT_DB_REGISTERED_TABLES[@]}"; do
        _knit_db_sql_ident ident "${__table}"
        hit="$(_knit_sqlite3 \
            "SELECT 1 FROM ${ident} WHERE id='${id_esc}' LIMIT 1;" 2>/dev/null)" \
            || hit=""
        if [[ -n "${hit}" ]]; then
            __knit_ret="${__table}"
            return 0
        fi
    done
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_append_ids()
#
# Run a read-only SELECT and append each non-empty result line to a caller-named
# array. Errors (e.g. a table that was registered but never created) are silenced
# and simply yield no rows, so a probe against a not-yet-materialized table is a
# no-op rather than a failure. The array is appended to, never reset, so several
# calls can accumulate matches (used when a selector spans more than one table).
#
# @param[out] __knit_ret Name of the array to append the selected ids to.
# @param[in] sql The SELECT statement to run.
# ------------------------------------------------------------------------------
_knit_remove_append_ids() {
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n __knit_ret=$1; shift
    local sql="$1"
    local line
    while IFS= read -r line; do
        [[ -n "${line}" ]] && __knit_ret+=("${line}")
    done < <(_knit_sqlite3 "${sql}" 2>/dev/null)
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_tables_of_kind()
#
# Fill a caller-named array with every table that holds rows of a given entity
# kind. The framework kinds resolve to a single table each (job -> jobs, run ->
# runs, artifact -> artifacts); the other kinds (setup, resource, app, command)
# are gathered from the live table registry, skipping the framework tables (which
# carry their own kinds) and keeping only those whose owning command's kind
# matches. This is what lets a setup/resource --name scan every table of that
# kind.
#
# @param[out] __knit_ret Name of the array to fill with table names.
# @param[in] kind The entity kind to gather tables for.
# ------------------------------------------------------------------------------
_knit_remove_tables_of_kind() {
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n __knit_ret=$1; shift
    local kind="$1"
    __knit_ret=()
    case "${kind}" in
        job)      __knit_ret=("${_KNIT_JOBS_TABLE}");      return 0 ;;
        run)      __knit_ret=("${_KNIT_RUNS_TABLE}");      return 0 ;;
        artifact) __knit_ret=("${_KNIT_ARTIFACTS_TABLE}"); return 0 ;;
    esac
    local table tk
    for table in "${!_KNIT_DB_REGISTERED_TABLES[@]}"; do
        case "${table}" in
            "${_KNIT_JOBS_TABLE}"|"${_KNIT_RUNS_TABLE}"|"${_KNIT_ARTIFACTS_TABLE}")
                continue ;;
        esac
        _knit_remove_table_kind tk "${table}"
        [[ "${tk}" == "${kind}" ]] && __knit_ret+=("${table}")
    done
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_resolve_by_id()
#
# Resolve a --id selector to a one-element starting id set, verifying the id
# exists and belongs to the expected kind. A missing id is fatal; an id that
# exists but in a table of a different kind is fatal with a hint to use the right
# subcommand (e.g. remove:setup --id given a job id).
#
# @param[out] __knit_ret Name of the array to fill with the starting id.
# @param[in] kind The expected entity kind.
# @param[in] id The row id to resolve.
# ------------------------------------------------------------------------------
_knit_remove_resolve_by_id() {
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n __knit_ret=$1; shift
    local kind="$1" id="$2"
    __knit_ret=()
    local table
    _knit_remove_id_table table "${id}"
    if [[ -z "${table}" ]]; then
        knit_fatal "remove ${kind}: no row with id \"${id}\"."
    fi
    local found_kind
    _knit_remove_table_kind found_kind "${table}"
    if [[ "${found_kind}" != "${kind}" ]]; then
        knit_fatal "remove ${kind}: id \"${id}\" is a ${found_kind}, not a ${kind}; use \"remove ${found_kind} --id ${id}\"."
    fi
    __knit_ret=("${id}")
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_resolve_by_name()
#
# Resolve a --name selector (the instance name given at creation) to a starting
# id set. For setup/resource the name is scanned across every table of that kind
# via the "name" column, so it resolves from the database even after the instance
# directory is gone. For a job the name is the "jobs.name" alias. For run the name
# is the launched app (the runs "app" column); for app/command the name is the
# command/app name, which is its table. No match is fatal.
#
# @param[out] __knit_ret Name of the array to fill with the starting ids.
# @param[in] kind The entity kind.
# @param[in] name The instance/command name to resolve.
# ------------------------------------------------------------------------------
_knit_remove_resolve_by_name() {
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n __knit_ret=$1; shift
    local kind="$1" name="$2"
    __knit_ret=()
    local name_esc; _knit_sql_escape name_esc "${name}"
    local -a out=()
    case "${kind}" in
        setup|resource)
            local -a tables=()
            _knit_remove_tables_of_kind tables "${kind}"
            local t ident
            for t in "${tables[@]}"; do
                _knit_db_sql_ident ident "${t}"
                _knit_remove_append_ids out \
                    "SELECT id FROM ${ident} WHERE name='${name_esc}';"
            done
            ;;
        job)
            _knit_remove_append_ids out \
                "SELECT id FROM ${_KNIT_JOBS_TABLE} WHERE name='${name_esc}';"
            ;;
        run)
            _knit_remove_append_ids out \
                "SELECT id FROM ${_KNIT_RUNS_TABLE} WHERE app='${name_esc}';"
            ;;
        app|command)
            local tk
            _knit_remove_table_kind tk "${name}"
            if [[ "${tk}" == "${kind}" ]]; then
                local ident; _knit_db_sql_ident ident "${name}"
                _knit_remove_append_ids out "SELECT id FROM ${ident};"
            fi
            ;;
    esac
    if (( ${#out[@]} == 0 )); then
        knit_fatal "remove ${kind}: no ${kind} named \"${name}\"."
    fi
    __knit_ret=("${out[@]}")
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_resolve_by_type()
#
# Resolve a --type selector (every instance of a type) to a starting id set. For
# setup/resource the type is the per-command table (setup:<type> / resource:<type>),
# so this selects every row in it. For a job the type is the job-body table; the
# starting ids are the job submissions (jobs rows) whose body rows live in that
# table, reached by the "call" edge from the submission to its body. No match is
# fatal.
#
# @param[out] __knit_ret Name of the array to fill with the starting ids.
# @param[in] kind The entity kind (setup, resource, or job).
# @param[in] type The type to resolve.
# ------------------------------------------------------------------------------
_knit_remove_resolve_by_type() {
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n __knit_ret=$1; shift
    local kind="$1" type="$2"
    __knit_ret=()
    local -a out=()
    local ident
    case "${kind}" in
        setup)
            _knit_db_sql_ident ident "setup:${type}"
            _knit_remove_append_ids out "SELECT id FROM ${ident};"
            ;;
        resource)
            _knit_db_sql_ident ident "resource:${type}"
            _knit_remove_append_ids out "SELECT id FROM ${ident};"
            ;;
        job)
            _knit_db_sql_ident ident "${type}"
            _knit_remove_append_ids out \
                "SELECT DISTINCT source_id FROM ${_KNIT_PROV_TABLE} WHERE edge_type='call' AND source_id != '' AND target_id IN (SELECT id FROM ${ident});"
            ;;
    esac
    if (( ${#out[@]} == 0 )); then
        knit_fatal "remove ${kind}: no ${kind} of type \"${type}\"."
    fi
    __knit_ret=("${out[@]}")
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_resolve_by_path()
#
# Resolve a --path selector (remove:artifact) to a starting id set. The artifacts
# "path" column is UNIQUE, so at most one row matches. No match is fatal.
#
# @param[out] __knit_ret Name of the array to fill with the starting id.
# @param[in] path The artifacts-relative path to resolve.
# ------------------------------------------------------------------------------
_knit_remove_resolve_by_path() {
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n __knit_ret=$1; shift
    local path="$1"
    __knit_ret=()
    local -a out=()
    local path_esc; _knit_sql_escape path_esc "${path}"
    _knit_remove_append_ids out \
        "SELECT id FROM ${_KNIT_ARTIFACTS_TABLE} WHERE path='${path_esc}';"
    if (( ${#out[@]} == 0 )); then
        knit_fatal "remove artifact: no artifact at path \"${path}\"."
    fi
    __knit_ret=("${out[@]}")
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_resolve_by_group()
#
# Resolve a --group selector (remove:job) to a starting id set: every job whose
# "group" column equals the given name (a whole prepare batch). The reserved
# "group" identifier is quoted. No match is fatal.
#
# @param[out] __knit_ret Name of the array to fill with the starting ids.
# @param[in] group The group name to resolve.
# ------------------------------------------------------------------------------
_knit_remove_resolve_by_group() {
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n __knit_ret=$1; shift
    local group="$1"
    __knit_ret=()
    local -a out=()
    local group_esc; _knit_sql_escape group_esc "${group}"
    local group_ident; _knit_db_sql_ident group_ident "group"
    _knit_remove_append_ids out \
        "SELECT id FROM ${_KNIT_JOBS_TABLE} WHERE ${group_ident}='${group_esc}';"
    if (( ${#out[@]} == 0 )); then
        knit_fatal "remove job: no job in group \"${group}\"."
    fi
    __knit_ret=("${out[@]}")
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_resolve_selection()
#
# Resolve a remove subcommand's selection into its starting id set, returned
# through a caller-named array. Reads whichever selector was provided (the
# exactly-one contract is already enforced by the --when constraints and the body
# presence check) and dispatches to the per-selector resolver for the kind. Every
# resolver is fatal on zero matches; one or many matches all become starting ids.
#
# @param[out] __knit_ret Name of the array to fill with the starting ids.
# @param[in] kind The entity kind of the subcommand.
# @param[in] ... The command invocation arguments (the selectors are read here).
# ------------------------------------------------------------------------------
_knit_remove_resolve_selection() {
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n __knit_ret=$1; shift
    local kind="$1"; shift
    __knit_ret=()

    local id name type path group
    id="$(knit_get_parameter "id" "$@")"       || id=""
    name="$(knit_get_parameter "name" "$@")"   || name=""
    type="$(knit_get_parameter "type" "$@")"   || type=""
    path="$(knit_get_parameter "path" "$@")"   || path=""
    group="$(knit_get_parameter "group" "$@")" || group=""

    local -a resolved=()
    if [[ -n "${id}" ]]; then
        _knit_remove_resolve_by_id resolved "${kind}" "${id}"
    elif [[ -n "${name}" ]]; then
        _knit_remove_resolve_by_name resolved "${kind}" "${name}"
    elif [[ -n "${type}" ]]; then
        _knit_remove_resolve_by_type resolved "${kind}" "${type}"
    elif [[ -n "${path}" ]]; then
        _knit_remove_resolve_by_path resolved "${path}"
    elif [[ -n "${group}" ]]; then
        _knit_remove_resolve_by_group resolved "${group}"
    fi
    __knit_ret=("${resolved[@]}")
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
# Body of 'remove setup': enforce the selector contract, resolve the selection to
# its starting id set, and print those ids. The closure and deletion machinery is
# added in later milestones.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_setup() {
    _knit_remove_require_one_selector id name type -- "$@"
    local -a ids=()
    _knit_remove_resolve_selection ids "setup" "$@"
    printf '%s\n' "${ids[@]}"
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
# Body of 'remove resource': enforce the selector contract, resolve the selection
# to its starting id set, and print those ids. The closure and deletion machinery
# is added in later milestones.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_resource() {
    _knit_remove_require_one_selector id name type -- "$@"
    local -a ids=()
    _knit_remove_resolve_selection ids "resource" "$@"
    printf '%s\n' "${ids[@]}"
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
# Body of 'remove job': enforce the selector contract, resolve the selection to
# its starting id set, and print those ids. The closure and deletion machinery is
# added in later milestones.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_job() {
    _knit_remove_require_one_selector id name type group -- "$@"
    local -a ids=()
    _knit_remove_resolve_selection ids "job" "$@"
    printf '%s\n' "${ids[@]}"
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
# Body of 'remove run': enforce the selector contract, resolve the selection to
# its starting id set, and print those ids. The closure and deletion machinery is
# added in later milestones.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_run() {
    _knit_remove_require_one_selector id name -- "$@"
    local -a ids=()
    _knit_remove_resolve_selection ids "run" "$@"
    printf '%s\n' "${ids[@]}"
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
# Body of 'remove app': enforce the selector contract, resolve the selection to
# its starting id set, and print those ids. The closure and deletion machinery is
# added in later milestones.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_app() {
    _knit_remove_require_one_selector id name -- "$@"
    local -a ids=()
    _knit_remove_resolve_selection ids "app" "$@"
    printf '%s\n' "${ids[@]}"
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
# Body of 'remove command': enforce the selector contract, resolve the selection
# to its starting id set, and print those ids. The closure and deletion machinery
# is added in later milestones.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_command() {
    _knit_remove_require_one_selector id name -- "$@"
    local -a ids=()
    _knit_remove_resolve_selection ids "command" "$@"
    printf '%s\n' "${ids[@]}"
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
# Body of 'remove artifact': enforce the selector contract, resolve the selection
# to its starting id set, and print those ids. The closure and deletion machinery
# is added in later milestones.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_artifact() {
    _knit_remove_require_one_selector id path -- "$@"
    local -a ids=()
    _knit_remove_resolve_selection ids "artifact" "$@"
    printf '%s\n' "${ids[@]}"
}
knit_done
