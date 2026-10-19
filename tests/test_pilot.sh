#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit

    # Each test controls _KNIT_PREFIX explicitly; point it at a temp path.
    __TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${__TEST_TMPDIR}/fake-knit"
}

teardown() {
    rm -rf "${__TEST_TMPDIR}"
}

# Marker written by the stubbed build (records the version/url it was built with).
__pilotd_build_marker=""
# File capturing the (stubbed) "knit metadata store" provenance calls.
__pilotd_meta=""

# Stub the network+compiler build and capture the metadata calls so the
# provisioning logic (version/url resolution, provenance recording) can be
# exercised without downloading or compiling anything.
_setup_pilotd_decision() {
    mkdir "${_KNIT_PREFIX}"
    _KNIT_PILOTD_EXE="${_KNIT_PREFIX}/knit-pilotd/bin/knit-pilotd"
    __pilotd_build_marker="${__TEST_TMPDIR}/pilotd-built"
    __pilotd_meta="${__TEST_TMPDIR}/pilotd-meta"
    : > "${__pilotd_meta}"
    eval '_knit_build_pilotd() { printf "%s\n" "$*" > "'"${__pilotd_build_marker}"'"; }'
    eval 'knit() { printf "%s\n" "$*" >> "'"${__pilotd_meta}"'"; }'
}

# ---------- _KNIT_PILOTD_EXE ----------

# _KNIT_PILOTD_EXE is frozen from _KNIT_PREFIX when the source is loaded, so the
# stable invariant is its install layout under a "knit-pilotd" prefix directory,
# not the exact prefix (which setup() resets only after sourcing).
@test "the knit-pilotd executable lives under a knit-pilotd prefix directory" {
    [[ "${_KNIT_PILOTD_EXE}" == */knit-pilotd/bin/knit-pilotd ]]
}

# ---------- _knit_pilotd_url ----------

@test "knit-pilotd url is derived from the version" {
    run _knit_pilotd_url "0.1.0"
    [ "$status" -eq 0 ]
    [ "$output" = "https://github.com/knit-sh/knit-pilotd/releases/download/v0.1.0/knit-pilotd-0.1.0.tar.gz" ]
}

# ---------- _knit_bootstrap_pilotd ----------

@test "bootstrap knit-pilotd builds the pinned default version and records provenance" {
    _setup_pilotd_decision

    _knit_bootstrap_pilotd

    # Built with the pinned version and its derived url.
    grep -q "${_KNIT_PILOTD_VERSION}" "${__pilotd_build_marker}"
    grep -q "knit-pilotd-${_KNIT_PILOTD_VERSION}.tar.gz" "${__pilotd_build_marker}"
    # Provenance recorded (version + url).
    grep -q "metadata store --key __knit_pilotd_version__ --value ${_KNIT_PILOTD_VERSION}" "${__pilotd_meta}"
    grep -q "metadata store --key __knit_pilotd_url__ --value https://github.com/knit-sh/knit-pilotd/releases/download/v${_KNIT_PILOTD_VERSION}/knit-pilotd-${_KNIT_PILOTD_VERSION}.tar.gz" "${__pilotd_meta}"
}

@test "bootstrap knit-pilotd honours an explicit version" {
    _setup_pilotd_decision

    _knit_bootstrap_pilotd "9.9.9"

    grep -q "9.9.9" "${__pilotd_build_marker}"
    grep -q "metadata store --key __knit_pilotd_version__ --value 9.9.9" "${__pilotd_meta}"
    grep -q "download/v9.9.9/knit-pilotd-9.9.9.tar.gz" "${__pilotd_meta}"
}

@test "bootstrap knit-pilotd honours an explicit url override" {
    _setup_pilotd_decision

    _knit_bootstrap_pilotd "1.2.3" "https://example.com/pilotd.tgz"

    grep -q "https://example.com/pilotd.tgz" "${__pilotd_build_marker}"
    grep -q "metadata store --key __knit_pilotd_version__ --value 1.2.3" "${__pilotd_meta}"
    grep -q "metadata store --key __knit_pilotd_url__ --value https://example.com/pilotd.tgz" "${__pilotd_meta}"
}
