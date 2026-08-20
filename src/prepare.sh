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
    _knit_sqlite3_write \
        "UPDATE ${jobs_ident} SET state='submitting'
          WHERE ${id_ident} = (SELECT ${id_ident} FROM ${jobs_ident}
                               WHERE ${where}
                               ORDER BY ${id_ident} ASC LIMIT 1)
            AND state='prepared'
          RETURNING ${id_ident};"
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
    _knit_sqlite3_write \
        "UPDATE ${jobs_ident} SET state='submitting'
          WHERE ${id_ident}='${esc}' AND state='prepared'
          RETURNING ${id_ident};"
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
