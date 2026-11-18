#!/usr/bin/env bats

# Focused coverage for _knit_drain_release_next's re-entry cwd. A drain run from
# inside a pilot job body executes with the cwd set to that job's directory, so
# the experiment it re-executes must still be able to resolve a bare
# `source knit.sh`. _knit_drain_release_next therefore re-enters from the
# directory holding the experiment script, regardless of the caller's cwd.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    _KNIT_TEST_TMPDIR="$(mktemp -d)"
    # A fake experiment script that, for `submit next`, prints the cwd it ran in
    # (standing in for the released job UUID) and, for `job wait`, records the cwd
    # to a file. It lives in its own directory so "ran from the script's dir" is
    # distinguishable from "ran from the caller's cwd".
    _SCRIPT_DIR="${_KNIT_TEST_TMPDIR}/exp"
    mkdir -p "${_SCRIPT_DIR}"
    _KNIT_SCRIPT_PATH="${_SCRIPT_DIR}/exp.sh"
    cat > "${_KNIT_SCRIPT_PATH}" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2" == "submit next" ]]; then
    pwd
elif [[ "\$1" == "job" && "\$2" == "wait" ]]; then
    pwd > "${_KNIT_TEST_TMPDIR}/wait.cwd"
fi
EOF
    chmod +x "${_KNIT_SCRIPT_PATH}"
    # A separate directory to run from, standing in for a pilot job's directory.
    _CALLER_DIR="${_KNIT_TEST_TMPDIR}/jobdir"
    mkdir -p "${_CALLER_DIR}"
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    knit_test_db_teardown
}

@test "release re-enters submit next from the experiment script's directory" {
    local out
    out="$(cd "${_CALLER_DIR}" && _knit_drain_release_next false)"
    # The fake script printed the cwd it ran in; it must be the script's dir, not
    # the caller's dir.
    [ "${out}" = "${_SCRIPT_DIR}" ]
}

@test "release re-enters job wait from the experiment script's directory" {
    cd "${_CALLER_DIR}"
    _knit_drain_release_next true >/dev/null
    [ "$(cat "${_KNIT_TEST_TMPDIR}/wait.cwd")" = "${_SCRIPT_DIR}" ]
}
