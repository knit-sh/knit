#!/bin/bash

## @file prepare.sh
##
## The `prepare` dispatcher: build and record a job without dispatching it to the
## scheduler. A prepared job gets a "jobs" row with state "prepared" and stays
## queued until released by `submit prepared` / `submit next`. `prepare` mirrors
## `submit` argument-for-argument (minus --wait) over the same _KNIT_JOBS
## registry, so you prepare the same jobs you submit: `prepare -- <job>` builds
## the job through _knit_prepare_build exactly as `submit` does, but stops before
## the dispatch phase.
##
## `prepare` declares neither a table nor outputs of its own: _knit_prepare_build
## records the "jobs" row under the "submit" command identity (see job.sh), so a
## prepared job and a directly-submitted job produce identically-shaped,
## identically-labeled rows and provenance edges. The prepare dispatcher is
## therefore transparent to the graph (knit_without_provenance).

knit_register "prepare" _knit_prepare "Prepare a job without submitting it."
_knit_is_builtin
# The job's "jobs" row is recorded under the "submit" identity, so the prepare
# dispatcher itself contributes no provenance node of its own.
knit_without_provenance
_knit_declare_submit_options

# ------------------------------------------------------------------------------
# @fn _knit_prepare()
#
# Entry point for the `prepare` CLI command. Builds a submission and records it
# with state "prepared" without contacting the scheduler (see
# _knit_prepare_build): the batch script and the frozen .submit metadata are
# written, but no scheduler command is issued and no .job.id is recorded. The job
# stays queued until released by `submit prepared` or `submit next`. Prints the
# job UUID (the canonical, scheduler-independent identifier).
#
# Usage:
# ```
# ./exp.sh prepare [--setup <setup-name>] [--name <alias>] [--group <name>] \
#     [sched-args...] -- job-name [args...]
# ```
# ------------------------------------------------------------------------------
_knit_prepare() {
    # The output variable names must not clash with _knit_prepare_build's own
    # internal locals (uuid/jobdir/alias_link/job_name), or the nameref outputs
    # would be shadowed (see the nameref-shadow-collision convention).
    # shellcheck disable=SC2034 # out_jobdir/out_alias/out_jobname are nameref
    # outputs of _knit_prepare_build; prepare only needs the uuid it returns.
    local out_uuid out_jobdir out_alias out_jobname
    _knit_prepare_build out_uuid out_jobdir out_alias out_jobname \
        "prepared" "$@"
    printf '%s\n' "${out_uuid}"
}
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_prepare_claim_next()
#
# Atomically claim the oldest prepared job matching optional filters, moving it
# from state "prepared" to the transient "submitting" so no concurrent releaser
# can grab the same row. The whole pick-and-mark is one conditional UPDATE under
# the write lock (see _knit_sqlite3_write): the inner SELECT picks the lowest id
# in state "prepared" (job UUIDs are time-ordered uuidv7, so lowest id is oldest
# prepared), and the outer guard re-checks the state so a row another releaser
# claimed first is not taken twice. Job UUIDs order by prepare time, so this
# releases in prepare order. Prints the claimed UUID, or nothing when no prepared
# job matches (queue drained, or the race was lost).
#
# @param job   Optional job-name filter (the "job" column); empty means any.
# @param group Optional group filter (the "group" column); empty means any.
# ------------------------------------------------------------------------------
_knit_prepare_claim_next() {
    local job="$1" group="$2"

    local -a conds=("state='prepared'")
    local esc
    if [[ -n "${job}" ]]; then
        _knit_sql_escape esc "${job}"
        conds+=("job='${esc}'")
    fi
    if [[ -n "${group}" ]]; then
        _knit_sql_escape esc "${group}"
        local group_ident
        _knit_db_sql_ident group_ident "group"
        conds+=("${group_ident}='${esc}'")
    fi
    local where
    printf -v where '%s AND ' "${conds[@]}"
    where="${where% AND }"

    local jobs_ident id_ident
    _knit_db_sql_ident jobs_ident "${_KNIT_JOBS_TABLE}"
    _knit_db_sql_ident id_ident "id"
    # The write lock (see _knit_sqlite3_write) already makes the whole
    # pick-and-mark atomic, so no releaser can interleave between the pick and
    # the UPDATE. A connection-scoped TEMP table holds the picked id, the UPDATE
    # claims exactly that row, and the trailing SELECT reports it. This avoids
    # UPDATE ... RETURNING, which needs sqlite >= 3.35 (a knit-symlinked system
    # sqlite may be older). The TEMP table already filtered on state='prepared',
    # so it is the claim guard; it is dropped when the connection closes.
    _knit_sqlite3_write \
        "CREATE TEMP TABLE _knit_claim AS
           SELECT ${id_ident} FROM ${jobs_ident}
             WHERE ${where}
             ORDER BY ${id_ident} ASC LIMIT 1;
         UPDATE ${jobs_ident} SET state='submitting'
           WHERE ${id_ident} IN (SELECT ${id_ident} FROM _knit_claim);
         SELECT ${id_ident} FROM _knit_claim;"
}

# ------------------------------------------------------------------------------
# @fn _knit_prepare_claim_id()
#
# Atomically claim one prepared job by its UUID, moving it from state "prepared"
# to the transient "submitting". Like _knit_prepare_claim_next but keyed on an
# explicit id: a single conditional UPDATE under the write lock whose guard
# ("AND state='prepared'") both prevents a double claim and yields nothing when
# the row is no longer prepared. Prints the claimed UUID, or nothing when the row
# is absent or not in state "prepared".
#
# @param uuid The job UUID to claim.
# ------------------------------------------------------------------------------
_knit_prepare_claim_id() {
    local uuid="$1"
    local esc
    _knit_sql_escape esc "${uuid}"
    local jobs_ident id_ident
    _knit_db_sql_ident jobs_ident "${_KNIT_JOBS_TABLE}"
    _knit_db_sql_ident id_ident "id"
    # Same TEMP-table claim as _knit_prepare_claim_next, keyed on an explicit id
    # (avoids UPDATE ... RETURNING, which needs sqlite >= 3.35). The TEMP table
    # is empty when the row is absent or no longer prepared, so the UPDATE claims
    # nothing and the trailing SELECT prints nothing. See that function's note.
    _knit_sqlite3_write \
        "CREATE TEMP TABLE _knit_claim AS
           SELECT ${id_ident} FROM ${jobs_ident}
             WHERE ${id_ident}='${esc}' AND state='prepared';
         UPDATE ${jobs_ident} SET state='submitting'
           WHERE ${id_ident} IN (SELECT ${id_ident} FROM _knit_claim);
         SELECT ${id_ident} FROM _knit_claim;"
}

# ------------------------------------------------------------------------------
# @fn _knit_prepare_release()
#
# Release a claimed prepared job (already moved to state "submitting" by one of
# the claim helpers) to the scheduler. The submission spec was frozen at prepare
# time, so this reconstructs the job name and any --name alias from the jobs row,
# then hands off to _knit_submit_dispatch, which builds the submit command,
# advances the row "submitting" -> "submitted", and issues it (cleaning up on a
# scheduler rejection exactly as a direct submit does). Prints the released job's
# UUID.
#
# @param uuid      The claimed job UUID.
# @param wait_flag "true"/"false": block until the job completes (see
#                  _knit_submit_dispatch's wait override).
# ------------------------------------------------------------------------------
_knit_prepare_release() {
    local uuid="$1" wait_flag="$2"
    local esc
    _knit_sql_escape esc "${uuid}"

    local job_name alias_name
    job_name="$(_knit_sqlite3 \
        "SELECT job FROM ${_KNIT_JOBS_TABLE} WHERE id='${esc}';")"
    alias_name="$(_knit_sqlite3 \
        "SELECT name FROM ${_KNIT_JOBS_TABLE} WHERE id='${esc}';")"

    local jobdir alias_link=""
    jobdir="$(_knit_job_dir "${uuid}")"
    if [[ -n "${alias_name}" ]]; then
        local job_root
        _knit_job_root job_root
        alias_link="${job_root}/${alias_name}"
    fi

    _knit_submit_dispatch "${uuid}" "${jobdir}" "${job_name}" "${alias_link}" \
        "${wait_flag}"
    printf '%s\n' "${uuid}"
}

# ------------------------------------------------------------------------------
# @fn _knit_prepare_remove()
#
# Remove a prepared job that was never dispatched: delete its jobs row, its job
# directory, and any --name alias. A prepared job has contacted no scheduler, so
# there is nothing to cancel; the teardown is exactly the rejection cleanup a
# failed submit performs (_knit_submit_cleanup_rejected), reached here by the
# "prepared" branch of `job cancel`. The --name alias is reconstructed from the
# row's "name" column, as _knit_prepare_release reconstructs it on dispatch.
#
# @param uuid The prepared job UUID.
# ------------------------------------------------------------------------------
_knit_prepare_remove() {
    local uuid="$1"
    local esc
    _knit_sql_escape esc "${uuid}"

    local alias_name
    alias_name="$(_knit_sqlite3 \
        "SELECT name FROM ${_KNIT_JOBS_TABLE} WHERE id='${esc}';")"

    local jobdir alias_link=""
    jobdir="$(_knit_job_dir "${uuid}")"
    if [[ -n "${alias_name}" ]]; then
        local job_root
        _knit_job_root job_root
        alias_link="${job_root}/${alias_name}"
    fi

    _knit_submit_cleanup_rejected "${uuid}" "${jobdir}" "${alias_link}"
}

# ------------------------------------------------------------------------------
# Release a prepared job to the scheduler by its UUID.
# ------------------------------------------------------------------------------
knit_register "submit:prepared" _knit_submit_prepared \
    "Release a prepared job to the scheduler by id."
_knit_is_builtin
# The release contributes no data row and no provenance node of its own: it
# advances an existing "jobs" row (recorded at prepare time under the "submit"
# identity) rather than recording a new invocation.
knit_without_provenance
knit_with_optional "id:string" "" "UUID of the prepared job to release."
knit_with_flag "wait" "Block until the released job completes; return its exit code."
# ------------------------------------------------------------------------------
# @fn _knit_submit_prepared()
#
# Release one prepared job, named by --id, to the scheduler. The row must exist
# and be in state "prepared": an unknown id and a non-prepared row are distinct
# fatal errors, so a typo or a double release is reported rather than silently
# doing nothing. The claim is atomic (_knit_prepare_claim_id), so two releasers
# racing on the same id never both dispatch it. Prints the released job's UUID.
#
# To inspect prepared jobs before releasing, use `job list --status prepared`.
# ------------------------------------------------------------------------------
_knit_submit_prepared() {
    local id wait_flag
    id=$(knit_get_parameter "id" "$@")
    wait_flag=$(knit_get_parameter "wait" "$@") || wait_flag="false"

    if [[ -z "${id}" ]]; then
        knit_fatal "submit prepared requires --id <uuid>."
    fi

    # Distinguish "unknown id" from "not prepared" with a read before the claim;
    # the atomic claim below still guards against a concurrent release.
    local esc state
    _knit_sql_escape esc "${id}"
    state="$(_knit_sqlite3 \
        "SELECT state FROM ${_KNIT_JOBS_TABLE} WHERE id='${esc}';")"
    if [[ -z "${state}" ]]; then
        knit_fatal "No job found with id \"${id}\"."
    fi
    if [[ "${state}" != "prepared" ]]; then
        knit_fatal "Job \"%s\" is not prepared (state \"%s\"); only a prepared job can be released." \
            "${id}" "${state}"
    fi

    local claimed
    claimed="$(_knit_prepare_claim_id "${id}")"
    if [[ -z "${claimed}" ]]; then
        knit_fatal "Job \"%s\" is no longer prepared (it was released concurrently)." \
            "${id}"
    fi
    _knit_prepare_release "${claimed}" "${wait_flag}"
}
knit_done

# ------------------------------------------------------------------------------
# Release the next prepared job in line to the scheduler.
# ------------------------------------------------------------------------------
knit_register "submit:next" _knit_submit_next \
    "Release the next prepared job (oldest first), optionally filtered."
_knit_is_builtin
# Like `submit prepared`, a release records no row and no provenance node.
knit_without_provenance
knit_with_optional "type:string" "" "Only release a job of this type (the job name)."
knit_with_optional "group:string" "" "Only release a job in this group."
knit_with_flag "wait" "Block until the released job completes; return its exit code."
# ------------------------------------------------------------------------------
# @fn _knit_submit_next()
#
# Release the oldest prepared job to the scheduler, optionally restricted to a
# job type (--type) and/or group (--group). Jobs release in prepare order (see
# _knit_prepare_claim_next). When no prepared job matches, this reports it and
# returns non-zero so a fill-the-queue loop can stop. Prints the released job's
# UUID on success.
# ------------------------------------------------------------------------------
_knit_submit_next() {
    local type group wait_flag
    type=$(knit_get_parameter "type" "$@") || type=""
    group=$(knit_get_parameter "group" "$@") || group=""
    wait_flag=$(knit_get_parameter "wait" "$@") || wait_flag="false"

    local claimed
    claimed="$(_knit_prepare_claim_next "${type}" "${group}")"
    if [[ -z "${claimed}" ]]; then
        knit_info "No prepared job to release."
        return 1
    fi
    _knit_prepare_release "${claimed}" "${wait_flag}"
}
knit_done

# ------------------------------------------------------------------------------
# Prepare many jobs at once from a JSON plan.
# ------------------------------------------------------------------------------
knit_register "prepare:from" _knit_prepare_from \
    "Prepare many jobs from a JSON plan (file or stdin)."
_knit_is_builtin
# Each prepared job is recorded by _knit_prepare_build under the "submit"
# identity, so `prepare from` itself owns no table and adds no provenance node.
knit_without_provenance
knit_with_optional "file:string" "" \
    "Path to the JSON plan (default: read the plan from stdin)."
knit_with_optional "group:string" "" \
    "Override the plan's top-level group for every prepared job."
# ------------------------------------------------------------------------------
# @fn _knit_prepare_from()
#
# Entry point for the `prepare from` CLI command. Reads a JSON plan (from --file,
# or from stdin when --file is omitted) and prepares each job it describes, as if
# each had been passed to `prepare … -- <job> …` individually. Reading from an
# interactive terminal (nothing to read) or reading an empty plan is fatal rather
# than a silent hang, mirroring the no-argument form of knit_with_spack_env. The
# whole plan is validated before any job is prepared, so a bad plan leaves nothing
# half-prepared. Prints one prepared job UUID per line, in plan order.
#
# Usage:
# ```
# ./exp.sh prepare from [--file <plan.json>] [--group <name>]
# ./exp.sh prepare from < plan.json
# ```
# ------------------------------------------------------------------------------
_knit_prepare_from() {
    local file group_override
    file=$(knit_get_parameter "file" "$@") || file=""
    group_override=$(knit_get_parameter "group" "$@") || group_override=""

    local plan
    if [[ -n "${file}" ]]; then
        if [[ ! -f "${file}" ]]; then
            knit_fatal "prepare from: plan file \"${file}\" not found."
        fi
        plan="$(cat "${file}")"
    else
        # No --file: the plan must arrive on stdin (here-doc, here-string, or
        # pipe). An interactive terminal has nothing to read, so "cat" would block
        # forever; fail fast with guidance instead (see _knit_stdin_is_terminal).
        if _knit_stdin_is_terminal; then
            knit_fatal "prepare from: no plan provided. Give a plan with --file <plan.json> or feed one on stdin (here-doc/here-string/pipe)."
        fi
        plan="$(cat)"
    fi
    if [[ -z "${plan//[[:space:]]/}" ]]; then
        knit_fatal "prepare from: the plan is empty."
    fi

    _knit_prepare_from_file "${plan}" "${group_override}"
}
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_prepare_matrix_expand()
#
# Expand every matrix block in a plan's "jobs" list into concrete entries, in
# place, and print the rewritten plan. A jobs element is either a concrete entry
# (kept as-is) or a `{ "matrix": {…} }` block; a block expands to one entry per
# combination so the later render pass resolves each combination by the same
# field rules as a hand-written entry.
#
# A matrix block is a field map with three reserved keys and any number of fixed
# fields:
#   - "axes"    — a map from field name to a list of values; the block expands to
#                 the cartesian product of the axes (first axis varies slowest).
#   - "exclude" — a list of field maps; drop every combination that matches all
#                 fields of any exclude entry.
#   - "include" — a list of field maps; append each, merged over the block's
#                 fixed fields, as a new standalone combination (after exclude).
# Every other key on the block (e.g. "job", a fixed "setup") is carried into
# every combination. Combinations keep product order, then the appended
# includes; blocks and concrete entries interleave in plan order.
#
# To vary a job argument, use an "args" axis whose values are arg objects/arrays
# (e.g. `"args": [ {"colormap":"fire"}, {"colormap":"ice"} ]`): a top-level
# non-reserved field is a submission argument, exactly as for a concrete entry.
#
# A structural problem (a non-object matrix, a non-object "axes", an axis that is
# not a list, a non-array "exclude"/"include") raises a jq error naming the
# offending entry, so the whole expansion fails and nothing is prepared.
#
# @param plan The plan JSON text (already checked to be an object with a "jobs"
#             array).
# ------------------------------------------------------------------------------
_knit_prepare_matrix_expand() {
    local plan="$1"
    local prog
    # shellcheck disable=SC2016 # $-expressions below are jq syntax, not shell.
    prog='
def axis_combos($axes):
  reduce ($axes|to_entries)[] as $e ([{}];
    [ .[] as $acc | $e.value[] as $v | $acc + {($e.key): $v} ]);
def expand_matrix($i; $block):
  (if ($block|type) != "object"
     then error("plan entry \($i): \"matrix\" must be an object") else . end)
  | ($block.axes // {}) as $axes
  | (if ($axes|type) != "object"
       then error("plan entry \($i): matrix \"axes\" must be an object")
     else . end)
  | (if ($axes|to_entries|all(.value|type=="array")) then .
     else error("plan entry \($i): every matrix axis must be a list of values")
     end)
  | ($block.exclude // []) as $exclude
  | (if ($exclude|type) != "array"
       then error("plan entry \($i): matrix \"exclude\" must be an array")
     else . end)
  | ($block.include // []) as $include
  | (if ($include|type) != "array"
       then error("plan entry \($i): matrix \"include\" must be an array")
     else . end)
  | ($block | del(.axes, .exclude, .include)) as $fixed
  | (axis_combos($axes) | map($fixed + .)) as $base
  | ($base | map(. as $c
      | select( any($exclude[]; . as $x
                    | all(($x|keys_unsorted[]); . as $k | $c[$k] == $x[$k]) )
                | not ))) as $kept
  | ($kept + ($include | map($fixed + .)));
.jobs |= ( [ range(0; length) as $i | (.[$i]) as $e
             | if ($e|type)=="object" and ($e|has("matrix"))
               then expand_matrix($i; $e.matrix)
               else [$e] end ]
           | add // [] )
'
    printf '%s' "${plan}" | _knit_jq -c "${prog}"
}

# ------------------------------------------------------------------------------
# @fn _knit_prepare_from_file()
#
# Parse and fully validate a JSON plan, then prepare each job it describes in
# plan order. The plan is a JSON object with an optional top-level "group", an
# optional "defaults" field map merged under every entry, and a required "jobs"
# list of concrete entries. Every entry is resolved to a `prepare` argument list
# and validated before anything is prepared, so a malformed plan leaves no job
# half-prepared. Prints one prepared job UUID per line.
#
# Per-entry field resolution (an explicit field on the entry wins over defaults):
#   - "job"   (required) — the registered job name (the token after --).
#   - "args"  — the job's own arguments, either an object ({k:v} -> --k v, a
#               boolean true -> a bare flag, false -> omitted) or an array of
#               raw tokens passed through verbatim.
#   - "extra" — an array of raw tokens appended after "args".
#   - any other key — a submission argument (--key value). An unknown key (not a
#               `prepare`/`submit` option) is fatal, naming the key.
#
# The group of each entry is, in decreasing precedence: a "group" on the entry
# (or in "defaults"), the command-line --group override, the plan's top-level
# "group".
#
# @param plan           The plan JSON text.
# @param group_override Command-line --group value ("" when not given).
# ------------------------------------------------------------------------------
_knit_prepare_from_file() {
    local plan="$1"
    local group_override="$2"

    # Reject a plan that is not valid JSON up front, so later jq passes can assume
    # a parseable document.
    if ! printf '%s' "${plan}" | _knit_jq -e . >/dev/null 2>&1; then
        knit_fatal "prepare from: the plan is not valid JSON."
    fi
    # The plan must be an object with a "jobs" array; "defaults"/"group", when
    # present, must be an object/string. These give clearer messages than a jq
    # type error deep in rendering.
    if ! printf '%s' "${plan}" | _knit_jq -e 'type=="object"' >/dev/null 2>&1; then
        knit_fatal "prepare from: the plan must be a JSON object."
    fi
    if ! printf '%s' "${plan}" | _knit_jq -e '.jobs|type=="array"' >/dev/null 2>&1; then
        knit_fatal "prepare from: the plan must have a \"jobs\" array."
    fi
    if ! printf '%s' "${plan}" \
        | _knit_jq -e '(.defaults==null) or (.defaults|type=="object")' \
            >/dev/null 2>&1; then
        knit_fatal "prepare from: \"defaults\" must be an object."
    fi
    if ! printf '%s' "${plan}" \
        | _knit_jq -e '(.group==null) or (.group|type=="string")' \
            >/dev/null 2>&1; then
        knit_fatal "prepare from: \"group\" must be a string."
    fi

    # Expand any matrix blocks into concrete entries before rendering, so a matrix
    # combination is resolved by the same field rules as a hand-written entry. A
    # structural problem in a matrix block raises a jq error, surfaced verbatim,
    # so a bad plan prepares nothing.
    local expanded
    if ! expanded="$(_knit_prepare_matrix_expand "${plan}" 2>&1)"; then
        knit_fatal "prepare from: invalid plan: ${expanded}"
    fi
    plan="${expanded}"

    # The top-level group applied to entries that set no group of their own: the
    # command-line --group overrides the plan's top-level "group".
    local top_group
    if [[ -n "${group_override}" ]]; then
        top_group="${group_override}"
    else
        top_group="$(printf '%s' "${plan}" | _knit_jq -r '.group // ""')"
    fi

    # Render every entry to a compact JSON object { job, subkeys, tokens }:
    #   tokens  — the full `prepare` argument list ([sub-args] -- job [job args]),
    #   subkeys — the submission-argument key names (validated below),
    #   job     — the resolved job name.
    # A structural problem (non-object entry, missing/non-string "job", a bad
    # "args"/"extra" type) raises a jq error naming the offending entry, so the
    # whole render fails and nothing is prepared.
    local prog
    # shellcheck disable=SC2016 # $-expressions below are jq syntax, not shell.
    prog='
def render_value($k; $v):
  if $v == true then ["--\($k)"]
  elif $v == false then []
  else ["--\($k)", ($v|tostring)] end;
. as $plan
| ($plan.defaults // {}) as $defaults
| ($plan.jobs) as $jobs
| range(0; ($jobs|length)) as $i
| ($jobs[$i]) as $raw
| (if ($raw|type) != "object"
     then error("plan entry \($i) is not an object") else null end)
| ($defaults + $raw) as $m0
| (if ($m0|has("group")|not) and ($top_group != "")
     then $m0 + {group: $top_group} else $m0 end) as $m
| (if ($m|has("job")|not)
     then error("plan entry \($i): missing required \"job\"")
   elif (($m.job)|type) != "string"
     then error("plan entry \($i): \"job\" must be a string")
   else null end)
| (($m.args) // null) as $args
| (if ($args != null) and (($args|type) != "object") and (($args|type) != "array")
     then error("plan entry \($i): \"args\" must be an object or array")
   else null end)
| (($m.extra) // null) as $extra
| (if ($extra != null) and (($extra|type) != "array")
     then error("plan entry \($i): \"extra\" must be an array")
   else null end)
| ($m | to_entries
       | map(select((.key=="job" or .key=="args" or .key=="extra")|not))) as $subs
| ($subs | map(render_value(.key; .value)) | add // []) as $subtokens
| (if $args == null then []
   elif ($args|type)=="array" then ($args | map(tostring))
   else ($args | to_entries | map(render_value(.key; .value)) | add // []) end
  ) as $argtokens
| (if $extra == null then [] else ($extra | map(tostring)) end) as $extratokens
| { job: $m.job,
    subkeys: ($subs | map(.key)),
    tokens: ($subtokens + ["--", $m.job] + $argtokens + $extratokens) }
'
    local rendered
    if ! rendered="$(printf '%s' "${plan}" \
        | _knit_jq -c --arg top_group "${top_group}" "${prog}" 2>&1)"; then
        # jq's message (from error(), or a type error) is the most specific
        # explanation available; surface it verbatim after our own prefix.
        knit_fatal "prepare from: invalid plan: ${rendered}"
    fi

    # Nothing to do: an empty "jobs" list prepares no job.
    if [[ -z "${rendered}" ]]; then
        return 0
    fi

    # Validate before preparing (part 1): every submission-argument key must name
    # a known `prepare` option, and every "job" must be registered. A single
    # failure aborts before any _knit_prepare_build, so a bad plan prepares
    # nothing.
    local key norm
    while IFS= read -r key; do
        [[ -z "${key}" ]] && continue
        norm=$(_knit_name_normalize "${key}")
        if ! _knit_set_find _KNIT_CMD_prepare_optional "${norm}"; then
            knit_fatal "prepare from: unknown key \"${key}\" in plan (not a \"prepare\"/\"submit\" option)."
        fi
    done < <(printf '%s' "${rendered}" | _knit_jq -r '.subkeys[]')

    local job
    while IFS= read -r job; do
        [[ -z "${job}" ]] && continue
        if [[ ! -v _KNIT_JOBS["${job}"] ]]; then
            knit_fatal "prepare from: unknown job \"${job}\" in plan."
        fi
    done < <(printf '%s' "${rendered}" | _knit_jq -r '.job')

    # Validated: prepare each entry in plan order.
    local line
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        local -a toks=()
        mapfile -t toks < <(printf '%s' "${line}" | _knit_jq -r '.tokens[]')
        # Output variable names must not clash with _knit_prepare_build's internal
        # locals (uuid/jobdir/alias_link/job_name); see nameref-shadow-collision.
        # shellcheck disable=SC2034 # out_jobdir/out_alias/out_jobname are nameref
        # outputs of _knit_prepare_build; only the uuid is printed here.
        local out_uuid out_jobdir out_alias out_jobname
        _knit_prepare_build out_uuid out_jobdir out_alias out_jobname \
            "prepared" "${toks[@]}"
        printf '%s\n' "${out_uuid}"
    done <<< "${rendered}"
}
