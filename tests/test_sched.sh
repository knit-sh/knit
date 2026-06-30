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
    _KNIT_IS_BOOTSTRAPPED=""
}

# ---------- _knit_uuidv7 ----------

@test "_knit_uuidv7 produces a value of the uuid type" {
    local u
    u="$(_knit_uuidv7)"
    knit_type_check "uuid" "${u}"
}

@test "_knit_uuidv7 sets the version nibble to 7" {
    local u
    u="$(_knit_uuidv7)"
    [ "${u:14:1}" = "7" ]
}

@test "_knit_uuidv7 sets the variant nibble to one of 8,9,a,b" {
    local u
    u="$(_knit_uuidv7)"
    [[ "${u:19:1}" =~ ^[89ab]$ ]]
}

@test "_knit_uuidv7 produces distinct values" {
    local a b
    a="$(_knit_uuidv7)"
    b="$(_knit_uuidv7)"
    [ "${a}" != "${b}" ]
}

@test "_knit_uuidv7 values are lexically time-ordered" {
    local a b
    a="$(_knit_uuidv7)"
    sleep 0.01
    b="$(_knit_uuidv7)"
    [[ "${a}" < "${b}" ]]
}

# ---------- __knit_submit job directory creation ----------

@test "__knit_submit creates <setup>/jobs/<uuid> directory" {
    local setup_dir="${__KNIT_TEST_TMPDIR}/setup"
    mkdir -p "${setup_dir}"
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done

    __knit_submit --setup "${setup_dir}" -- myjob

    [ -d "${setup_dir}/jobs" ]
    local count
    count=$(find "${setup_dir}/jobs" -mindepth 1 -maxdepth 1 -type d | wc -l)
    [ "${count}" -eq 1 ]
}

@test "__knit_submit job directory name is a valid uuid" {
    local setup_dir="${__KNIT_TEST_TMPDIR}/setup"
    mkdir -p "${setup_dir}"
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done

    __knit_submit --setup "${setup_dir}" -- myjob

    local name
    name=$(find "${setup_dir}/jobs" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
    knit_type_check "uuid" "${name}"
}
