#!/bin/bash

## @file bundle.sh

# ------------------------------------------------------------------------------
# @var _KNIT_BUNDLE_REQUIRES
#
# Extra files the experiment needs but Knit does not otherwise track (a config
# file, a small input, a post-processing script). Each entry is a path string
# recorded verbatim by knit_bundle_requires, in declaration order. The paths are
# meant to be relative to the experiment script's directory; validation and glob
# expansion happen later, when "knit bundle" runs, not at declaration time.
# ------------------------------------------------------------------------------
declare -ga _KNIT_BUNDLE_REQUIRES
_KNIT_BUNDLE_REQUIRES=()

# ------------------------------------------------------------------------------
# @fn knit_bundle_requires()
#
# Declare an extra file, directory, or glob that "knit bundle" must add to the
# archive. Called at the top of an experiment script (like
# knit_set_program_description), not inside a knit_register/knit_done block. It
# describes the experiment as a whole, so it appends to the global
# _KNIT_BUNDLE_REQUIRES array rather than to any one command.
#
# The path is stored verbatim. This function MUST NOT touch the filesystem — no
# stat, no existence check, no knit_fatal. The experiment script is re-sourced on
# every invocation, including on a compute node that re-enters a job, so a
# declaration that failed on a missing or non-relocatable path would abort that
# re-entry and kill the job. All validation (path exists, path is relative, path
# stays inside the tree) and glob expansion are deferred to "knit bundle".
#
# @param[in] path A file, directory, or glob pattern, relative to the experiment
#                 script's directory.
# ------------------------------------------------------------------------------
knit_bundle_requires() {
    _KNIT_BUNDLE_REQUIRES+=("$1")
}

# ------------------------------------------------------------------------------
# @fn _knit_bundle_default_output()
#
# Compute the default archive path when the user gives no --output, and store it
# in the caller-named variable. The name is "./<project>-bundle" plus the format
# extension. The project name comes from the metadata table (key __project__); it
# falls back to the experiment script name without its ".sh" extension when the
# metadata holds no project. The extension is ".zip" for the zip format and
# ".tar.gz" otherwise.
#
# @param[out] __knit_ret Name of the variable to hold the default path.
# @param[in] fmt The archive format ("zip" or "tar").
# ------------------------------------------------------------------------------
_knit_bundle_default_output() {
    local -n __knit_ret=$1
    local fmt="$2"
    local project
    _knit_metadata_get project "__project__"
    [[ -z "${project}" ]] && project="${KNIT_SCRIPT_NAME%.sh}"
    local ext=".tar.gz"
    [[ "${fmt}" == "zip" ]] && ext=".zip"
    __knit_ret="./${project}-bundle${ext}"
}

# ------------------------------------------------------------------------------
# @fn _knit_bundle_collect()
#
# Fill a caller-named array with the archive contents, each as a path relative to
# the experiment root. This is the minimal default set: the experiment script,
# the knit.sh framework beside it, the pruned .knit directory (the database
# only), and the literal entries the user declared with knit_bundle_requires.
# Glob expansion, full tree collection, and the include/exclude filters are added
# in later milestones; this milestone adds the required entries verbatim.
#
# @param[out] __knit_ret Name of the array to fill with relative paths.
# @param[in] root The absolute experiment root.
# ------------------------------------------------------------------------------
_knit_bundle_collect() {
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n __knit_ret=$1; shift
    local root="$1"
    __knit_ret=()

    # The experiment script, relative to the root. The script normally sits at
    # the root, so this strips the root prefix to leave a bare file name.
    local script_rel="${KNIT_SCRIPT_PATH#"${root}/"}"
    [[ -n "${script_rel}" ]] && __knit_ret+=("${script_rel}")

    # The framework: knit.sh sits beside the script, so the experiment can source
    # it. The exact framework version must travel with the bundle.
    __knit_ret+=("knit.sh")

    # The pruned .knit: the provenance database only, not the provisioned tools.
    __knit_ret+=(".knit/knit.db")

    # The extra files the user declared. They are stored verbatim here; their
    # validation and glob expansion happen in a later milestone.
    local req
    for req in "${_KNIT_BUNDLE_REQUIRES[@]}"; do
        [[ -n "${req}" ]] && __knit_ret+=("${req}")
    done
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_bundle_prune_paths()
#
# Fill a caller-named array with the candidate paths that exist on disk, dropping
# the ones the archive writer cannot pack. Each candidate is a path relative to
# the experiment root. A symlink whose target cannot be reached — a dangling link
# or a symlink loop — is skipped with a warning, so the writer neither packs a
# link that dangles on the reproducer's machine nor spins on a loop. A path that
# is simply absent is skipped with a warning too. Every surviving path is kept in
# the given order.
#
# @param[out] __knit_ret Name of the array to fill with the surviving paths.
# @param[in] root The absolute experiment root.
# @param[in] ... The candidate relative paths.
# ------------------------------------------------------------------------------
_knit_bundle_prune_paths() {
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n __knit_ret=$1; shift
    local root="$1"; shift
    __knit_ret=()
    local rel abs
    for rel in "$@"; do
        [[ -z "${rel}" ]] && continue
        abs="${root}/${rel}"
        # A symlink that lstat sees but stat cannot resolve is broken or loops:
        # -L is true (it is a link) while -e is false (the target is unreachable).
        if [[ -L "${abs}" && ! -e "${abs}" ]]; then
            knit_warning "bundle: skipping broken or looping symlink \"%s\"." "${rel}"
            continue
        fi
        if [[ ! -e "${abs}" ]]; then
            knit_warning "bundle: skipping missing path \"%s\"." "${rel}"
            continue
        fi
        __knit_ret+=("${rel}")
    done
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_bundle_write_archive()
#
# Write the archive from a list of paths, each relative to the experiment root,
# so the archive unpacks to the same relative tree anywhere. Symlinks are
# dereferenced: the target content travels in the archive, not the link, so the
# result is self-contained and relocatable. The tar format uses "-h" for this;
# the zip format dereferences by default (it stores the referenced file unless
# "-y" is given). The tar path reads the file list from a temporary file so a
# long list does not hit the command-line length limit; the zip path changes into
# the root first, because zip has no "-C" option.
#
# @param[in] fmt The archive format ("zip" or "tar").
# @param[in] output The archive path to write.
# @param[in] root The absolute experiment root.
# @param[in] ... The relative paths to pack.
# @return Fatal when the archive tool is missing, no path is given, or the write
#         fails; otherwise 0.
# ------------------------------------------------------------------------------
_knit_bundle_write_archive() {
    local fmt="$1" output="$2" root="$3"; shift 3
    local -a rels=("$@")
    (( ${#rels[@]} == 0 )) && knit_fatal "bundle: nothing to pack."

    if [[ "${fmt}" == "zip" ]]; then
        command -v zip &>/dev/null \
            || knit_fatal "bundle: 'zip' is required for --zip but was not found on PATH."
        # zip has no working-directory option, so resolve the output to an
        # absolute path before changing into the root, and remove any existing
        # archive first (zip would otherwise merge into it).
        local abs_out
        abs_out="$(realpath -m -- "${output}")"
        rm -f -- "${abs_out}"
        # zip rejects "--" before the archive name; abs_out is an absolute path
        # from realpath, so it never looks like an option.
        ( cd "${root}" && zip -q -r "${abs_out}" "${rels[@]}" ) \
            || knit_fatal "bundle: failed to write \"%s\"." "${output}"
    else
        command -v tar &>/dev/null \
            || knit_fatal "bundle: 'tar' is required but was not found on PATH."
        local listfile
        listfile="$(mktemp)"
        printf '%s\n' "${rels[@]}" > "${listfile}"
        if ! tar -czhf "${output}" -C "${root}" -T "${listfile}"; then
            rm -f -- "${listfile}"
            knit_fatal "bundle: failed to write \"%s\"." "${output}"
        fi
        rm -f -- "${listfile}"
    fi
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_bundle()
#
# Body of "knit bundle": pack the experiment into one shippable archive. It reads
# the --output and --zip options, resolves the experiment root, computes the
# default output path when none is given, collects the minimal default contents,
# drops any path the writer cannot pack, and writes the archive. The command is
# read-only: it declares no table and takes knit_without_provenance, so it records
# no row and writes no provenance edge.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_bundle() {
    local output zip_flag
    output="$(knit_get_parameter "output" "$@")"   || output=""
    zip_flag="$(knit_get_parameter "zip" "$@")"     || zip_flag="false"

    local fmt="tar"
    [[ "${zip_flag}" == "true" ]] && fmt="zip"

    local root
    _knit_experiment_root root

    [[ -z "${output}" ]] && _knit_bundle_default_output output "${fmt}"

    local -a candidates=()
    _knit_bundle_collect candidates "${root}"

    local -a paths=()
    _knit_bundle_prune_paths paths "${root}" "${candidates[@]}"

    _knit_bundle_write_archive "${fmt}" "${output}" "${root}" "${paths[@]}"

    knit_info "Wrote bundle to %s" "${output}"
}

# ------------------------------------------------------------------------------
# Registration of the bundle command. It needs a bootstrapped experiment (it
# reads .knit/knit.db), so it is NOT marked knit_usable_before_bootstrap and the
# central runtime guard refuses it until bootstrap. It records nothing: it
# declares no table and takes knit_without_provenance.
# ------------------------------------------------------------------------------
knit_register "bundle" _knit_bundle \
    "Pack the experiment into one shippable archive."
_knit_is_builtin
knit_without_provenance
knit_with_optional "output:path" "" \
    "Archive path (default ./<project>-bundle.tar.gz, or .zip with --zip)."
knit_with_flag "zip" \
    "Write a .zip archive instead of .tar.gz."
knit_done
