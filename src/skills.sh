#!/bin/bash

## @file skills.sh

# ------------------------------------------------------------------------------
# @var _KNIT_SKILLS_REPO
#
# GitHub repository (org/repo) that serves the agent skills and commands tree
# under agent/. The install downloads this repository's archive.
# ------------------------------------------------------------------------------
declare -g _KNIT_SKILLS_REPO
_KNIT_SKILLS_REPO="knit-sh/knit"

# ------------------------------------------------------------------------------
# @var _KNIT_SKILLS_DEFAULT_REF
#
# Git ref the install resolves against when no --ref is given. This is the
# default branch, not the running knit version tag, because the agent/ tree on
# the default branch carries the most up-to-date skills (mirrors the profile
# store convention).
# ------------------------------------------------------------------------------
declare -g _KNIT_SKILLS_DEFAULT_REF
_KNIT_SKILLS_DEFAULT_REF="main"

# ------------------------------------------------------------------------------
# @fn _knit_skills_link_claude()
#
# Point Claude Code at the canonical ".agents" install by symlinking knit's items
# into ".claude/skills" and ".claude/commands", one entry at a time. The two
# containers are kept as real directories (created if missing, and an existing one
# --- even a symlink --- is left as is), so a project's own skills/commands and
# its ".claude/settings.json" live alongside the links rather than being replaced.
#
# Each immediate entry of ".agents/skills" (a skill directory) and
# ".agents/commands" (a command file) is symlinked into the matching container.
# The target is absolute (${PWD}/.agents/...) so the link is valid wherever the
# container physically lives --- in particular when the container is itself a
# symlink, where a relative target would resolve from the wrong place. An entry
# name already present is skipped with a warning rather than overwritten, so a
# user's own item is never clobbered; an entry that is already the exact link this
# would create is skipped silently, which makes a re-install idempotent.
# ------------------------------------------------------------------------------
_knit_skills_link_claude() {
    local sub container item name link target
    for sub in skills commands; do
        container=".claude/${sub}"
        # Keep the container a directory; never replace it. A non-directory in the
        # way (a real file, say) is left alone with a warning.
        if [[ -e "${container}" && ! -d "${container}" ]]; then
            knit_warning "%s" \
                "Not linking into ${container}: it exists and is not a directory."
            continue
        fi
        mkdir -p "${container}"
        # Symlink each installed item into the container. The glob stays literal
        # when the source directory is empty, so guard each match with -e.
        for item in ".agents/${sub}"/*; do
            [[ -e "${item}" ]] || continue
            name="${item##*/}"
            link="${container}/${name}"
            target="${PWD}/.agents/${sub}/${name}"
            if [[ -L "${link}" && "$(readlink "${link}")" == "${target}" ]]; then
                continue    # already linked by us: idempotent, no warning
            fi
            if [[ -e "${link}" || -L "${link}" ]]; then
                knit_warning "%s" \
                    "Not linking ${link}: an entry already exists there."
                continue
            fi
            ln -s "${target}" "${link}"
        done
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_skills_download()
#
# Download the knit repository at a ref as a tarball and extract it into the
# destination directory, so <dest>/agent/ holds the skills and commands. Uses
# curl and tar (as the sqlite/jq/spack provisioning does) so knit needs no git,
# and --strip-components=1 drops the archive's single "knit-<ref>/" top-level
# directory without having to resolve the ref to a commit first. GitHub serves
# any ref at archive/<ref>.tar.gz.
#
# @param dest Destination directory (already created by the caller).
# @param ref  Git ref (branch, tag, or commit SHA) to download.
# ------------------------------------------------------------------------------
_knit_skills_download() {
    local dest="$1"
    local ref="$2"
    local url="https://github.com/${_KNIT_SKILLS_REPO}/archive/${ref}.tar.gz"
    local tarball="${dest}/knit-${ref##*/}.tar.gz"
    knit_trace "Downloading knit ${ref} from ${url}..."
    # -f turns a rate-limited/error GitHub response into a clean failure rather
    # than a saved error body; --retry rides out a transient network error; a
    # GITHUB_TOKEN/GH_TOKEN, when set, lifts the anonymous rate limit CI shares.
    local -a curl_args=(-fsSL --retry 3 --retry-delay 2 -o "${tarball}")
    local gh_token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    [[ -n "${gh_token}" ]] && curl_args+=(-H "Authorization: Bearer ${gh_token}")
    if ! curl "${curl_args[@]}" "${url}"; then
        knit_fatal "%s" "Could not download knit ${ref} from ${url}."
    fi
    if ! tar -xzf "${tarball}" -C "${dest}" --strip-components=1 2>/dev/null; then
        knit_fatal "%s" "Could not extract the knit archive from ${url}."
    fi
    rm -f "${tarball}"
}

# ------------------------------------------------------------------------------
# @fn _knit_skills_install()
#
# Implementation of 'knit skills install'. Downloads the latest agent/ tree from
# the knit repository and installs the skills and commands into ".agents/", the
# canonical cross-harness location. The copy merges into any existing
# skills/commands directory (so other, non-knit skills there are preserved) and
# overwrites knit's own, which makes a re-install idempotent.
#
# With --claude, Claude Code is pointed at that same install by symlinking knit's
# skills and commands into ".claude" one item at a time (see
# _knit_skills_link_claude), so there is one real copy on disk, not a per-harness
# fork, and a project's own ".claude" items are left in place.
#
# It also drops the agent/AGENTS.md pointer at the project root so an agent
# orients itself even before a skill is loaded. An existing project AGENTS.md is
# never overwritten (it may hold the user's own notes); the pointer is written
# only when no AGENTS.md is present.
# ------------------------------------------------------------------------------
_knit_skills_install() {
    local ref claude
    ref="$(knit_get_parameter "ref" "$@")"
    [[ -z "${ref}" ]] && ref="${_KNIT_SKILLS_DEFAULT_REF}"
    claude="$(knit_get_parameter "claude" "$@")" || claude="false"

    local base=".agents"

    local scratch
    scratch="$(mktemp -d)" || knit_fatal "%s" \
        "Could not create a temporary directory for the download."

    _knit_skills_download "${scratch}" "${ref}"

    local src_skills="${scratch}/agent/skills"
    local src_commands="${scratch}/agent/commands"
    if [[ ! -d "${src_skills}" ]]; then
        rm -rf "${scratch}"
        knit_fatal "%s" \
            "The downloaded knit ${ref} has no agent/skills folder to install."
    fi

    mkdir -p "${base}/skills" "${base}/commands"
    cp -R "${src_skills}/." "${base}/skills/"
    [[ -d "${src_commands}" ]] && cp -R "${src_commands}/." "${base}/commands/"

    # Drop the AGENTS.md pointer at the project root, but never clobber one the
    # project already has.
    local src_agents="${scratch}/agent/AGENTS.md"
    if [[ -f "${src_agents}" && ! -e "AGENTS.md" ]]; then
        cp "${src_agents}" "AGENTS.md"
    fi

    rm -rf "${scratch}"
    knit_info "%s" "Installed knit agent skills and commands into ${base}/."

    if [[ "${claude}" == "true" ]]; then
        _knit_skills_link_claude
        knit_info "%s" "Linked knit skills and commands into .claude/."
    fi
}

# ------------------------------------------------------------------------------
# Registration of the skills command group.
# ------------------------------------------------------------------------------
knit_register skills knit_empty \
    "Install knit's agent skills and commands into an AI harness."
_knit_is_builtin
knit_usable_before_bootstrap
knit_done

knit_register "skills:install" _knit_skills_install \
    "Download knit's agent skills/commands from GitHub and install them into .agents/ (add --claude to also link .claude/ at it)."
_knit_is_builtin
knit_usable_before_bootstrap
knit_with_flag "claude" \
    "Also point Claude Code at the install by symlinking each skill and command into .claude/skills and .claude/commands."
knit_with_optional "ref:string" "main" \
    "Git ref (branch, tag, or commit) of knit-sh/knit to install skills from."
knit_done
