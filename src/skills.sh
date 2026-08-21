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
# @fn _knit_skills_harness_dir()
#
# Map a harness name to the base directory the skills and commands install into,
# relative to the current directory. The default (empty or "agents") is the
# cross-harness ".agents"; "claude" installs into ".claude". Any other value is
# fatal, listing the valid names.
#
# @param __knit_ret1 Name of the variable to hold the base directory.
# @param harness     Harness name from --harness ("" for the default).
# ------------------------------------------------------------------------------
_knit_skills_harness_dir() {
    local -n __knit_ret1=$1
    local harness="$2"
    case "${harness}" in
        ""|agents) __knit_ret1=".agents" ;;
        claude)    __knit_ret1=".claude" ;;
        *) knit_fatal "%s" \
            "Unknown harness '${harness}'. Valid: agents (default), claude." ;;
    esac
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
    if ! curl -sSL -o "${tarball}" "${url}"; then
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
# the knit repository and installs the skills and commands into the harness
# layout. The copy merges into any existing skills/commands directory (so other,
# non-knit skills there are preserved) and overwrites knit's own, which makes a
# re-install idempotent.
# ------------------------------------------------------------------------------
_knit_skills_install() {
    local harness ref
    harness="$(knit_get_parameter "harness" "$@")"
    ref="$(knit_get_parameter "ref" "$@")"
    [[ -z "${ref}" ]] && ref="${_KNIT_SKILLS_DEFAULT_REF}"

    local base
    _knit_skills_harness_dir base "${harness}"

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

    rm -rf "${scratch}"
    knit_info "%s" "Installed knit agent skills and commands into ${base}/."
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
    "Download knit's agent skills/commands and install them into a harness layout."
_knit_is_builtin
knit_usable_before_bootstrap
knit_with_optional "harness:string" "agents" \
    "Target harness: 'agents' (default) installs to .agents/, 'claude' to .claude/."
knit_with_optional "ref:string" "main" \
    "Git ref (branch, tag, or commit) of knit-sh/knit to install skills from."
knit_done
