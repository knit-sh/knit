#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit

    # Install lands in the current directory (.agents/, plus .claude/ links with
    # --claude); run every test inside an isolated tmpdir so nothing touches the
    # repo.
    _KNIT_TEST_TMPDIR="$(mktemp -d)"
    cd "${_KNIT_TEST_TMPDIR}" || return 1

    # Stub the network primitive: instead of downloading from GitHub, lay down a
    # fake agent/ tree into the scratch dir and record the ref it was asked for.
    # shellcheck disable=SC2317 # invoked indirectly after redefinition
    _knit_skills_download() {
        local dest="$1"
        local ref="$2"
        printf '%s' "${ref}" > "${_KNIT_TEST_TMPDIR}/last_ref"
        mkdir -p "${dest}/agent/skills/using-knit" \
                 "${dest}/agent/skills/writing-a-profile/validate" \
                 "${dest}/agent/commands"
        printf 'SKILL\n' > "${dest}/agent/skills/using-knit/SKILL.md"
        printf 'SKILL\n' > "${dest}/agent/skills/writing-a-profile/SKILL.md"
        printf 'CHECK\n' > "${dest}/agent/skills/writing-a-profile/validate/check.sh"
        printf 'CMD\n'   > "${dest}/agent/commands/knit-profile.md"
        printf 'CMD\n'   > "${dest}/agent/commands/knit-analyze.md"
        printf 'POINTER\n' > "${dest}/agent/AGENTS.md"
    }
}

teardown() {
    cd / || true
    rm -rf "${_KNIT_TEST_TMPDIR}"
}

# --- install ------------------------------------------------------------------

@test "install: target is .agents/ with skills and commands, no .claude by default" {
    run knit skills install
    [ "${status}" -eq 0 ]
    [ -f ".agents/skills/using-knit/SKILL.md" ]
    [ -f ".agents/commands/knit-profile.md" ]
    [ ! -e ".claude" ]
}

@test "install: --claude keeps .claude/{skills,commands} real and links items in" {
    run knit skills install --claude
    [ "${status}" -eq 0 ]
    # The containers are real directories, not symlinks.
    [ -d ".claude/skills" ] && [ ! -L ".claude/skills" ]
    [ -d ".claude/commands" ] && [ ! -L ".claude/commands" ]
    # Each knit item is an individual symlink with an absolute target...
    [ -L ".claude/skills/using-knit" ]
    [ "$(readlink ".claude/skills/using-knit")" = "${PWD}/.agents/skills/using-knit" ]
    [ -L ".claude/commands/knit-profile.md" ]
    [ "$(readlink ".claude/commands/knit-profile.md")" = "${PWD}/.agents/commands/knit-profile.md" ]
    # ... that resolves through to the .agents copy, bundled files included.
    [ -f ".claude/skills/using-knit/SKILL.md" ]
    [ -f ".claude/skills/writing-a-profile/validate/check.sh" ]
    [ -f ".claude/commands/knit-analyze.md" ]
}

@test "install: --claude is idempotent and quiet on re-run" {
    run knit skills install --claude
    [ "${status}" -eq 0 ]
    run knit skills install --claude
    [ "${status}" -eq 0 ]
    [ -L ".claude/skills/using-knit" ]
    [ "$(readlink ".claude/skills/using-knit")" = "${PWD}/.agents/skills/using-knit" ]
    # Our own links are skipped silently, so a re-run warns about nothing.
    [[ "${output}" != *"Not linking"* ]]
}

@test "install: --claude keeps a user's own item and skips a name clash with a warning" {
    mkdir -p ".claude/skills/mytool" ".claude/skills/using-knit"
    printf 'MINE\n' > ".claude/skills/mytool/SKILL.md"
    printf 'MINE\n' > ".claude/skills/using-knit/SKILL.md"   # clashes with a knit skill
    printf 'settings\n' > ".claude/settings.json"
    run knit skills install --claude
    [ "${status}" -eq 0 ]
    # The user's unrelated skill and their settings are untouched.
    [ "$(cat ".claude/skills/mytool/SKILL.md")" = "MINE" ]
    [ "$(cat ".claude/settings.json")" = "settings" ]
    # The name clash is preserved (still a real dir with the user's content) and warned.
    [ ! -L ".claude/skills/using-knit" ]
    [ "$(cat ".claude/skills/using-knit/SKILL.md")" = "MINE" ]
    [[ "${output}" == *"Not linking .claude/skills/using-knit"* ]]
    # A non-clashing knit skill is still linked in alongside.
    [ -L ".claude/skills/writing-a-profile" ]
}

@test "install: --claude honors an existing .claude/skills symlink container" {
    mkdir -p ".claude" "external-skills"
    ln -s "../external-skills" ".claude/skills"   # container is itself a symlink
    run knit skills install --claude
    [ "${status}" -eq 0 ]
    # The container symlink is kept as is; items are linked into its target.
    [ -L ".claude/skills" ]
    [ -e "external-skills/using-knit" ]
    [ -f ".claude/skills/using-knit/SKILL.md" ]
}

@test "install: preserves an unrelated skill already present (merge, not wipe)" {
    mkdir -p ".agents/skills/graphify"
    printf 'keep\n' > ".agents/skills/graphify/SKILL.md"
    run knit skills install
    [ "${status}" -eq 0 ]
    [ -f ".agents/skills/graphify/SKILL.md" ]
    [ -f ".agents/skills/using-knit/SKILL.md" ]
}

@test "install: drops the AGENTS.md pointer at the project root" {
    run knit skills install
    [ "${status}" -eq 0 ]
    [ -f "AGENTS.md" ]
    [ "$(cat AGENTS.md)" = "POINTER" ]
}

@test "install: never overwrites an existing project AGENTS.md" {
    printf 'MINE\n' > "AGENTS.md"
    run knit skills install
    [ "${status}" -eq 0 ]
    [ "$(cat AGENTS.md)" = "MINE" ]
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
