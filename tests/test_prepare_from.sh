#!/usr/bin/env bats

# Unit tests for `prepare from` (src/prepare.sh): prepare many jobs from a JSON
# plan read from --file or stdin. Covers the concrete-entry plan (field
# resolution, defaults, group precedence, plan order, validate-before-prepare)
# and matrix expansion (cartesian product, exclude, include, ordering).

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq

    knit_test_db_setup

    _KNIT_JQ_EXE="jq"
    _KNIT_TEST_TMPDIR="$(mktemp -d)"

    # Pin the experiment root so a --setup name resolves deterministically and
    # jobs land under <experiment-root>/jobs.
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/.knit"
    mkdir -p "${_KNIT_PREFIX}"
    _KNIT_TEST_SETUP_ROOT="${_KNIT_TEST_TMPDIR}/setups"

    # Force the local backend so no scheduler is contacted; prepare never
    # dispatches anyway.
    _KNIT_DETECTED_JOB_MANAGER="<unknown>"

    KNIT_SCRIPT_PATH="/fake/exp.sh"

    _knit_create_metadata_table
    # prepare records into the jobs table but does not own it; create it up front.
    _knit_db_setup_table "submit" "jobs"

    # Fail loudly if a test ever reaches the local launcher: prepare must not
    # dispatch.
    _knit_submit_local() { printf 'DISPATCHED\n' >&2; return 1; }

    # A real terminal is unavailable under bats; default the stdin guard to "not a
    # terminal" so the stdin form works, and let the terminal test flip it.
    _knit_stdin_is_terminal() { return 1; }
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    _KNIT_DETECTED_JOB_MANAGER=""
    knit_test_db_teardown
}

# Register a job "render" (and, for the type tests, "other") requiring an "mcenv"
# setup, plus the built setup instance so a used_by edge is recorded.
_register_jobs_with_setup() {
    local setup="${_KNIT_TEST_SETUP_ROOT}/setup"
    mkdir -p "${setup}"
    printf 'mcenv\n'        > "${setup}/.setup.type"
    printf 'setup-uuid-1\n' > "${setup}/.setup.id"

    _submit_render_fn() { :; }
    knit_register_job "render" _submit_render_fn "render test job"
    knit_with_setup "mcenv"
    knit_with_optional "colormap:string" "gray" "Palette."
    knit_with_optional "zoom:string" "1.0" "Zoom factor."
    knit_with_flag "verbose" "Verbose output."
    knit_with_extra "Opaque passthrough for the job."
    knit_done

    _submit_other_fn() { :; }
    knit_register_job "other" _submit_other_fn "another test job"
    knit_with_setup "mcenv"
    knit_done
}

# Count of prepared jobs of a given job type.
_prepared_count() {
    sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM jobs WHERE state='prepared';"
}

# ---------- source: file and stdin ----------

@test "prepare from --file prepares each concrete entry in the plan" {
    _register_jobs_with_setup
    local plan="${_KNIT_TEST_TMPDIR}/plan.json"
    cat > "${plan}" <<'JSON'
{ "defaults": { "setup": "setup" },
  "jobs": [ { "job": "render" }, { "job": "render" } ] }
JSON

    run _knit_invoke_command prepare from --file "${plan}"
    [ "$status" -eq 0 ]
    [ "$(_prepared_count)" = "2" ]
    # One UUID printed per prepared job.
    [ "$(printf '%s\n' "$output" | grep -c .)" = "2" ]
}

@test "prepare from reads the plan from stdin when --file is omitted" {
    _register_jobs_with_setup

    run _knit_invoke_command prepare from <<'JSON'
{ "defaults": { "setup": "setup" }, "jobs": [ { "job": "render" } ] }
JSON
    [ "$status" -eq 0 ]
    [ "$(_prepared_count)" = "1" ]
}

@test "prepare from on an interactive terminal is fatal" {
    _register_jobs_with_setup
    _knit_stdin_is_terminal() { return 0; }

    run _knit_invoke_command prepare from
    [ "$status" -ne 0 ]
    [[ "$output" == *"no plan provided"* ]]
}

@test "prepare from with an empty stdin plan is fatal" {
    _register_jobs_with_setup

    run _knit_invoke_command prepare from <<'JSON'

JSON
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty"* ]]
}

@test "prepare from with a missing plan file is fatal" {
    _register_jobs_with_setup

    run _knit_invoke_command prepare from --file "/no/such/plan.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

# ---------- field resolution ----------

# The job's own arguments are baked into the generated .job.sh at prepare time
# (the compute-side "submit <job> …" line); the job's own table row is only
# written when the job actually runs, so these assert against .job.sh.
_jobscript_of() {
    cat "$(_knit_job_dir "$1")/.job.sh"
}

# The --colormap value baked into a prepared job's .job.sh (job args live there,
# submission args live in the jobs row).
_colormap_of() {
    local script
    script="$(_jobscript_of "$1")"
    [[ "${script}" =~ --colormap\ ([^\ ]+) ]] && printf '%s' "${BASH_REMATCH[1]}"
}

# Prepared job UUIDs in ascending id order (uuidv7 => prepare order).
_ordered_uuids() {
    sqlite3 "${_KNIT_DATABASE}" \
        "SELECT id FROM jobs WHERE state='prepared' ORDER BY id ASC;"
}

@test "prepare from renders object args as --key value" {
    _register_jobs_with_setup

    local uuid
    uuid="$(_knit_invoke_command prepare from <<'JSON'
{ "defaults": { "setup": "setup" },
  "jobs": [ { "job": "render", "args": { "colormap": "fire", "zoom": "2.0" } } ] }
JSON
)"
    local script
    script="$(_jobscript_of "${uuid}")"
    [[ "${script}" == *"submit render "*"--colormap fire"* ]]
    [[ "${script}" == *"--zoom 2.0"* ]]
}

@test "prepare from renders array args as raw tokens verbatim" {
    _register_jobs_with_setup

    local uuid
    uuid="$(_knit_invoke_command prepare from <<'JSON'
{ "defaults": { "setup": "setup" },
  "jobs": [ { "job": "render", "args": ["--colormap", "forest"] } ] }
JSON
)"
    [[ "$(_jobscript_of "${uuid}")" == *"submit render --colormap forest"* ]]
}

@test "prepare from renders a boolean true object arg as a bare flag" {
    _register_jobs_with_setup

    local uuid
    uuid="$(_knit_invoke_command prepare from <<'JSON'
{ "defaults": { "setup": "setup" },
  "jobs": [ { "job": "render", "args": { "verbose": true, "colormap": "ice" } } ] }
JSON
)"
    # true -> bare "--verbose" (no value), value args still "--key value".
    local script
    script="$(_jobscript_of "${uuid}")"
    [[ "${script}" == *"--verbose"* ]]
    [[ "${script}" != *"--verbose true"* ]]
    [[ "${script}" == *"--colormap ice"* ]]
}

@test "prepare from omits a boolean false object arg" {
    _register_jobs_with_setup

    local uuid
    uuid="$(_knit_invoke_command prepare from <<'JSON'
{ "defaults": { "setup": "setup" },
  "jobs": [ { "job": "render", "args": { "verbose": false, "colormap": "ice" } } ] }
JSON
)"
    # false -> the flag is omitted entirely.
    [[ "$(_jobscript_of "${uuid}")" != *"--verbose"* ]]
}

@test "prepare from appends extra tokens after args" {
    _register_jobs_with_setup

    local uuid
    uuid="$(_knit_invoke_command prepare from <<'JSON'
{ "defaults": { "setup": "setup" },
  "jobs": [ { "job": "render", "args": { "colormap": "ice" },
              "extra": ["--", "trailing"] } ] }
JSON
)"
    [ "$(_prepared_count)" = "1" ]
    [[ "$(_jobscript_of "${uuid}")" == *"--colormap ice -- trailing"* ]]
}

@test "prepare from treats other keys as submission arguments" {
    _register_jobs_with_setup

    local uuid
    uuid="$(_knit_invoke_command prepare from <<'JSON'
{ "jobs": [ { "job": "render", "setup": "setup", "nodes": 4 } ] }
JSON
)"
    # nodes is a submission column; the job's setup resolves from the entry key.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT nodes FROM jobs WHERE id='${uuid}';")" = "4" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT setup FROM jobs WHERE id='${uuid}';")" = "setup" ]
}

@test "prepare from rejects an unknown submission key" {
    _register_jobs_with_setup

    run _knit_invoke_command prepare from <<'JSON'
{ "jobs": [ { "job": "render", "setup": "setup", "notanoption": 1 } ] }
JSON
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown key"* ]]
    [[ "$output" == *"notanoption"* ]]
}

@test "prepare from rejects an entry missing a job" {
    _register_jobs_with_setup

    run _knit_invoke_command prepare from <<'JSON'
{ "jobs": [ { "setup": "setup" } ] }
JSON
    [ "$status" -ne 0 ]
    [[ "$output" == *"job"* ]]
}

@test "prepare from rejects an unknown job name" {
    _register_jobs_with_setup

    run _knit_invoke_command prepare from <<'JSON'
{ "jobs": [ { "job": "nosuchjob", "setup": "setup" } ] }
JSON
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown job"* ]]
}

# ---------- defaults merge and group precedence ----------

@test "prepare from merges defaults under each entry (entry wins)" {
    _register_jobs_with_setup

    local uuid
    uuid="$(_knit_invoke_command prepare from <<'JSON'
{ "defaults": { "setup": "setup", "nodes": 2 },
  "jobs": [ { "job": "render", "nodes": 8 } ] }
JSON
)"
    # The entry's nodes overrides the default; the default setup is inherited.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT nodes FROM jobs WHERE id='${uuid}';")" = "8" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT setup FROM jobs WHERE id='${uuid}';")" = "setup" ]
}

@test "prepare from applies the plan top-level group to every entry" {
    _register_jobs_with_setup

    local uuid
    uuid="$(_knit_invoke_command prepare from <<'JSON'
{ "group": "sweep", "defaults": { "setup": "setup" },
  "jobs": [ { "job": "render" } ] }
JSON
)"
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT \"group\" FROM jobs WHERE id='${uuid}';")" = "sweep" ]
}

@test "prepare from --group overrides the plan top-level group" {
    _register_jobs_with_setup

    local uuid
    uuid="$(_knit_invoke_command prepare from --group cli-group <<'JSON'
{ "group": "sweep", "defaults": { "setup": "setup" },
  "jobs": [ { "job": "render" } ] }
JSON
)"
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT \"group\" FROM jobs WHERE id='${uuid}';")" = "cli-group" ]
}

@test "prepare from lets a per-entry group override the top-level group" {
    _register_jobs_with_setup

    local uuid
    uuid="$(_knit_invoke_command prepare from --group cli-group <<'JSON'
{ "group": "sweep", "defaults": { "setup": "setup" },
  "jobs": [ { "job": "render", "group": "own" } ] }
JSON
)"
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT \"group\" FROM jobs WHERE id='${uuid}';")" = "own" ]
}

# ---------- ordering and atomicity ----------

@test "prepare from prepares entries in plan order" {
    _register_jobs_with_setup
    _stub_dispatch_ok() { _knit_submit_local() { printf '1\n'; }; }
    _stub_dispatch_ok

    local out
    out="$(_knit_invoke_command prepare from <<'JSON'
{ "defaults": { "setup": "setup" },
  "jobs": [ { "job": "render", "args": { "colormap": "a" } },
            { "job": "render", "args": { "colormap": "b" } },
            { "job": "render", "args": { "colormap": "c" } } ] }
JSON
)"
    # UUIDs print in plan order, and uuidv7 ids are time-ordered, so the printed
    # order matches ascending id order (the order `submit next` later releases).
    local -a printed sorted
    mapfile -t printed <<< "${out}"
    mapfile -t sorted < <(printf '%s\n' "${printed[@]}" | sort)
    [ "${printed[*]}" = "${sorted[*]}" ]
    [ "${#printed[@]}" = "3" ]
}

@test "prepare from validates the whole plan before preparing anything" {
    _register_jobs_with_setup

    # The second entry has an unknown key, so the first (valid) entry must not be
    # prepared: a bad plan leaves nothing half-prepared.
    run _knit_invoke_command prepare from <<'JSON'
{ "defaults": { "setup": "setup" },
  "jobs": [ { "job": "render" }, { "job": "render", "bogus": 1 } ] }
JSON
    [ "$status" -ne 0 ]
    [ "$(_prepared_count)" = "0" ]
}

@test "prepare from rejects a plan that is not valid JSON" {
    _register_jobs_with_setup

    run _knit_invoke_command prepare from <<'JSON'
{ not json
JSON
    [ "$status" -ne 0 ]
    [[ "$output" == *"not valid JSON"* ]]
}

@test "prepare from rejects a plan without a jobs array" {
    _register_jobs_with_setup

    run _knit_invoke_command prepare from <<'JSON'
{ "defaults": { "setup": "setup" } }
JSON
    [ "$status" -ne 0 ]
    [[ "$output" == *"jobs"* ]]
}

@test "prepare from with an empty jobs list prepares nothing" {
    _register_jobs_with_setup

    run _knit_invoke_command prepare from <<'JSON'
{ "jobs": [] }
JSON
    [ "$status" -eq 0 ]
    [ "$(_prepared_count)" = "0" ]
}

# ---------- matrix expansion ----------

@test "prepare from expands a matrix to the cartesian product" {
    _register_jobs_with_setup

    _knit_invoke_command prepare from <<'JSON' >/dev/null
{ "defaults": { "setup": "setup" },
  "jobs": [ { "matrix": {
      "job": "render",
      "axes": { "args": [ {"colormap":"fire"}, {"colormap":"ice"} ],
                "nodes": [2, 4] } } } ] }
JSON
    # 2 colormaps x 2 node counts = 4 prepared jobs.
    [ "$(_prepared_count)" = "4" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM jobs WHERE state='prepared' AND nodes=2;")" = "2" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM jobs WHERE state='prepared' AND nodes=4;")" = "2" ]
}

@test "prepare from drops excluded matrix combinations" {
    _register_jobs_with_setup

    _knit_invoke_command prepare from <<'JSON' >/dev/null
{ "defaults": { "setup": "setup" },
  "jobs": [ { "matrix": {
      "job": "render",
      "axes": { "args": [ {"colormap":"fire"}, {"colormap":"ice"} ],
                "nodes": [2, 4] },
      "exclude": [ { "args": {"colormap":"ice"}, "nodes": 4 } ] } } ] }
JSON
    # Product is 4, minus the one excluded combination (ice/4) = 3.
    [ "$(_prepared_count)" = "3" ]
    # No prepared row is the excluded ice/4 combination.
    local id nodes cmap
    while IFS= read -r id; do
        nodes="$(sqlite3 "${_KNIT_DATABASE}" \
            "SELECT nodes FROM jobs WHERE id='${id}';")"
        cmap="$(_colormap_of "${id}")"
        [ "${nodes}/${cmap}" != "4/ice" ]
    done < <(_ordered_uuids)
}

@test "prepare from appends matrix include entries as standalone combinations" {
    _register_jobs_with_setup

    _knit_invoke_command prepare from <<'JSON' >/dev/null
{ "defaults": { "setup": "setup" },
  "jobs": [ { "matrix": {
      "job": "render",
      "axes": { "args": [ {"colormap":"fire"} ], "nodes": [2] },
      "include": [ { "args": {"colormap":"forest"}, "nodes": 8 } ] } } ] }
JSON
    # One product combination plus one appended include.
    [ "$(_prepared_count)" = "2" ]
    # The include carries the block's job (render) and its own fields.
    local id
    id="$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT id FROM jobs WHERE state='prepared' AND nodes=8;")"
    [ -n "${id}" ]
    [ "$(_colormap_of "${id}")" = "forest" ]
}

@test "prepare from varies a submission argument across a matrix axis" {
    _register_jobs_with_setup

    _knit_invoke_command prepare from <<'JSON' >/dev/null
{ "defaults": { "setup": "setup" },
  "jobs": [ { "matrix": {
      "job": "render",
      "args": { "colormap": "gray" },
      "axes": { "nodes": [2, 4, 8] } } } ] }
JSON
    [ "$(_prepared_count)" = "3" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT group_concat(nodes) FROM (SELECT nodes FROM jobs \
         WHERE state='prepared' ORDER BY nodes);")" = "2,4,8" ]
}

@test "prepare from applies defaults to every matrix combination" {
    _register_jobs_with_setup

    _knit_invoke_command prepare from <<'JSON' >/dev/null
{ "defaults": { "setup": "setup", "nodes": 2 },
  "jobs": [ { "matrix": {
      "job": "render",
      "axes": { "args": [ {"colormap":"a"}, {"colormap":"b"} ] } } } ] }
JSON
    [ "$(_prepared_count)" = "2" ]
    # Every combination inherits the default setup and nodes.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM jobs WHERE state='prepared' \
         AND setup='setup' AND nodes=2;")" = "2" ]
}

@test "prepare from prepares matrix combinations in product order, interleaved" {
    _register_jobs_with_setup

    _knit_invoke_command prepare from <<'JSON' >/dev/null
{ "defaults": { "setup": "setup" },
  "jobs": [ { "job": "render", "args": { "colormap": "pre" } },
            { "matrix": {
                "job": "render",
                "axes": { "args": [ {"colormap":"x"}, {"colormap":"y"} ] } } },
            { "job": "render", "args": { "colormap": "post" } } ] }
JSON
    [ "$(_prepared_count)" = "4" ]
    local -a ids
    mapfile -t ids < <(_ordered_uuids)
    local seq=""
    local id
    for id in "${ids[@]}"; do
        seq+="$(_colormap_of "${id}") "
    done
    # Concrete entries and the expanded matrix interleave in plan order.
    [ "${seq}" = "pre x y post " ]
}

@test "prepare from rejects a malformed matrix block before preparing" {
    _register_jobs_with_setup

    # An axis whose value is not a list is a structural error; nothing prepares.
    run _knit_invoke_command prepare from <<'JSON'
{ "defaults": { "setup": "setup" },
  "jobs": [ { "matrix": { "job": "render", "axes": { "nodes": 2 } } } ] }
JSON
    [ "$status" -ne 0 ]
    [[ "$output" == *"axis"* ]]
    [ "$(_prepared_count)" = "0" ]
}

@test "prepare from validates an expanded matrix job name" {
    _register_jobs_with_setup

    # The matrix carries an unregistered job; expansion resolves it, then the
    # normal job-existence check rejects it before anything prepares.
    run _knit_invoke_command prepare from <<'JSON'
{ "defaults": { "setup": "setup" },
  "jobs": [ { "matrix": { "job": "nosuchjob",
                          "axes": { "nodes": [2, 4] } } } ] }
JSON
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown job"* ]]
    [ "$(_prepared_count)" = "0" ]
}
