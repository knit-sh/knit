#!/usr/bin/env bats

# Tests for the shared GitHub tarball-download helpers (src/github.sh):
# _knit_github_api, _knit_github_resolve_commit, and _knit_github_download. These
# are parameterized on the repository owner (org) and take the framing callback
# as an argument, so they are reused by Spack provisioning and by plugin imports.

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit

    __TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${__TEST_TMPDIR}/fake-knit"
    mkdir -p "${_KNIT_PREFIX}"
    DEST="${__TEST_TMPDIR}/dest"
    _KNIT_IS_BOOTSTRAPPED="1"
}

teardown() {
    rm -rf "${__TEST_TMPDIR}"
    _KNIT_IS_BOOTSTRAPPED=""
}

# ---------- _knit_github_api ----------

@test "github_api sends no Authorization header when no token is set" {
    local GITHUB_TOKEN="" GH_TOKEN=""
    curl() { printf '%s\n' "$*"; }

    run _knit_github_api "https://api.github.com/x"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Authorization"* ]]
    [[ "$output" == *"https://api.github.com/x"* ]]
}

@test "github_api authenticates with GITHUB_TOKEN when set" {
    local GITHUB_TOKEN="tok123" GH_TOKEN=""
    curl() { printf '%s\n' "$*"; }

    run _knit_github_api "https://api.github.com/x"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Authorization: Bearer tok123"* ]]
}

@test "github_api falls back to GH_TOKEN when GITHUB_TOKEN is unset" {
    local GITHUB_TOKEN="" GH_TOKEN="ghtok"
    curl() { printf '%s\n' "$*"; }

    run _knit_github_api "https://api.github.com/x"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Authorization: Bearer ghtok"* ]]
}

# ---------- _knit_github_resolve_commit ----------

@test "resolve_commit returns the sha from the GitHub commits API" {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    curl() { printf '%s' '{"sha":"deadbeef"}'; }
    _knit_jq() { jq "$@"; }

    run _knit_github_resolve_commit myorg myrepo "v1.0"
    [ "$status" -eq 0 ]
    [ "$output" = "deadbeef" ]
}

@test "resolve_commit targets the owner/repo/ref in the API URL" {
    # Echo the requested URL straight through so we can assert its shape.
    _knit_github_api() { printf '%s' "$1"; }
    _knit_jq() { cat; }

    run _knit_github_resolve_commit myorg myrepo myref
    [ "$status" -eq 0 ]
    [ "$output" = "https://api.github.com/repos/myorg/myrepo/commits/myref" ]
}

@test "resolve_commit is fatal when the API returns no sha" {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    curl() { printf '%s' '{}'; }
    _knit_jq() { jq "$@"; }

    run _knit_github_resolve_commit myorg myrepo "nope"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not resolve"* ]]
}

# ---------- _knit_github_download ----------

@test "download curls the archive, extracts stripping one level, and returns the sha256" {
    local -a cmds=()
    local content="knit-plugin-tarball-bytes"
    # Framing callback: record each command and, for the download, write known
    # bytes to the "-o" target so the sha256 is deterministic.
    fake_framed() {
        shift   # drop the title
        cmds+=("$*")
        if [[ "$1" == curl ]]; then
            local out="" prev=""
            for a in "$@"; do
                [[ "${prev}" == "-o" ]] && out="${a}"
                prev="${a}"
            done
            [[ -n "${out}" ]] && printf '%s' "${content}" > "${out}"
        fi
        return 0
    }

    local sha256
    _knit_github_download sha256 fake_framed myorg myrepo "${DEST}" "abc123"

    # First call downloads archive/<sha>.tar.gz from the owner/repo.
    [[ "${cmds[0]}" == "curl -L -o "*"https://github.com/myorg/myrepo/archive/abc123.tar.gz" ]]
    # Second call extracts into the destination, stripping the top-level dir.
    [[ "${cmds[1]}" == tar\ -xzf\ *" -C ${DEST} --strip-components=1" ]]
    # The destination is created before extraction.
    [ -d "${DEST}" ]
    # The returned sha256 is the digest of the downloaded bytes.
    local expected
    expected="$(printf '%s' "${content}" | sha256sum)"
    expected="${expected%% *}"
    [ "${sha256}" = "${expected}" ]
}

@test "download is fatal when the download fails" {
    fail_framed() { return 1; }
    local sha256
    run _knit_github_download sha256 fail_framed myorg myrepo "${DEST}" "abc123"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not download"* ]]
}
