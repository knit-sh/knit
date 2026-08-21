#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit

    # Install lands in the current directory (.agents/ or .claude/); run every
    # test inside an isolated tmpdir so nothing touches the repo.
    _KNIT_TEST_TMPDIR="$(mktemp -d)"
    cd "${_KNIT_TEST_TMPDIR}" || return 1

    # Stub the network primitive: instead of downloading from GitHub, lay down a
    # fake agent/ tree into the scratch dir and record the ref it was asked for.
    # shellcheck disable=SC2317 # invoked indirectly after redefinition
    _knit_skills_download() {
        local dest="$1"
        local ref="$2"
        printf '%s' "${ref}" > "${_KNIT_TEST_TMPDIR}/last_ref"
        mkdir -p "${dest}/agent/skills/using-knit" "${dest}/agent/commands"
        printf 'SKILL\n' > "${dest}/agent/skills/using-knit/SKILL.md"
        printf 'CMD\n'   > "${dest}/agent/commands/knit-profile.md"
    }
}

teardown() {
    cd / || true
    rm -rf "${_KNIT_TEST_TMPDIR}"
}

# --- harness -> directory mapping --------------------------------------------

@test "harness_dir: default and 'agents' map to .agents" {
    local d
    _knit_skills_harness_dir d ""
    [ "${d}" = ".agents" ]
    _knit_skills_harness_dir d "agents"
    [ "${d}" = ".agents" ]
}

@test "harness_dir: 'claude' maps to .claude" {
    local d
    _knit_skills_harness_dir d "claude"
    [ "${d}" = ".claude" ]
}

@test "harness_dir: unknown harness is fatal" {
    run _knit_skills_harness_dir d "bogus"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Unknown harness 'bogus'"* ]]
}

# --- install ------------------------------------------------------------------

@test "install: default target is .agents/ with skills and commands" {
    run knit skills install
    [ "${status}" -eq 0 ]
    [ -f ".agents/skills/using-knit/SKILL.md" ]
    [ -f ".agents/commands/knit-profile.md" ]
}

@test "install: --harness claude targets .claude/" {
    run knit skills install --harness claude
    [ "${status}" -eq 0 ]
    [ -f ".claude/skills/using-knit/SKILL.md" ]
    [ -f ".claude/commands/knit-profile.md" ]
    [ ! -d ".agents" ]
}

@test "install: preserves an unrelated skill already present (merge, not wipe)" {
    mkdir -p ".claude/skills/graphify"
    printf 'keep\n' > ".claude/skills/graphify/SKILL.md"
    run knit skills install --harness claude
    [ "${status}" -eq 0 ]
    [ -f ".claude/skills/graphify/SKILL.md" ]
    [ -f ".claude/skills/using-knit/SKILL.md" ]
}

@test "install: re-install is idempotent" {
    run knit skills install
    [ "${status}" -eq 0 ]
    run knit skills install
    [ "${status}" -eq 0 ]
    [ -f ".agents/skills/using-knit/SKILL.md" ]
}

@test "install: default ref is main; --ref is forwarded to the download" {
    run knit skills install
    [ "${status}" -eq 0 ]
    [ "$(cat "${_KNIT_TEST_TMPDIR}/last_ref")" = "main" ]

    run knit skills install --ref v1.2.3
    [ "${status}" -eq 0 ]
    [ "$(cat "${_KNIT_TEST_TMPDIR}/last_ref")" = "v1.2.3" ]
}

@test "install: fatal when the download has no agent/skills folder" {
    # shellcheck disable=SC2317 # invoked indirectly after redefinition
    _knit_skills_download() { mkdir -p "$1/agent"; }
    run knit skills install
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no agent/skills folder"* ]]
}
