#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    _KNIT_TEST_TMPDIR="$(mktemp -d)"
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

@test "setup --help shows the parent grammar and the required --path option" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_with_optional "seed:integer" "1" "Random seed."
    knit_done
    local result
    result=$(_knit_invoke_command "setup" "mysetup" "--help")
    [[ "$result" == *"setup [OPTIONS] -- mysetup [OPTIONS]"* ]]
    [[ "$result" == *"--seed"* ]]
    [[ "$result" == *"setup options"* ]]
    [[ "$result" == *"--path"* ]]
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

# ---------- _knit_setup ----------

@test "_knit_setup fails if path already exists" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    local existing="${_KNIT_TEST_TMPDIR}/existing"
    mkdir -p "${existing}"
    run _knit_setup --path "${existing}" -- mysetup
    [ "$status" -ne 0 ]
}

@test "_knit_setup fails if setup name is not registered" {
    run _knit_setup --path "${_KNIT_TEST_TMPDIR}/newdir" -- unknownsetup
    [ "$status" -ne 0 ]
}

@test "_knit_setup fails if setup args are invalid" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/newdir"
    run _knit_setup --path "${_KNIT_TEST_TMPDIR}/newdir" -- mysetup --unknown-arg foo
    [ "$status" -ne 0 ]
}

@test "_knit_setup creates the directory on success" {
    local sentinel="${_KNIT_TEST_TMPDIR}/sentinel"
    local newdir="${_KNIT_TEST_TMPDIR}/newdir"
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    export KNIT_SETUP_PREFIX="${newdir}"
    _knit_setup --path "${newdir}" -- mysetup
    [ -d "${newdir}" ]
}

@test "_knit_setup sets KNIT_SETUP_PREFIX inside the setup function" {
    local newdir="${_KNIT_TEST_TMPDIR}/newdir"
    local prefix_file="${_KNIT_TEST_TMPDIR}/prefix.txt"
    _test_setup_fn() {
        printf '%s' "${KNIT_SETUP_PREFIX}" > "${prefix_file}"
    }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    _knit_setup --path "${newdir}" -- mysetup
    local captured
    captured=$(cat "${prefix_file}")
    [ "${captured}" = "${newdir}" ]
}

@test "_knit_setup actually invokes the setup function" {
    local newdir="${_KNIT_TEST_TMPDIR}/newdir"
    local sentinel="${_KNIT_TEST_TMPDIR}/sentinel"
    _test_setup_fn() {
        touch "${sentinel}"
    }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    _knit_setup --path "${newdir}" -- mysetup
    [ -f "${sentinel}" ]
}

@test "_knit_setup removes directory when setup function fails" {
    local newdir="${_KNIT_TEST_TMPDIR}/newdir"
    _test_setup_fn() { return 1; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    run _knit_setup --path "${newdir}" -- mysetup
    [ "$status" -ne 0 ]
    [ ! -d "${newdir}" ]
}

@test "_knit_setup creates .activate.sh after success" {
    local newdir="${_KNIT_TEST_TMPDIR}/newdir"
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    _knit_setup --path "${newdir}" -- mysetup
    [ -f "${newdir}/.activate.sh" ]
}

@test "_knit_setup records the setup type in .setup.type" {
    local newdir="${_KNIT_TEST_TMPDIR}/newdir"
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    _knit_setup --path "${newdir}" -- mysetup
    [ -f "${newdir}/.setup.type" ]
    [ "$(cat "${newdir}/.setup.type")" = "mysetup" ]
}

@test "_knit_setup does not write .setup.type when the setup fails" {
    local newdir="${_KNIT_TEST_TMPDIR}/newdir"
    _test_setup_fn() { return 1; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    run _knit_setup --path "${newdir}" -- mysetup
    [ ! -f "${newdir}/.setup.type" ]
}
