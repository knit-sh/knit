#!/usr/bin/env bats

setup() {
    if ! command -v sqlite3 &>/dev/null; then
        skip "sqlite3 not available"
    fi

    source knit.sh

    __KNIT_SQLITE_EXE="sqlite3"
    __KNIT_DATABASE="$(mktemp --suffix=.db)"
    __KNIT_TEST_TMPDIR="$(mktemp -d)"

    # Satisfy the bootstrap check — tests in this file work with a live DB
    _KNIT_IS_BOOTSTRAPPED="1"
}

teardown() {
    rm -f "${__KNIT_DATABASE}"
    rm -rf "${__KNIT_TEST_TMPDIR}"
    unset KNIT_SETUP_PREFIX
    _KNIT_IS_BOOTSTRAPPED=""
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

@test "knit_register_setup creates DB table named setup:<name>" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    local result
    result=$(sqlite3 "${__KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='setup:mysetup';")
    [ "$result" -eq 1 ]
}

@test "knit_register_setup table has id as first column" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    local first_col
    first_col=$(sqlite3 "${__KNIT_DATABASE}" "PRAGMA table_info('setup:mysetup');" | cut -d'|' -f2 | head -1)
    [ "$first_col" = "id" ]
}

@test "knit_register_setup table includes declared parameter" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_with_optional "version:string" "main" "Version."
    knit_done
    local names
    names=$(sqlite3 "${__KNIT_DATABASE}" "PRAGMA table_info('setup:mysetup');" | cut -d'|' -f2 | tr '\n' ',')
    [ "$names" = "id,version," ]
}

@test "knit_register_setup installs before callback" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    local cmd
    cmd=$(__knit_command_mangle "setup:mysetup")
    local cb_content
    eval "cb_content=\"\${_KNIT_CMD_${cmd}_before_cb[*]}\""
    [[ "${cb_content}" == *__knit_setup_before_cb* ]]
}

@test "knit_register_setup installs after callback" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    local cmd
    cmd=$(__knit_command_mangle "setup:mysetup")
    local cb_content
    eval "cb_content=\"\${_KNIT_CMD_${cmd}_after_cb[*]}\""
    [[ "${cb_content}" == *__knit_setup_after_cb* ]]
}

# ---------- __knit_setup_before_cb ----------

@test "setup before callback fails when KNIT_SETUP_PREFIX is not set" {
    unset KNIT_SETUP_PREFIX
    run __knit_setup_before_cb
    [ "$status" -ne 0 ]
}

@test "setup before callback succeeds when KNIT_SETUP_PREFIX is set" {
    export KNIT_SETUP_PREFIX="/tmp"
    run __knit_setup_before_cb
    [ "$status" -eq 0 ]
}

# ---------- __knit_setup_after_cb ----------

@test "setup after callback creates .activate.sh in KNIT_SETUP_PREFIX" {
    export KNIT_SETUP_PREFIX="${__KNIT_TEST_TMPDIR}"
    __knit_setup_after_cb
    [ -f "${KNIT_SETUP_PREFIX}/.activate.sh" ]
}

@test "setup after callback makes .activate.sh executable" {
    export KNIT_SETUP_PREFIX="${__KNIT_TEST_TMPDIR}"
    __knit_setup_after_cb
    [ -x "${KNIT_SETUP_PREFIX}/.activate.sh" ]
}

@test "setup after callback writes exported variable to .activate.sh" {
    export KNIT_SETUP_PREFIX="${__KNIT_TEST_TMPDIR}"
    export _KNIT_TEST_CANARY="hello_world"
    __knit_setup_after_cb
    grep -q '_KNIT_TEST_CANARY' "${KNIT_SETUP_PREFIX}/.activate.sh"
}

@test "setup after callback excludes SHLVL from .activate.sh" {
    export KNIT_SETUP_PREFIX="${__KNIT_TEST_TMPDIR}"
    __knit_setup_after_cb
    ! grep -q '^export SHLVL=' "${KNIT_SETUP_PREFIX}/.activate.sh"
}

@test "setup after callback excludes KNIT_SETUP_PREFIX itself from .activate.sh" {
    export KNIT_SETUP_PREFIX="${__KNIT_TEST_TMPDIR}"
    __knit_setup_after_cb
    ! grep -q '^export KNIT_SETUP_PREFIX=' "${KNIT_SETUP_PREFIX}/.activate.sh"
}

# ---------- __knit_setup ----------

@test "__knit_setup fails if path already exists" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    local existing="${__KNIT_TEST_TMPDIR}/existing"
    mkdir -p "${existing}"
    run __knit_setup --path "${existing}" -- mysetup
    [ "$status" -ne 0 ]
}

@test "__knit_setup fails if setup name is not registered" {
    run __knit_setup --path "${__KNIT_TEST_TMPDIR}/newdir" -- unknownsetup
    [ "$status" -ne 0 ]
}

@test "__knit_setup fails if setup args are invalid" {
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    export KNIT_SETUP_PREFIX="${__KNIT_TEST_TMPDIR}/newdir"
    run __knit_setup --path "${__KNIT_TEST_TMPDIR}/newdir" -- mysetup --unknown-arg foo
    [ "$status" -ne 0 ]
}

@test "__knit_setup creates the directory on success" {
    local sentinel="${__KNIT_TEST_TMPDIR}/sentinel"
    local newdir="${__KNIT_TEST_TMPDIR}/newdir"
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    export KNIT_SETUP_PREFIX="${newdir}"
    __knit_setup --path "${newdir}" -- mysetup
    [ -d "${newdir}" ]
}

@test "__knit_setup sets KNIT_SETUP_PREFIX inside the setup function" {
    local newdir="${__KNIT_TEST_TMPDIR}/newdir"
    local prefix_file="${__KNIT_TEST_TMPDIR}/prefix.txt"
    _test_setup_fn() {
        printf '%s' "${KNIT_SETUP_PREFIX}" > "${prefix_file}"
    }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    __knit_setup --path "${newdir}" -- mysetup
    local captured
    captured=$(cat "${prefix_file}")
    [ "${captured}" = "${newdir}" ]
}

@test "__knit_setup actually invokes the setup function" {
    local newdir="${__KNIT_TEST_TMPDIR}/newdir"
    local sentinel="${__KNIT_TEST_TMPDIR}/sentinel"
    _test_setup_fn() {
        touch "${sentinel}"
    }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    __knit_setup --path "${newdir}" -- mysetup
    [ -f "${sentinel}" ]
}

@test "__knit_setup removes directory when setup function fails" {
    local newdir="${__KNIT_TEST_TMPDIR}/newdir"
    _test_setup_fn() { return 1; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    run __knit_setup --path "${newdir}" -- mysetup
    [ "$status" -ne 0 ]
    [ ! -d "${newdir}" ]
}

@test "__knit_setup creates .activate.sh after success" {
    local newdir="${__KNIT_TEST_TMPDIR}/newdir"
    _test_setup_fn() { :; }
    knit_register_setup "mysetup" "_test_setup_fn" "A test setup."
    knit_done
    __knit_setup --path "${newdir}" -- mysetup
    [ -f "${newdir}/.activate.sh" ]
}
