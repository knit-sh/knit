#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    _knit_create_metadata_table

    _KNIT_TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/.knit"
    mkdir -p "${_KNIT_PREFIX}"

    # Setups resolve under <experiment-root>/setups (the __setup_path__ fallback);
    # tests reference this root directly.
    _KNIT_TEST_SETUP_ROOT="${_KNIT_TEST_TMPDIR}/setups"
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    unset KNIT_SETUP_PREFIX
    knit_test_db_teardown
}

# ---------- knit_register_setup ----------

@test "knit_register_setup adds name to _KNIT_SETUPS" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    [[ -v _KNIT_SETUPS["mysetup"] ]]
}

@test "knit_register_setup registers setup:<name> command" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    _knit_set_find _KNIT_COMMANDS "setup__1__mysetup"
}

@test "setup --help shows the parent grammar and the required --name option" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_with_optional "seed:integer" "1" "Random seed."
    knit_done
    local result
    result=$(_knit_invoke_command "setup" "mysetup" "--help")
    [[ "$result" == *"setup [OPTIONS] -- mysetup [OPTIONS]"* ]]
    [[ "$result" == *"--seed"* ]]
    [[ "$result" == *"setup options"* ]]
    [[ "$result" == *"--name"* ]]
}

@test "knit_register_setup creates DB table named setup:<name>" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    local result
    result=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='setup:mysetup';")
    [ "$result" -eq 1 ]
}

@test "knit_register_setup table has id as first column" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    local first_col
    first_col=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('setup:mysetup');" | cut -d'|' -f2 | head -1)
    [ "$first_col" = "id" ]
}

@test "knit_register_setup table includes declared parameter" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_with_optional "version:string" "main" "Version."
    knit_done
    local names
    names=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('setup:mysetup');" | cut -d'|' -f2 | tr '\n' ',')
    [ "$names" = "id,version," ]
}

@test "knit_register_setup installs before callback" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "setup:mysetup")
    local cb_content
    eval "cb_content=\"\${_KNIT_CMD_${cmd}_before_cb[*]}\""
    [[ "${cb_content}" == *_knit_setup_before_cb* ]]
}

@test "knit_register_setup installs after callback" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "setup:mysetup")
    local cb_content
    eval "cb_content=\"\${_KNIT_CMD_${cmd}_after_cb[*]}\""
    [[ "${cb_content}" == *_knit_setup_after_cb* ]]
}

# ---------- _knit_setup_before_cb ----------

@test "setup before callback fails when KNIT_SETUP_PREFIX is not set" {
    unset KNIT_SETUP_PREFIX
    run _knit_setup_before_cb
    [ "$status" -ne 0 ]
}

@test "setup before callback succeeds when KNIT_SETUP_PREFIX is set" {
    export KNIT_SETUP_PREFIX="/tmp"
    run _knit_setup_before_cb
    [ "$status" -eq 0 ]
}

# ---------- _knit_setup_after_cb ----------

@test "setup after callback creates .activate.sh in KNIT_SETUP_PREFIX" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}"
    _knit_setup_after_cb
    [ -f "${KNIT_SETUP_PREFIX}/.activate.sh" ]
}

@test "setup after callback makes .activate.sh executable" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}"
    _knit_setup_after_cb
    [ -x "${KNIT_SETUP_PREFIX}/.activate.sh" ]
}

@test "setup after callback writes exported variable to .activate.sh" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}"
    export _KNIT_TEST_CANARY="hello_world"
    _knit_setup_after_cb
    grep -q '_KNIT_TEST_CANARY' "${KNIT_SETUP_PREFIX}/.activate.sh"
}

@test "setup after callback excludes SHLVL from .activate.sh" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}"
    _knit_setup_after_cb
    ! grep -q '^export SHLVL=' "${KNIT_SETUP_PREFIX}/.activate.sh"
}

@test "setup after callback excludes KNIT_SETUP_PREFIX itself from .activate.sh" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}"
    _knit_setup_after_cb
    ! grep -q '^export KNIT_SETUP_PREFIX=' "${KNIT_SETUP_PREFIX}/.activate.sh"
}

@test "setup after callback excludes readonly variables from .activate.sh" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}"
    # A readonly exported variable cannot be re-exported: sourcing .activate.sh
    # would fail with "readonly variable", so it must be skipped.
    declare -xr _KNIT_TEST_RO="frozen"
    _knit_setup_after_cb
    ! grep -q '_KNIT_TEST_RO' "${KNIT_SETUP_PREFIX}/.activate.sh"
}

@test "setup after callback produces a source-able .activate.sh (no readonly errors)" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}"
    # KNIT_VERSION is declared readonly by knit; the generated file must be
    # source-able in a fresh shell that has knit.sh loaded (KNIT_VERSION set).
    _knit_setup_after_cb
    run bash -c "source knit.sh >/dev/null 2>&1; source '${KNIT_SETUP_PREFIX}/.activate.sh'"
    [ "$status" -eq 0 ]
}

# ---------- platform consumption (before/after cb) ----------

@test "setup before callback sources the platform fragment" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}"
    printf '%s\n' 'export _KNIT_TEST_PLATFORM_CANARY=on' > "${_KNIT_PREFIX}/platform.sh"
    _knit_setup_before_cb
    [ "${_KNIT_TEST_PLATFORM_CANARY:-}" = "on" ]
    unset _KNIT_TEST_PLATFORM_CANARY
}

@test "setup before callback is a no-op when platform.sh is absent" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}"
    rm -f "${_KNIT_PREFIX}/platform.sh"
    run _knit_setup_before_cb
    [ "$status" -eq 0 ]
}

@test "setup after callback inlines platform.sh at the top of .activate.sh" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}"
    printf '%s\n' '# knit platform environment (generated at bootstrap)' \
                  'module load cray-mpich' > "${_KNIT_PREFIX}/platform.sh"
    _knit_setup_after_cb
    local activate="${KNIT_SETUP_PREFIX}/.activate.sh"
    grep -Fq 'module load cray-mpich' "${activate}"
    # The inlined platform block must precede the environment dump.
    local platform_line export_line
    platform_line=$(grep -n 'module load cray-mpich' "${activate}" | head -1 | cut -d: -f1)
    export_line=$(grep -n '^export ' "${activate}" | head -1 | cut -d: -f1)
    [ "${platform_line}" -lt "${export_line}" ]
}

@test "setup after callback does not inline when platform.sh is absent" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}"
    rm -f "${_KNIT_PREFIX}/platform.sh"
    _knit_setup_after_cb
    ! grep -Fq 'Platform activation (inlined' "${KNIT_SETUP_PREFIX}/.activate.sh"
}

# ---------- _knit_setup ----------

@test "_knit_setup maps --name to <setup-root>/<name>" {
    local newdir="${_KNIT_TEST_SETUP_ROOT}/myenv"
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    _knit_setup --name myenv -- mysetup
    [ -d "${newdir}" ]
}

@test "_knit_setup rejects an invalid instance name" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    run _knit_setup --name "a/b" -- mysetup
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid name"* ]]
}

@test "_knit_setup rejects the reserved name default for a non-default type" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    run _knit_setup --name default -- mysetup
    [ "$status" -ne 0 ]
    [[ "$output" == *"reserved"* ]]
}

@test "_knit_setup allows the name default for the builtin default type" {
    _knit_setup --name default -- default
    [ -d "${_KNIT_TEST_SETUP_ROOT}/default" ]
    [ "$(cat "${_KNIT_TEST_SETUP_ROOT}/default/.setup.type")" = "default" ]
}

@test "_knit_setup rebuilds idempotently when the named instance exists" {
    local newdir="${_KNIT_TEST_SETUP_ROOT}/myenv"
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    _knit_setup --name myenv -- mysetup
    # A stale file left inside the instance must be gone after a rebuild.
    touch "${newdir}/STALE"
    _knit_setup --name myenv -- mysetup
    [ -d "${newdir}" ]
    [ ! -f "${newdir}/STALE" ]
}

@test "_knit_setup fails if setup name is not registered" {
    run _knit_setup --name newenv -- unknownsetup
    [ "$status" -ne 0 ]
}

@test "_knit_setup fails if setup args are invalid" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    run _knit_setup --name myenv -- mysetup --unknown-arg foo
    [ "$status" -ne 0 ]
}

@test "_knit_setup creates the directory on success" {
    local newdir="${_KNIT_TEST_SETUP_ROOT}/myenv"
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    _knit_setup --name myenv -- mysetup
    [ -d "${newdir}" ]
}

@test "_knit_setup sets KNIT_SETUP_PREFIX inside the setup function" {
    local newdir="${_KNIT_TEST_SETUP_ROOT}/myenv"
    local prefix_file="${_KNIT_TEST_TMPDIR}/prefix.txt"
    _test_setup_fn() {
        printf '%s' "${KNIT_SETUP_PREFIX}" > "${prefix_file}"
    }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    _knit_setup --name myenv -- mysetup
    local captured
    captured=$(cat "${prefix_file}")
    [ "${captured}" = "${newdir}" ]
}

@test "_knit_setup actually invokes the setup function" {
    local sentinel="${_KNIT_TEST_TMPDIR}/sentinel"
    _test_setup_fn() {
        touch "${sentinel}"
    }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    _knit_setup --name myenv -- mysetup
    [ -f "${sentinel}" ]
}

@test "_knit_setup removes directory when setup function fails" {
    local newdir="${_KNIT_TEST_SETUP_ROOT}/myenv"
    _test_setup_fn() { return 1; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    run _knit_setup --name myenv -- mysetup
    [ "$status" -ne 0 ]
    [ ! -d "${newdir}" ]
}

@test "_knit_setup creates .activate.sh after success" {
    local newdir="${_KNIT_TEST_SETUP_ROOT}/myenv"
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    _knit_setup --name myenv -- mysetup
    [ -f "${newdir}/.activate.sh" ]
}

@test "_knit_setup records the setup type in .setup.type" {
    local newdir="${_KNIT_TEST_SETUP_ROOT}/myenv"
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    _knit_setup --name myenv -- mysetup
    [ -f "${newdir}/.setup.type" ]
    [ "$(cat "${newdir}/.setup.type")" = "mysetup" ]
}

@test "_knit_setup does not write .setup.type when the setup fails" {
    local newdir="${_KNIT_TEST_SETUP_ROOT}/myenv"
    _test_setup_fn() { return 1; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    run _knit_setup --name myenv -- mysetup
    [ ! -f "${newdir}/.setup.type" ]
}

@test "_knit_setup records the setup body's row id in .setup.id" {
    local newdir="${_KNIT_TEST_SETUP_ROOT}/myenv"
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    _knit_setup --name myenv -- mysetup
    [ -f "${newdir}/.setup.id" ]
    # The recorded marker matches the id of the row the setup body wrote to its
    # own table, so a consumer can join to that row by id.
    [ "$(cat "${newdir}/.setup.id")" \
        = "$(sqlite3 "${_KNIT_DATABASE}" 'SELECT id FROM "setup:mysetup";')" ]
}

# ---------- _knit_setup_check_type ----------

@test "_knit_setup_check_type accepts a matching type" {
    local d="${_KNIT_TEST_TMPDIR}/dep"
    mkdir -p "${d}"
    printf 'mcenv\n' > "${d}/.setup.type"
    run _knit_setup_check_type "${d}" "mcenv"
    [ "$status" -eq 0 ]
}

@test "_knit_setup_check_type rejects a missing marker" {
    local d="${_KNIT_TEST_TMPDIR}/dep"
    mkdir -p "${d}"
    run _knit_setup_check_type "${d}" "mcenv"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no recorded type"* ]]
}

@test "_knit_setup_check_type rejects a type mismatch" {
    local d="${_KNIT_TEST_TMPDIR}/dep"
    mkdir -p "${d}"
    printf 'otherenv\n' > "${d}/.setup.type"
    run _knit_setup_check_type "${d}" "mcenv"
    [ "$status" -ne 0 ]
    [[ "$output" == *"mcenv"* ]]
    [[ "$output" == *"otherenv"* ]]
}

# ---------- _knit_setup_dep_before_cb ----------

@test "_knit_setup_dep_before_cb sources the --setup activate.sh" {
    local d="${_KNIT_TEST_TMPDIR}/dep"
    mkdir -p "${d}"
    printf 'mcenv\n' > "${d}/.setup.type"
    printf 'export DEP_MARK=hello\n' > "${d}/.activate.sh"
    unset KNIT_SETUP_PREFIX DEP_MARK
    _knit_setup_dep_before_cb "mcenv" --setup "${d}"
    [ "${DEP_MARK}" = "hello" ]
    [ "${KNIT_SETUP_PREFIX}" = "$(realpath "${d}")" ]
}

@test "_knit_setup_dep_before_cb falls back to the ambient prefix" {
    local d="${_KNIT_TEST_TMPDIR}/dep"
    mkdir -p "${d}"
    printf 'mcenv\n' > "${d}/.setup.type"
    printf 'export DEP_MARK=amb\n' > "${d}/.activate.sh"
    export KNIT_SETUP_PREFIX="${d}"
    unset DEP_MARK
    _knit_setup_dep_before_cb "mcenv"
    [ "${DEP_MARK}" = "amb" ]
}

@test "_knit_setup_dep_before_cb fatals when no --setup and no ambient prefix" {
    unset KNIT_SETUP_PREFIX
    run _knit_setup_dep_before_cb "mcenv"
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a --setup"* ]]
}

@test "_knit_setup_dep_before_cb does not clobber an existing KNIT_SETUP_PREFIX" {
    local own="${_KNIT_TEST_TMPDIR}/own"
    local dep="${_KNIT_TEST_TMPDIR}/dep"
    mkdir -p "${own}" "${dep}"
    printf 'mcenv\n' > "${dep}/.setup.type"
    printf 'export DEP_MARK=dep\n' > "${dep}/.activate.sh"
    export KNIT_SETUP_PREFIX="${own}"
    _knit_setup_dep_before_cb "mcenv" --setup "${dep}"
    [ "${DEP_MARK}" = "dep" ]
    [ "${KNIT_SETUP_PREFIX}" = "${own}" ]
}

@test "_knit_setup_dep_before_cb rejects a wrong-type --setup" {
    local d="${_KNIT_TEST_TMPDIR}/dep"
    mkdir -p "${d}"
    printf 'otherenv\n' > "${d}/.setup.type"
    printf 'export DEP_MARK=x\n' > "${d}/.activate.sh"
    unset KNIT_SETUP_PREFIX
    run _knit_setup_dep_before_cb "mcenv" --setup "${d}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"mcenv"* ]]
    [[ "$output" == *"otherenv"* ]]
}

# ---------- knit_with_setup (generic) ----------

@test "knit_with_setup on a plain command adds a marker, --setup option, and callback" {
    _test_fn() { :; }
    knit_register "_test_fn" "plaincmd" "A plain command."
    knit_with_setup "mcenv"
    knit_done
    [ "${_KNIT_CMD_plaincmd_setup}" = "mcenv" ]
    _knit_set_find "_KNIT_CMD_plaincmd_optional" "setup"
    local -n _cbs="_KNIT_CMD_plaincmd_before_cb"
    [[ "${_cbs[*]}" == *"_knit_setup_dep_before_cb mcenv"* ]]
}

@test "knit_with_setup on a plain command adds a Requirements help note" {
    _test_fn() { :; }
    knit_register "_test_fn" "plaincmd" "A plain command."
    knit_with_setup "mcenv"
    knit_done
    local -n _notes="_KNIT_CMD_plaincmd_notes"
    [[ "${_notes[*]}" == *'Requires a --setup built by the "mcenv" setup.'* ]]
}

@test "knit_with_setup is rejected on a setup command" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    run knit_with_setup "mcenv"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be used on a setup"* ]]
    knit_done
}

@test "knit_with_setup is rejected on a wrapper" {
    _wrap_fn() { :; }
    knit_register_wrapper "mywrap" "_wrap_fn" "A wrapper."
    run knit_with_setup "mcenv"
    [ "$status" -ne 0 ]
    [[ "$output" == *"wrapper"* ]]
    knit_done
}

@test "knit_with_setup may be called at most once per command" {
    _test_fn() { :; }
    knit_register "_test_fn" "plaincmd" "A plain command."
    knit_with_setup "mcenv"
    run knit_with_setup "other"
    [ "$status" -ne 0 ]
    knit_done
}

@test "knit_with_setup on a plain command installs the used_by-edge after-callback" {
    _test_fn() { :; }
    knit_register "_test_fn" "plaincmd" "A plain command."
    knit_with_setup "mcenv"
    knit_done
    local -n _acbs="_KNIT_CMD_plaincmd_after_cb"
    [[ "${_acbs[*]}" == *"_knit_setup_dep_after_cb"* ]]
}

# ---------- knit_without_setup ----------

@test "knit_without_setup on a job sets the no_setup marker" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_without_setup
    knit_done
    [ -n "${_KNIT_CMD_submit__1__myjob_no_setup:-}" ]
}

@test "knit_without_setup is a no-op on a plain command (no marker)" {
    _test_fn() { :; }
    knit_register "_test_fn" "plaincmd" "A plain command."
    run knit_without_setup
    [ "$status" -eq 0 ]
    knit_without_setup
    knit_done
    [ ! -v _KNIT_CMD_plaincmd_no_setup ]
}

@test "knit_without_setup is rejected on a setup command" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    run knit_without_setup
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be used on a setup"* ]]
    knit_done
}

@test "knit_without_setup is rejected on a wrapper" {
    _wrap_fn() { :; }
    knit_register_wrapper "mywrap" "_wrap_fn" "A wrapper."
    run knit_without_setup
    [ "$status" -ne 0 ]
    [[ "$output" == *"wrapper"* ]]
    knit_done
}

@test "knit_without_setup after knit_with_setup is mutually exclusive" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_with_setup "mcenv"
    run knit_without_setup
    [ "$status" -ne 0 ]
    [[ "$output" == *"mutually exclusive"* ]]
    knit_done
}

@test "knit_with_setup after knit_without_setup is mutually exclusive" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_without_setup
    run knit_with_setup "mcenv"
    [ "$status" -ne 0 ]
    [[ "$output" == *"mutually exclusive"* ]]
    knit_done
}

# ---------- builtin "default" setup ----------

@test "_knit_default_setup_path is default under the setup root" {
    [ "$(_knit_default_setup_path)" = "${_KNIT_TEST_SETUP_ROOT}/default" ]
}

@test "_knit_setup_default_after_cb writes a platform-only .activate.sh (no env dump)" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/def"
    mkdir -p "${KNIT_SETUP_PREFIX}"
    export _KNIT_TEST_CANARY="canary"
    _knit_setup_default_after_cb
    local activate="${KNIT_SETUP_PREFIX}/.activate.sh"
    [ -x "${activate}" ]
    # The default setup carries no environment dump: unlike the generic after-cb
    # it must not re-export the ambient shell environment.
    ! grep -q '_KNIT_TEST_CANARY' "${activate}"
}

@test "_knit_setup_default_after_cb inlines platform.sh when present" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/def"
    mkdir -p "${KNIT_SETUP_PREFIX}"
    printf 'export PLATFORM_SEEDED=1\n' > "${_KNIT_PREFIX}/platform.sh"
    _knit_setup_default_after_cb
    grep -Fq 'Platform activation (inlined' "${KNIT_SETUP_PREFIX}/.activate.sh"
    grep -q 'PLATFORM_SEEDED' "${KNIT_SETUP_PREFIX}/.activate.sh"
}

@test "_knit_setup instantiates the builtin default setup" {
    local newdir="${_KNIT_TEST_SETUP_ROOT}/default"
    export _KNIT_TEST_CANARY="canary"
    _knit_setup --name default -- default
    [ "$(cat "${newdir}/.setup.type")" = "default" ]
    # Platform-only: no ambient environment dump.
    ! grep -q '_KNIT_TEST_CANARY' "${newdir}/.activate.sh"
    # The setup body recorded a row and its id was written to .setup.id.
    [ -f "${newdir}/.setup.id" ]
    [ "$(cat "${newdir}/.setup.id")" \
        = "$(sqlite3 "${_KNIT_DATABASE}" 'SELECT id FROM "setup:default";')" ]
}

@test "_knit_setup_dep_resolve_path falls back to the default path" {
    unset KNIT_SETUP_PREFIX
    [ "$(_knit_setup_dep_resolve_path "default")" \
        = "${_KNIT_TEST_SETUP_ROOT}/default" ]
}

@test "_knit_setup_dep_resolve_path returns empty for a non-default type" {
    unset KNIT_SETUP_PREFIX
    [ -z "$(_knit_setup_dep_resolve_path "mcenv")" ]
}

# ---------- used_by edges ----------

# Build a fake setup directory holding the markers a real `knit setup` writes.
_seed_setup_dir() {
    local dir="$1" type="$2" id="$3"
    mkdir -p "${dir}"
    printf '%s\n' "${type}" > "${dir}/.setup.type"
    [[ -n "${id}" ]] && printf '%s\n' "${id}" > "${dir}/.setup.id"
    printf ':\n' > "${dir}/.activate.sh"
}

@test "a consumer with knit_with_setup records a used_by edge to the setup" {
    local dep="${_KNIT_TEST_TMPDIR}/dep"
    _seed_setup_dir "${dep}" "mcenv" "setup-uuid-1"
    _test_fn() { :; }
    knit_register "_test_fn" "plaincmd" "A plain command."
    knit_with_table "plaincmd"
    knit_with_setup "mcenv"
    knit_done
    unset KNIT_SETUP_PREFIX
    _knit_invoke_command plaincmd --setup "${dep}"
    # The used_by edge's source is the setup (id from .setup.id, name setup:<type>),
    # its target is the consumer's recorded row, and it has no duration.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT source_id,source_name,target_name,edge_type,start_time,end_time FROM ${_KNIT_PROV_TABLE} WHERE edge_type='used_by';")" \
        = "setup-uuid-1|setup:mcenv|plaincmd|used_by||" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT target_id FROM ${_KNIT_PROV_TABLE} WHERE edge_type='used_by';")" \
        = "$(sqlite3 "${_KNIT_DATABASE}" 'SELECT id FROM plaincmd;')" ]
}

@test "a consumer records no used_by edge when the setup has no .setup.id" {
    local dep="${_KNIT_TEST_TMPDIR}/dep"
    _seed_setup_dir "${dep}" "mcenv" ""
    _test_fn() { :; }
    knit_register "_test_fn" "plaincmd" "A plain command."
    knit_with_table "plaincmd"
    knit_with_setup "mcenv"
    knit_done
    unset KNIT_SETUP_PREFIX
    _knit_invoke_command plaincmd --setup "${dep}"
    _knit_prov_ensure_table
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM ${_KNIT_PROV_TABLE} WHERE edge_type='used_by';")" = "0" ]
}

@test "_knit_setup_record_uses_edge writes source, target, and NULL timestamps" {
    local dep="${_KNIT_TEST_TMPDIR}/dep"
    _seed_setup_dir "${dep}" "mcenv" "setup-uuid-9"
    _test_fn() { :; }
    knit_register "_test_fn" "plaincmd" "A plain command."
    knit_done
    _knit_setup_record_uses_edge "${dep}" "plaincmd" "target-uuid-9"
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT source_id,source_name,target_id,target_name,edge_type,start_time,end_time FROM ${_KNIT_PROV_TABLE};")" \
        = "setup-uuid-9|setup:mcenv|target-uuid-9|plaincmd|used_by||" ]
}

@test "_knit_setup_record_uses_edge records nothing for a without-provenance target" {
    local dep="${_KNIT_TEST_TMPDIR}/dep"
    _seed_setup_dir "${dep}" "mcenv" "setup-uuid-9"
    _test_fn() { :; }
    knit_register "_test_fn" "plaincmd" "A plain command."
    knit_without_provenance
    knit_done
    _knit_setup_record_uses_edge "${dep}" "plaincmd" "target-uuid-9"
    _knit_prov_ensure_table
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM ${_KNIT_PROV_TABLE};")" = "0" ]
}
