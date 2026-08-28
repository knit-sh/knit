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
# This file currently provides the command surface, selection resolution, both
# closure modes, and the erase-set mapping: registration, the shared selector/flag
# declarations, the resolvers that turn a selector into the set of starting row
# ids, the fixed-point downward closure over the provenance graph, the
# callee/artifact refusal check that rejects erasing a callee (or artifact) whose
# caller (or producer) is kept, the whole-lineage closure that --from-root selects
# (the connected component over call/produced edges, traversed both directions,
# with no refusal check), the mapping that resolves every erase-set id to its
# (table, kind) and reads each artifact's on-disk path and type before the row is
# gone, the collector that finds the plain (non-artifact) file/directory outputs
# remove leaves on disk, the non-terminal-job refusal that rejects erasing a job
# that has not finished, the report builder and printer that render the itemized
# plan (the data rows, the provenance edges, the on-disk directories and artifact
# entries to remove, and what is left on disk), and bodies that validate the
# exactly-one-selector contract, resolve the selection, compute whichever closure
# the flags request, run the refusal check in the default mode, map the erase set,
# refuse a non-terminal job, and either print the report and stop under --dry-run,
# print the report and delete the rows and files under --yes, or print the
# resulting erase set. The deletion transaction removes, in one atomic
# BEGIN...COMMIT, every provenance edge touching the erase set and then the data
# rows table by table. After a successful commit the filesystem phase removes, best
# effort, each erased job/setup/resource instance directory (setups and resources
# only when their on-disk marker still names the erased row) and -- unless
# --keep-files -- each artifact entry under the artifact root, and then reports the
# files it deliberately left on disk (a command's plain outputs, and kept artifact
# entries) and exits non-zero listing anything a removal could not clear. The
# confirmation prompt is added in a later milestone.
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
# @fn _knit_remove_closure_downward()
#
# Compute the default downward erase set from a set of starting ids, returned
# through a caller-named array. Starting from each id, the closure follows every
# outgoing provenance edge (source -> target) of the three edge types to a fixed
# point: a "call" edge (a caller owns its callees), a "produced" edge (a producer
# owns its artifacts), and a "used_by" edge from a provider (a setup or resource
# owns its consumers). Because the walk only follows edges where the current id is
# the SOURCE, a "used_by" edge is never followed backward into a provider (which
# would be the target), so erasing a consumer leaves its setup/resource intact.
# An associative visited set guards against revisiting an id (and against any
# accidental cycle from bad data), so each reachable id appears once.
#
# @param[out] __knit_ret Name of the array to fill with the erase-set ids.
# @param[in] ... The starting ids.
# ------------------------------------------------------------------------------
_knit_remove_closure_downward() {
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n __knit_ret=$1; shift
    __knit_ret=()
    local -A visited=()
    local -a worklist=("$@")
    local x x_esc target
    while (( ${#worklist[@]} > 0 )); do
        x="${worklist[-1]}"
        unset 'worklist[-1]'
        [[ -z "${x}" ]] && continue
        [[ -v visited["${x}"] ]] && continue
        visited["${x}"]=1
        __knit_ret+=("${x}")
        _knit_sql_escape x_esc "${x}"
        while IFS= read -r target; do
            [[ -n "${target}" ]] && worklist+=("${target}")
        done < <(_knit_sqlite3 \
            "SELECT target_id FROM ${_KNIT_PROV_TABLE} WHERE source_id='${x_esc}' AND edge_type IN ('call','used_by','produced');" \
            2>/dev/null)
    done
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_check_refusal()
#
# Enforce the callee/artifact refusal for the default (downward) closure. For each
# originally selected id, refuse the whole operation if that id is the target of a
# "call" or "produced" edge whose source is NOT in the erase set: erasing a callee
# while its caller stays (or an artifact while its producer stays) would leave the
# caller's/producer's edge dangling, so it is rejected. A "call" refusal points the
# user at removing the caller (with the caller's own remove subcommand) or passing
# --from-root; a "produced" refusal (a bare remove:artifact) points at --from-root,
# which pulls the producer in and erases the whole lineage. An edge with an empty
# source (a root invocation) never triggers a refusal.
#
# @param[in] __knit_selected Name of the array of originally selected ids.
# @param[in] __knit_erase    Name of the array holding the full erase set.
# @return Fatal on the first refusal; otherwise 0.
# ------------------------------------------------------------------------------
_knit_remove_check_refusal() {
    local -n __knit_selected=$1
    local -n __knit_erase=$2
    local -A in_set=()
    local e
    for e in "${__knit_erase[@]}"; do in_set["${e}"]=1; done
    local x x_esc src src_name etype tgt_name caller_table caller_kind hint
    for x in "${__knit_selected[@]}"; do
        _knit_sql_escape x_esc "${x}"
        while IFS='|' read -r src src_name etype tgt_name; do
            [[ -z "${src}" ]] && continue
            [[ -v in_set["${src}"] ]] && continue
            if [[ "${etype}" == "produced" ]]; then
                knit_fatal "remove: cannot erase artifact ${x}; it was produced by \"${src_name}\" (${src}), which is not being erased. Pass --from-root to erase the whole lineage."
            fi
            caller_kind=""
            _knit_remove_id_table caller_table "${src}"
            [[ -n "${caller_table}" ]] && \
                _knit_remove_table_kind caller_kind "${caller_table}"
            if [[ -n "${caller_kind}" ]]; then
                hint="Remove the caller instead (\"remove ${caller_kind} --id ${src}\") or pass --from-root to erase the whole lineage."
            else
                hint="Remove the caller instead or pass --from-root to erase the whole lineage."
            fi
            knit_fatal "remove: cannot erase ${tgt_name} (${x}); it is called by \"${src_name}\" (${src}), which is not being erased. ${hint}"
        done < <(_knit_sqlite3 \
            "SELECT source_id, source_name, edge_type, target_name FROM ${_KNIT_PROV_TABLE} WHERE edge_type IN ('call','produced') AND target_id='${x_esc}';" \
            2>/dev/null)
    done
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_closure_from_root()
#
# Compute the whole-lineage erase set that --from-root selects, returned through a
# caller-named array: the connected component of the starting ids in the subgraph
# made of "call" and "produced" edges only, traversed in BOTH directions. From
# each id the walk adds every neighbour across a call/produced edge, backward
# (target -> source: the caller that invoked it, or the producer that made it) and
# forward (source -> target: everything it called or produced). Iterated to a
# fixed point, the two directions climb to the root of the tree and back down over
# the whole tree, so pointing at any row (a callee, a run, an app, or an artifact)
# names the same lineage. "used_by" edges are NEVER queried, in either direction,
# so a setup or resource used by the tree is left intact (it belongs to its own
# tree). An associative visited set guards against revisiting an id, so each id
# appears once. There is no refusal check in this mode: pulling in the kept
# caller/producer is exactly what --from-root is for.
#
# @param[out] __knit_ret Name of the array to fill with the erase-set ids.
# @param[in] ... The starting ids.
# ------------------------------------------------------------------------------
_knit_remove_closure_from_root() {
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n __knit_ret=$1; shift
    __knit_ret=()
    local -A visited=()
    local -a worklist=("$@")
    local x x_esc neighbor
    while (( ${#worklist[@]} > 0 )); do
        x="${worklist[-1]}"
        unset 'worklist[-1]'
        [[ -z "${x}" ]] && continue
        [[ -v visited["${x}"] ]] && continue
        visited["${x}"]=1
        __knit_ret+=("${x}")
        _knit_sql_escape x_esc "${x}"
        while IFS= read -r neighbor; do
            [[ -n "${neighbor}" ]] && worklist+=("${neighbor}")
        done < <(_knit_sqlite3 \
            "SELECT target_id FROM ${_KNIT_PROV_TABLE} WHERE source_id='${x_esc}' AND edge_type IN ('call','produced') UNION SELECT source_id FROM ${_KNIT_PROV_TABLE} WHERE target_id='${x_esc}' AND edge_type IN ('call','produced');" \
            2>/dev/null)
    done
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_map_ids()
#
# Map every erase-set id to the table it lives in and the entity kind of that
# table, returned through two caller-named associative arrays (id -> table and
# id -> kind). For each id whose kind is "artifact" it additionally reads that
# row's on-disk path and type into two more caller-named associative arrays
# (id -> path and id -> type), because the filesystem phase needs them after the
# row itself has been deleted. An id whose table cannot be located (its owning
# command is not registered in the current script, so its table is absent from the
# registry _knit_remove_id_table probes) is skipped: it cannot be classified or
# grouped for deletion here. Row ids are globally unique across tables, so the
# id -> table map doubles as the group-by-table index the delete phase needs.
#
# @param[out] __knit_ret1 Name of the assoc array to fill (id -> table).
# @param[out] __knit_ret2 Name of the assoc array to fill (id -> kind).
# @param[out] __knit_ret3 Name of the assoc array to fill (artifact id -> path).
# @param[out] __knit_ret4 Name of the assoc array to fill (artifact id -> type).
# @param[in] ... The erase-set ids.
# ------------------------------------------------------------------------------
_knit_remove_map_ids() {
    # shellcheck disable=SC2178 # nameref to the caller's associative array
    local -n __knit_ret1=$1
    # shellcheck disable=SC2178 # nameref to the caller's associative array
    local -n __knit_ret2=$2
    # shellcheck disable=SC2178 # nameref to the caller's associative array
    local -n __knit_ret3=$3
    # shellcheck disable=SC2178 # nameref to the caller's associative array
    local -n __knit_ret4=$4
    shift 4
    __knit_ret1=()
    __knit_ret2=()
    __knit_ret3=()
    __knit_ret4=()
    local id tbl knd id_esc apath atype
    for id in "$@"; do
        [[ -z "${id}" ]] && continue
        _knit_remove_id_table tbl "${id}"
        [[ -z "${tbl}" ]] && continue
        _knit_remove_table_kind knd "${tbl}"
        __knit_ret1["${id}"]="${tbl}"
        __knit_ret2["${id}"]="${knd}"
        if [[ "${knd}" == "artifact" ]]; then
            _knit_sql_escape id_esc "${id}"
            apath="$(_knit_sqlite3 \
                "SELECT path FROM ${_KNIT_ARTIFACTS_TABLE} WHERE id='${id_esc}';" \
                2>/dev/null)" || apath=""
            atype="$(_knit_sqlite3 \
                "SELECT type FROM ${_KNIT_ARTIFACTS_TABLE} WHERE id='${id_esc}';" \
                2>/dev/null)" || atype=""
            __knit_ret3["${id}"]="${apath}"
            __knit_ret4["${id}"]="${atype}"
        fi
    done
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_plain_outputs()
#
# Collect the plain (non-artifact) file/directory OUTPUTS of every erased row into
# a caller-named associative array (recorded path -> owning command name), reading
# the id -> table map _knit_remove_map_ids produced. A plain output is a
# file/directory output a command declared that is NOT an artifact: for each row,
# the owning command's _KNIT_CMD_<cmd>_fileparams entries whose marker direction is
# "output" and whose name is not in _KNIT_CMD_<cmd>_artifacts; the recorded path is
# that row's <name> column. Input file/directory parameters are ignored (they are
# the run's inputs, not its outputs), and so are artifacts (their on-disk entries
# are handled by the filesystem phase). The framework tables (jobs/runs/artifacts)
# carry no user-declared file outputs and are skipped, as is any row whose owning
# command is no longer registered in the current script -- its file-parameter
# markers are absent, so its columns cannot be classified. remove never deletes
# these paths; the caller lists them under "Left on disk".
#
# @param[out] __knit_ret    Name of the assoc array to fill (path -> command).
# @param[in]  __knit_tables Name of the assoc array mapping id -> table.
# @param[in]  ...           The erase-set ids.
# ------------------------------------------------------------------------------
_knit_remove_plain_outputs() {
    # shellcheck disable=SC2178 # nameref to the caller's associative array
    local -n __knit_ret=$1
    local -n __knit_tables=$2
    shift 2
    __knit_ret=()
    local id tbl owner mangled param marker tblident colident value id_esc
    for id in "$@"; do
        [[ -z "${id}" ]] && continue
        tbl="${__knit_tables["${id}"]:-}"
        [[ -z "${tbl}" ]] && continue
        # Framework tables have no user-declared plain file outputs.
        case "${tbl}" in
            "${_KNIT_JOBS_TABLE}"|"${_KNIT_RUNS_TABLE}"|"${_KNIT_ARTIFACTS_TABLE}")
                continue ;;
        esac
        owner="${_KNIT_DB_REGISTERED_TABLES["${tbl}"]:-}"
        [[ -z "${owner}" ]] && continue
        mangled="$(_knit_command_mangle "${owner}")"
        # No file-parameter markers means the command has no file outputs to
        # classify (or is no longer registered): nothing to list for this row.
        _knit_set_exists "_KNIT_CMD_${mangled}_fileparams" || continue
        _knit_db_sql_ident tblident "${tbl}"
        _knit_sql_escape id_esc "${id}"
        while IFS= read -r param; do
            [[ -z "${param}" ]] && continue
            marker="_KNIT_CMD_${mangled}_fileparam_${param}"
            [[ "${!marker:-}" == output:* ]] || continue
            _knit_set_find "_KNIT_CMD_${mangled}_artifacts" "${param}" && continue
            _knit_db_sql_ident colident "${param}"
            value="$(_knit_sqlite3 \
                "SELECT ${colident} FROM ${tblident} WHERE id='${id_esc}';" \
                2>/dev/null)" || value=""
            [[ -n "${value}" ]] && __knit_ret["${value}"]="${owner}"
        done < <(_knit_set_iter "_KNIT_CMD_${mangled}_fileparams")
    done
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_check_terminal_jobs()
#
# Enforce that every job in the erase set has finished before anything is deleted.
# For each erase-set id whose table is the jobs table (read from the id -> table
# map _knit_remove_map_ids produced), the job's "state" column is read; a state
# other than "completed" or "killed" (that is, "submitted", "running", or
# "prepared") refuses the whole operation and points the user at "job cancel <id>"
# to stop or tear down the job first. There is no --force override: a live job must
# be cancelled before it can be erased. The refusal fires whether the job was named
# directly or pulled into the set by a cascade (a setup or resource it used being
# erased), because both reach it through the same erase-set membership.
#
# @param[in] __knit_tables Name of the assoc array mapping id -> table.
# @param[in] ...           The erase-set ids.
# @return Fatal on the first non-terminal job; otherwise 0.
# ------------------------------------------------------------------------------
_knit_remove_check_terminal_jobs() {
    local -n __knit_tables=$1; shift
    local id id_esc state
    for id in "$@"; do
        [[ -z "${id}" ]] && continue
        [[ "${__knit_tables["${id}"]:-}" == "${_KNIT_JOBS_TABLE}" ]] || continue
        _knit_sql_escape id_esc "${id}"
        state="$(_knit_sqlite3 \
            "SELECT state FROM ${_KNIT_JOBS_TABLE} WHERE id='${id_esc}';" \
            2>/dev/null)" || state=""
        case "${state}" in
            completed|killed) ;;
            *)
                knit_fatal "remove: cannot erase job ${id}; its state is \"${state:-unknown}\" (not completed or killed). Run \"job cancel ${id}\" first."
                ;;
        esac
    done
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_row_value()
#
# Read a single column of a single row, identified by id, into a caller-named
# variable (empty when the row, the column, or the table is absent -- the error
# is silenced). The report builder uses it to fetch a display field for one
# erase-set row: a setup or resource instance name, a job name or state, or a
# run's launched app.
#
# @param[out] __knit_ret Name of the variable to hold the column value.
# @param[in] table  The table to read from.
# @param[in] id     The row id.
# @param[in] column The column name to read.
# ------------------------------------------------------------------------------
_knit_remove_row_value() {
    # shellcheck disable=SC2178 # scalar nameref; the name is array-typed elsewhere in the file
    local -n __knit_ret=$1; shift
    local table="$1" id="$2" column="$3"
    local tblident colident id_esc
    _knit_db_sql_ident tblident "${table}"
    _knit_db_sql_ident colident "${column}"
    _knit_sql_escape id_esc "${id}"
    # shellcheck disable=SC2178 # scalar nameref (see above)
    __knit_ret="$(_knit_sqlite3 \
        "SELECT ${colident} FROM ${tblident} WHERE id='${id_esc}';" \
        2>/dev/null)"
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_id_in_list()
#
# Build a SQL IN-list -- a comma-separated sequence of single-quoted, escaped ids
# such as 'a','b','c' -- from a set of ids, returned through a caller-named
# variable (empty when no non-empty id is given). Every id is escaped with
# _knit_sql_escape, never interpolated raw. The report builder uses it to select
# the provenance edges touching the erase set; the deletion phase reuses it.
#
# @param[out] __knit_ret Name of the variable to hold the IN-list text.
# @param[in] ... The ids.
# ------------------------------------------------------------------------------
_knit_remove_id_in_list() {
    # shellcheck disable=SC2178 # scalar nameref; the name is array-typed elsewhere in the file
    local -n __knit_ret=$1; shift
    local -a quoted=()
    local id esc
    for id in "$@"; do
        [[ -z "${id}" ]] && continue
        _knit_sql_escape esc "${id}"
        quoted+=("'${esc}'")
    done
    local IFS=,
    # shellcheck disable=SC2178 # scalar nameref (see above)
    __knit_ret="${quoted[*]}"
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_build_report()
#
# Assemble the itemized removal report from the erase set and its maps, filling
# four caller-named arrays that _knit_remove_print_report lays out. All database
# reads and formatting happen here, so the printer is pure layout:
#   - the data-row lines, one per erase-set id in order, each "<kind> <label>
#     <id>" with a short annotation. A setup or resource shows "<type> (<name>)";
#     a job submission shows its state; a job body row is marked as such; a run
#     shows its launched app; an app or plain command shows its command name; an
#     artifact shows its path.
#   - the provenance-edge lines: every __provenance__ edge with an endpoint in the
#     set (exactly the edges the deletion removes, including a kept provider's
#     used_by edge into an erased consumer).
#   - the on-disk directories and artifact entries the removal deletes: each job
#     directory, each setup/resource instance directory, and -- unless keep_files
#     is "true" -- each artifact entry under the artifact root.
#   - the "left on disk" lines: the plain non-artifact outputs (always, attributed
#     to the owning command) and, under keep_files, the kept artifact entries.
#
# @param[out] __knit_ret1 Name of the array to fill with data-row lines.
# @param[out] __knit_ret2 Name of the array to fill with provenance-edge lines.
# @param[out] __knit_ret3 Name of the array to fill with removed dir/entry paths.
# @param[out] __knit_ret4 Name of the array to fill with "left on disk" lines.
# @param[in]  __knit_tables Name of the assoc array mapping id -> table.
# @param[in]  __knit_kinds  Name of the assoc array mapping id -> kind.
# @param[in]  __knit_apaths Name of the assoc array mapping artifact id -> path.
# @param[in]  __knit_plain  Name of the assoc array mapping plain output path -> command.
# @param[in]  keep_files    "true" to keep (not remove) artifact entries on disk.
# @param[in]  ...           The erase-set ids, in order.
# ------------------------------------------------------------------------------
_knit_remove_build_report() {
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n __knit_ret1=$1
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n __knit_ret2=$2
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n __knit_ret3=$3
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n __knit_ret4=$4
    local -n __knit_tables=$5
    local -n __knit_kinds=$6
    local -n __knit_apaths=$7
    local -n __knit_plain=$8
    shift 8
    local keep_files="$1"; shift
    local -a ids=("$@")
    __knit_ret1=()
    __knit_ret2=()
    __knit_ret3=()
    __knit_ret4=()

    # Roots resolved lazily and cached (each reads metadata).
    local job_root="" setup_root="" resource_root="" artifact_root=""

    local id kind tbl label annot line
    local etype ename apath name state
    for id in "${ids[@]}"; do
        [[ -z "${id}" ]] && continue
        tbl="${__knit_tables["${id}"]:-}"
        [[ -z "${tbl}" ]] && continue
        kind="${__knit_kinds["${id}"]:-}"
        label=""
        annot=""
        case "${kind}" in
            setup)
                etype="${tbl#setup:}"
                _knit_remove_row_value name "${tbl}" "${id}" name
                label="${etype}"
                [[ -n "${name}" ]] && label="${etype} (${name})"
                if [[ -n "${name}" ]]; then
                    [[ -z "${setup_root}" ]] && _knit_setup_root setup_root
                    __knit_ret3+=("${setup_root}/${name}")
                fi
                ;;
            resource)
                etype="${tbl#resource:}"
                _knit_remove_row_value name "${tbl}" "${id}" name
                label="${etype}"
                [[ -n "${name}" ]] && label="${etype} (${name})"
                if [[ -n "${name}" ]]; then
                    [[ -z "${resource_root}" ]] && _knit_resource_root resource_root
                    __knit_ret3+=("${resource_root}/${name}")
                fi
                ;;
            job)
                if [[ "${tbl}" == "${_KNIT_JOBS_TABLE}" ]]; then
                    _knit_remove_row_value name "${tbl}" "${id}" name
                    _knit_remove_row_value state "${tbl}" "${id}" state
                    label="${name}"
                    annot="state: ${state}"
                    [[ -z "${job_root}" ]] && _knit_job_root job_root
                    __knit_ret3+=("${job_root}/${id}")
                else
                    label="${tbl}"
                    annot="body row"
                fi
                ;;
            run)
                _knit_remove_row_value ename "${_KNIT_RUNS_TABLE}" "${id}" app
                label="${ename}"
                ;;
            app|command)
                label="${tbl}"
                ;;
            artifact)
                apath="${__knit_apaths["${id}"]:-}"
                label="${apath}"
                if [[ "${keep_files}" != "true" && -n "${apath}" ]]; then
                    [[ -z "${artifact_root}" ]] && _knit_artifact_root artifact_root
                    __knit_ret3+=("${artifact_root}/${apath}")
                fi
                ;;
        esac
        printf -v line '%-8s %-20s %s' "${kind}" "${label}" "${id}"
        [[ -n "${annot}" ]] && line+="  (${annot})"
        __knit_ret1+=("${line}")
    done

    # Provenance edges touching the set (an endpoint in the erase set).
    local in_list
    _knit_remove_id_in_list in_list "${ids[@]}"
    if [[ -n "${in_list}" ]]; then
        local sname sid tname tid lhs rhs eline
        while IFS='|' read -r sname sid etype tname tid; do
            lhs="${sname}"
            [[ -n "${sid}" ]] && lhs="${sname} ${sid}"
            rhs="${tname}"
            [[ -n "${tid}" ]] && rhs="${tname} ${tid}"
            printf -v eline '%s --%s--> %s' "${lhs}" "${etype}" "${rhs}"
            __knit_ret2+=("${eline}")
        done < <(_knit_sqlite3 \
            "SELECT source_name, source_id, edge_type, target_name, target_id FROM ${_KNIT_PROV_TABLE} WHERE source_id IN (${in_list}) OR target_id IN (${in_list});" \
            2>/dev/null)
    fi

    # Left on disk: plain outputs (always), sorted for stable output.
    local -a paths=()
    local p lline
    for p in "${!__knit_plain[@]}"; do paths+=("${p}"); done
    if (( ${#paths[@]} > 0 )); then
        mapfile -t paths < <(printf '%s\n' "${paths[@]}" | sort)
    fi
    for p in "${paths[@]}"; do
        printf -v lline '%s   (output of %s)' "${p}" "${__knit_plain["${p}"]}"
        __knit_ret4+=("${lline}")
    done
    # Kept artifact entries under --keep-files.
    if [[ "${keep_files}" == "true" ]]; then
        [[ -z "${artifact_root}" ]] && _knit_artifact_root artifact_root
        for id in "${ids[@]}"; do
            [[ "${__knit_kinds["${id}"]:-}" == "artifact" ]] || continue
            apath="${__knit_apaths["${id}"]:-}"
            [[ -z "${apath}" ]] && continue
            printf -v lline '%s   (artifact, --keep-files)' "${artifact_root}/${apath}"
            __knit_ret4+=("${lline}")
        done
    fi
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_print_report()
#
# Lay out the itemized report the erase set built. The header line is a parameter
# so the tense matches the mode ("The following will be permanently erased:"
# before a prompt or under --dry-run; "Erased:" after the fact under --yes). The
# data-row section is always printed (the erase set is never empty); the
# provenance-edge, removed, and "left on disk" sections are printed only when they
# have entries. Each section header carries its count.
#
# @param[in] header  The header line to print above the report.
# @param[in] __knit_rows    Name of the array of data-row lines.
# @param[in] __knit_edges   Name of the array of provenance-edge lines.
# @param[in] __knit_removed Name of the array of removed dir/entry paths.
# @param[in] __knit_left    Name of the array of "left on disk" lines.
# ------------------------------------------------------------------------------
_knit_remove_print_report() {
    local header="$1"; shift
    local -n __knit_rows=$1
    local -n __knit_edges=$2
    local -n __knit_removed=$3
    local -n __knit_left=$4
    local item
    printf '%s\n\n' "${header}"
    printf '  Data rows (%d):\n' "${#__knit_rows[@]}"
    for item in "${__knit_rows[@]}"; do printf '    %s\n' "${item}"; done
    if (( ${#__knit_edges[@]} > 0 )); then
        printf '\n  Provenance edges (%d):\n' "${#__knit_edges[@]}"
        for item in "${__knit_edges[@]}"; do printf '    %s\n' "${item}"; done
    fi
    if (( ${#__knit_removed[@]} > 0 )); then
        printf '\n  Directories and artifacts removed (%d):\n' "${#__knit_removed[@]}"
        for item in "${__knit_removed[@]}"; do printf '    %s\n' "${item}"; done
    fi
    if (( ${#__knit_left[@]} > 0 )); then
        printf '\n  Left on disk (%d):\n' "${#__knit_left[@]}"
        for item in "${__knit_left[@]}"; do printf '    %s\n' "${item}"; done
    fi
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_delete_rows()
#
# Delete the erase set from the database in one transaction: first every
# __provenance__ edge that touches the set, then the data rows table by table. The
# whole thing is a single ".bail on" BEGIN...COMMIT fed to _knit_sqlite3_write, so
# it runs under the advisory write lock and either the whole erase set goes or
# nothing does (a failing statement stops the CLI and rolls the open transaction
# back). Edges are deleted with "source_id IN (...) OR target_id IN (...)" over
# every erase-set id, which also clears a KEPT provider's used_by edge into an
# erased consumer (the edge is caught by its erased target even though its source
# stays). Data rows are grouped by table from the id -> table map so each table is
# cleared with one DELETE. Ids are escaped into the IN-lists by
# _knit_remove_id_in_list, never interpolated raw. Filesystem side effects (job,
# setup, and resource directories and artifact entries) are handled separately
# after a successful commit.
#
# @param[in] __knit_tables Name of the assoc array mapping id -> table.
# @param[in] ...           The erase-set ids.
# ------------------------------------------------------------------------------
_knit_remove_delete_rows() {
    local -n __knit_tables=$1; shift
    local -a ids=("$@")

    # Every edge touching the set is deleted from both ends by this one IN-list.
    local edge_list
    _knit_remove_id_in_list edge_list "${ids[@]}"
    [[ -z "${edge_list}" ]] && return 0

    # Group ids by table so each data table is cleared with a single DELETE.
    local -A by_table=()
    local id tbl
    for id in "${ids[@]}"; do
        [[ -z "${id}" ]] && continue
        tbl="${__knit_tables["${id}"]:-}"
        [[ -z "${tbl}" ]] && continue
        if [[ -v by_table["${tbl}"] ]]; then
            by_table["${tbl}"]+=$'\n'"${id}"
        else
            by_table["${tbl}"]="${id}"
        fi
    done

    # Assemble the statements: edges first (so a mid-transaction reader -- which
    # the write lock precludes anyway -- never sees a row without its edges), then
    # each data table.
    local prov_ident
    _knit_db_sql_ident prov_ident "${_KNIT_PROV_TABLE}"
    local sql
    printf -v sql 'DELETE FROM %s WHERE source_id IN (%s) OR target_id IN (%s);\n' \
        "${prov_ident}" "${edge_list}" "${edge_list}"

    local tblident row_list stmt
    local -a tids=()
    for tbl in "${!by_table[@]}"; do
        mapfile -t tids <<< "${by_table["${tbl}"]}"
        _knit_remove_id_in_list row_list "${tids[@]}"
        [[ -z "${row_list}" ]] && continue
        _knit_db_sql_ident tblident "${tbl}"
        printf -v stmt 'DELETE FROM %s WHERE id IN (%s);\n' "${tblident}" "${row_list}"
        sql+="${stmt}"
    done

    _knit_sqlite3_write <<EOF
.bail on
BEGIN;
${sql}COMMIT;
EOF
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_rmtree()
#
# Remove a single filesystem entry (a file, directory, or symlink) best-effort.
# An absent entry is a success (nothing to do). A symlink is removed as the link,
# never followed to its target (rm -rf never deletes a symlink's target). The
# return code reports the OUTCOME, not rm's exit status: 0 when the entry is gone
# afterward (or was never there), 1 when it still exists, so the caller can list a
# path it could not clear.
#
# @param[in] path The entry to remove.
# @return 0 if the entry is gone (or was absent); 1 if it remains.
# ------------------------------------------------------------------------------
_knit_remove_rmtree() {
    local path="$1"
    [[ -e "${path}" || -L "${path}" ]] || return 0
    rm -rf "${path}" 2>/dev/null
    [[ -e "${path}" || -L "${path}" ]] && return 1
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_rm_artifact()
#
# Remove one on-disk artifact entry at <root>/<rel> best-effort, with a
# containment guard and empty-parent pruning. An absent entry is a success. The
# entry itself is never resolved, so a --link-from artifact (a symlink under the
# artifact root) is removed as the link and a target outside the root is left
# untouched; only the entry's PARENT is resolved, and the removal is refused
# (silently, as a no-op) unless that parent stays inside the artifact root -- a
# cheap defense, since the recorded path is framework-written and always relative.
# After a successful removal, now-empty parent directories are pruned up to but not
# including the artifact root, so the root does not accumulate empty subtrees.
#
# @param[in] root The resolved artifact root.
# @param[in] rel  The artifacts-relative path recorded for the entry.
# @return 0 if the entry is gone (or was absent, or outside the root); 1 if it
#         remains.
# ------------------------------------------------------------------------------
_knit_remove_rm_artifact() {
    local root="$1" rel="$2"
    local entry="${root}/${rel}"
    [[ -e "${entry}" || -L "${entry}" ]] || return 0
    local root_real parent_real
    root_real="$(cd "${root}" 2>/dev/null && pwd -P)" || return 0
    parent_real="$(cd "$(dirname "${entry}")" 2>/dev/null && pwd -P)" || return 0
    case "${parent_real}/" in
        "${root_real}/"*) ;;   # inside the root (or the root itself)
        *) return 0 ;;         # outside: refuse as a no-op (defensive)
    esac
    rm -rf "${entry}" 2>/dev/null
    [[ -e "${entry}" || -L "${entry}" ]] && return 1
    local dir="${parent_real}"
    while [[ "${dir}" != "${root_real}" && "${dir}" == "${root_real}/"* ]]; do
        rmdir "${dir}" 2>/dev/null || break
        dir="$(dirname "${dir}")"
    done
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_instance_names()
#
# Read the instance name of every setup and resource row in the erase set into a
# caller-named associative array (id -> name), from the "name" column each such row
# records. It must run BEFORE the rows are deleted, because the filesystem phase
# needs the names to locate the instance directories (setups/<name>,
# resources/<name>) after the rows are gone, exactly as the artifact path is read
# before deletion. Ids of other kinds are skipped (a job directory is named by its
# id, an artifact by its path), as is any row whose name column is empty.
#
# @param[out] __knit_ret    Name of the assoc array to fill (id -> instance name).
# @param[in]  __knit_kinds  Name of the assoc array mapping id -> kind.
# @param[in]  __knit_tables Name of the assoc array mapping id -> table.
# @param[in]  ...           The erase-set ids.
# ------------------------------------------------------------------------------
_knit_remove_instance_names() {
    # shellcheck disable=SC2178 # nameref to the caller's associative array
    local -n __knit_ret=$1
    local -n __knit_kinds=$2
    local -n __knit_tables=$3
    shift 3
    __knit_ret=()
    local id knd tbl name
    for id in "$@"; do
        [[ -z "${id}" ]] && continue
        knd="${__knit_kinds["${id}"]:-}"
        case "${knd}" in setup|resource) ;; *) continue ;; esac
        tbl="${__knit_tables["${id}"]:-}"
        [[ -z "${tbl}" ]] && continue
        _knit_remove_row_value name "${tbl}" "${id}" name
        [[ -n "${name}" ]] && __knit_ret["${id}"]="${name}"
    done
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_filesystem()
#
# Remove the framework-managed on-disk state of the erase set, best-effort, after
# the deletion transaction has committed. For every erase-set id, by kind:
#   - job: its job directory <job-root>/<id> is removed;
#   - setup: its instance directory <setup-root>/<name> is removed ONLY when the
#     directory's .setup.id marker names this row -- so erasing an older historical
#     build never removes a newer kept build's live directory (both share the
#     instance name; only one owns the directory);
#   - resource: its instance directory <resource-root>/<name> and its sibling
#     sidecar markers (.<name>.resource.{type,source,id}) are removed under the
#     same owns-the-dir guard (the .<name>.resource.id sidecar names the row);
#   - artifact: unless keep_files is "true", its on-disk entry
#     <artifact-root>/<path> is removed (symlink-safe, containment-guarded, empty
#     parents pruned -- see _knit_remove_rm_artifact).
# A command's plain (non-artifact) file/directory outputs are NEVER removed here;
# the caller lists the surviving ones with _knit_remove_report_left. Each entry
# whose removal was ATTEMPTED but did not clear is logged and its path is appended
# to a caller-named failures array, so the caller can print a final "remove by
# hand" list and exit non-zero; a deliberately kept file (a plain output, or an
# artifact under keep_files) is not a failure. The setup/resource instance names
# come from the map _knit_remove_instance_names read before deletion, and the
# artifact paths from the map _knit_remove_map_ids read before deletion.
#
# @param[out] __knit_ret    Name of the array to append unremovable paths to.
# @param[in]  __knit_kinds  Name of the assoc array mapping id -> kind.
# @param[in]  __knit_apaths Name of the assoc array mapping artifact id -> path.
# @param[in]  __knit_names  Name of the assoc array mapping id -> instance name.
# @param[in]  keep_files    "true" to leave artifact entries on disk.
# @param[in]  ...           The erase-set ids.
# ------------------------------------------------------------------------------
_knit_remove_filesystem() {
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n __knit_ret=$1
    local -n __knit_kinds=$2
    local -n __knit_apaths=$3
    local -n __knit_names=$4
    shift 4
    local keep_files="$1"; shift
    __knit_ret=()

    # Roots resolved lazily and cached (each reads metadata).
    local job_root="" setup_root="" resource_root="" artifact_root=""
    local id knd name dir marker owner apath
    for id in "$@"; do
        [[ -z "${id}" ]] && continue
        knd="${__knit_kinds["${id}"]:-}"
        case "${knd}" in
            job)
                [[ -z "${job_root}" ]] && _knit_job_root job_root
                dir="${job_root}/${id}"
                if ! _knit_remove_rmtree "${dir}"; then
                    knit_error "remove: could not remove job directory \"${dir}\"."
                    __knit_ret+=("${dir}")
                fi
                ;;
            setup)
                name="${__knit_names["${id}"]:-}"
                [[ -z "${name}" ]] && continue
                [[ -z "${setup_root}" ]] && _knit_setup_root setup_root
                dir="${setup_root}/${name}"
                marker="${dir}/.setup.id"
                owner=""
                if [[ -f "${marker}" ]]; then
                    IFS= read -r owner < "${marker}" 2>/dev/null || owner=""
                fi
                [[ "${owner}" == "${id}" ]] || continue
                if ! _knit_remove_rmtree "${dir}"; then
                    knit_error "remove: could not remove setup directory \"${dir}\"."
                    __knit_ret+=("${dir}")
                fi
                ;;
            resource)
                name="${__knit_names["${id}"]:-}"
                [[ -z "${name}" ]] && continue
                [[ -z "${resource_root}" ]] && _knit_resource_root resource_root
                dir="${resource_root}/${name}"
                marker="${resource_root}/.${name}.resource.id"
                owner=""
                if [[ -f "${marker}" ]]; then
                    IFS= read -r owner < "${marker}" 2>/dev/null || owner=""
                fi
                [[ "${owner}" == "${id}" ]] || continue
                # Sidecar markers are siblings of the instance directory.
                rm -f "${resource_root}/.${name}.resource.type" \
                      "${resource_root}/.${name}.resource.source" \
                      "${marker}" 2>/dev/null
                if ! _knit_remove_rmtree "${dir}"; then
                    knit_error "remove: could not remove resource directory \"${dir}\"."
                    __knit_ret+=("${dir}")
                fi
                ;;
            artifact)
                [[ "${keep_files}" == "true" ]] && continue
                apath="${__knit_apaths["${id}"]:-}"
                [[ -z "${apath}" ]] && continue
                [[ -z "${artifact_root}" ]] && _knit_artifact_root artifact_root
                if ! _knit_remove_rm_artifact "${artifact_root}" "${apath}"; then
                    knit_error "remove: could not remove artifact entry \"${artifact_root}/${apath}\"."
                    __knit_ret+=("${artifact_root}/${apath}")
                fi
                ;;
        esac
    done
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_report_left()
#
# Print the "NOT removed" report after an actual removal: the files and directories
# remove deliberately left in place that STILL EXIST. Two sources, in order:
#   - every plain (non-artifact) file/directory output remove never deletes,
#     attributed to its owning command as "(output of <command>)". A plain output
#     that lived inside a removed job directory is already gone and is not listed.
#   - under keep_files, every kept artifact entry <artifact-root>/<path>, marked
#     "(artifact, --keep-files)".
# Only entries that still exist are listed, so this is a truthful record of what
# survived. When nothing survived, nothing is printed. This report is informational
# and does not itself set the exit code; a removal that FAILED (as opposed to a
# deliberately kept file) is handled separately by the caller from the failures
# _knit_remove_filesystem collects.
#
# @param[in] __knit_kinds  Name of the assoc array mapping id -> kind.
# @param[in] __knit_apaths Name of the assoc array mapping artifact id -> path.
# @param[in] __knit_plain  Name of the assoc array mapping plain output path -> command.
# @param[in] keep_files    "true" if artifact entries were kept on disk.
# @param[in] ...           The erase-set ids.
# ------------------------------------------------------------------------------
_knit_remove_report_left() {
    local -n __knit_kinds=$1
    local -n __knit_apaths=$2
    local -n __knit_plain=$3
    shift 3
    local keep_files="$1"; shift
    local -a lines=()
    local line

    # Plain outputs (always kept) that still exist, sorted for stable output.
    local -a paths=()
    local p
    for p in "${!__knit_plain[@]}"; do paths+=("${p}"); done
    if (( ${#paths[@]} > 0 )); then
        mapfile -t paths < <(printf '%s\n' "${paths[@]}" | sort)
    fi
    for p in "${paths[@]}"; do
        [[ -e "${p}" || -L "${p}" ]] || continue
        printf -v line '%s   (output of %s)' "${p}" "${__knit_plain["${p}"]}"
        lines+=("${line}")
    done

    # Kept artifact entries under --keep-files that still exist.
    if [[ "${keep_files}" == "true" ]]; then
        local artifact_root="" id apath entry
        for id in "$@"; do
            [[ "${__knit_kinds["${id}"]:-}" == "artifact" ]] || continue
            apath="${__knit_apaths["${id}"]:-}"
            [[ -z "${apath}" ]] && continue
            [[ -z "${artifact_root}" ]] && _knit_artifact_root artifact_root
            entry="${artifact_root}/${apath}"
            [[ -e "${entry}" || -L "${entry}" ]] || continue
            printf -v line '%s   (artifact, --keep-files)' "${entry}"
            lines+=("${line}")
        done
    fi

    (( ${#lines[@]} == 0 )) && return 0
    printf 'The following files/directories were NOT removed:\n'
    for line in "${lines[@]}"; do printf '  %s\n' "${line}"; done
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_remove_dispatch()
#
# Shared body for every remove subcommand: enforce the exactly-one-selector
# contract, resolve the selection to its starting ids, compute the erase set, map
# each id to its table and kind, and refuse the operation if it would erase a
# non-terminal job. Which closure is computed depends on --from-root: without it,
# the default downward closure is taken and the callee/artifact refusal check runs
# (fatal before anything is printed or deleted); with it, the whole-lineage
# connected-component closure is taken and the refusal check is skipped by design.
# Under --dry-run the itemized report is built and printed and the command stops
# (no prompt, no deletion); under --yes the report is printed, the erase set is
# deleted from the database (edges and rows, in one transaction), the
# framework-managed on-disk state is removed best-effort (job/setup/resource
# directories and, unless --keep-files, artifact entries), and the files left on
# disk are reported; the command exits non-zero if any attempted removal could not
# be cleared. With neither flag the resulting erase set is printed (the
# confirmation prompt is added in a later milestone). --dry-run wins if both flags
# are given. The selector names are given as leading arguments up to a literal
# "--", after which come the command invocation arguments.
#
# @param[in] kind The entity kind of the subcommand.
# @param[in] ... The selector names, then "--", then the invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_dispatch() {
    local kind="$1"; shift
    local -a selectors=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        selectors+=("$1"); shift
    done
    shift  # drop the "--"
    _knit_remove_require_one_selector "${selectors[@]}" -- "$@"
    local -a starting=()
    _knit_remove_resolve_selection starting "${kind}" "$@"
    local from_root
    from_root="$(knit_get_parameter "from-root" "$@")" || from_root="false"
    local -a erase=()
    if [[ "${from_root}" == "true" ]]; then
        _knit_remove_closure_from_root erase "${starting[@]}"
    else
        _knit_remove_closure_downward erase "${starting[@]}"
        _knit_remove_check_refusal starting erase
    fi
    # These maps are written by _knit_remove_map_ids and read back by name (art_type
    # is captured for completeness but not consumed: the filesystem step removes
    # files, directories, and symlinks alike with one rm -rf); shellcheck cannot see
    # the by-name reads.
    # shellcheck disable=SC2034
    local -A id_table=() id_kind=() art_path=() art_type=()
    _knit_remove_map_ids id_table id_kind art_path art_type "${erase[@]}"
    _knit_remove_check_terminal_jobs id_table "${erase[@]}"

    local keep_files dry_run yes
    keep_files="$(knit_get_parameter "keep-files" "$@")" || keep_files="false"
    dry_run="$(knit_get_parameter "dry-run" "$@")"       || dry_run="false"
    yes="$(knit_get_parameter "yes" "$@")"               || yes="false"

    if [[ "${dry_run}" == "true" || "${yes}" == "true" ]]; then
        # shellcheck disable=SC2034 # filled by name for _knit_remove_build_report
        local -A plain_out=()
        _knit_remove_plain_outputs plain_out id_table "${erase[@]}"
        # shellcheck disable=SC2034 # filled by name by _knit_remove_build_report
        local -a rep_rows=() rep_edges=() rep_removed=() rep_left=()
        _knit_remove_build_report \
            rep_rows rep_edges rep_removed rep_left \
            id_table id_kind art_path plain_out \
            "${keep_files}" "${erase[@]}"
        # --dry-run wins if both are given: report and stop, never delete.
        if [[ "${dry_run}" == "true" ]]; then
            _knit_remove_print_report \
                "The following will be permanently erased:" \
                rep_rows rep_edges rep_removed rep_left
            return 0
        fi
        # Capture setup/resource instance names before the rows go; the filesystem
        # phase needs them to locate the instance directories after deletion.
        # shellcheck disable=SC2034 # filled by name for _knit_remove_filesystem
        local -A inst_name=()
        _knit_remove_instance_names inst_name id_kind id_table "${erase[@]}"
        _knit_remove_print_report \
            "Erased:" \
            rep_rows rep_edges rep_removed rep_left
        _knit_remove_delete_rows id_table "${erase[@]}"
        # Filesystem side effects run after a successful commit, best-effort.
        local -a fs_failures=()
        _knit_remove_filesystem fs_failures id_kind art_path inst_name \
            "${keep_files}" "${erase[@]}"
        _knit_remove_report_left id_kind art_path plain_out \
            "${keep_files}" "${erase[@]}"
        if (( ${#fs_failures[@]} > 0 )); then
            printf 'The following could not be removed and must be deleted by hand:\n' >&2
            local f
            for f in "${fs_failures[@]}"; do printf '  %s\n' "${f}" >&2; done
            return 1
        fi
        return 0
    fi

    printf '%s\n' "${erase[@]}"
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
# Body of 'remove setup': resolve the selection, close it downward, run the
# refusal check, and print the erase set. The deletion machinery is added in
# later milestones.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_setup() {
    _knit_remove_dispatch "setup" id name type -- "$@"
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
# Body of 'remove resource': resolve the selection, close it downward, run the
# refusal check, and print the erase set. The deletion machinery is added in
# later milestones.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_resource() {
    _knit_remove_dispatch "resource" id name type -- "$@"
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
# Body of 'remove job': resolve the selection, close it downward, run the refusal
# check, and print the erase set. The setup and resource the job used are not
# followed (their used_by edges point INTO the job). The deletion machinery is
# added in later milestones.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_job() {
    _knit_remove_dispatch "job" id name type group -- "$@"
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
# Body of 'remove run': resolve the selection, close it downward, run the refusal
# check, and print the erase set. Selecting a run whose enclosing job is kept is
# refused (the job's call edge would dangle). The deletion machinery is added in
# later milestones.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_run() {
    _knit_remove_dispatch "run" id name -- "$@"
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
# Body of 'remove app': resolve the selection, close it downward, run the refusal
# check, and print the erase set. Selecting an app whose enclosing run/job is kept
# is refused. The deletion machinery is added in later milestones.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_app() {
    _knit_remove_dispatch "app" id name -- "$@"
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
# Body of 'remove command': resolve the selection, close it downward, run the
# refusal check, and print the erase set. The deletion machinery is added in later
# milestones.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_command() {
    _knit_remove_dispatch "command" id name -- "$@"
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
# Body of 'remove artifact': resolve the selection, close it downward, run the
# refusal check, and print the erase set. Naming an artifact on its own is refused
# (its producer is kept); it is meaningful only with --from-root (added later).
# The deletion machinery is added in later milestones.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_remove_artifact() {
    _knit_remove_dispatch "artifact" id path -- "$@"
}
knit_done
