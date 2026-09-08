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
# @var _KNIT_BUNDLE_AUTO_REQUIRES
#
# Extra files Knit itself knows the experiment needs and adds without the user
# asking — currently the spack.yaml a setup names through knit_with_spack_env in
# its file form. Each entry is a path string recorded verbatim, in declaration
# order. Unlike _KNIT_BUNDLE_REQUIRES (the user's own list, validated strictly),
# these are handled leniently at bundle time: a path outside the tree draws a
# warning and is normalized rather than a fatal, since the user did not type it.
# ------------------------------------------------------------------------------
declare -ga _KNIT_BUNDLE_AUTO_REQUIRES
_KNIT_BUNDLE_AUTO_REQUIRES=()

# ------------------------------------------------------------------------------
# @var _KNIT_BUNDLE_EXTERN
#
# Maps a normalized in-archive relative path to the absolute on-disk source it
# stands for, for content that lives outside the experiment tree: an absolute
# stored root (a setup/job/artifact/resource root bootstrapped as an absolute
# path) or an auto-required file outside the tree. The key is where the content
# lands in the archive; the value is where its bytes really are. Collection fills
# it; the prune, dry-run, and write steps consult it (by prefix) to find the real
# source of a collected path. Reset at the start of every "knit bundle".
# ------------------------------------------------------------------------------
declare -gA _KNIT_BUNDLE_EXTERN
_KNIT_BUNDLE_EXTERN=()

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
# @fn _knit_bundle_auto_require()
#
# Record a path that Knit adds to the bundle on the experiment's behalf (see
# _KNIT_BUNDLE_AUTO_REQUIRES). Called by other directives — knit_with_spack_env
# in its file form — not by the user. Like knit_bundle_requires it stores the
# string verbatim and MUST NOT touch the filesystem, so it stays safe when the
# experiment script is re-sourced on a compute node during job re-entry.
#
# @param[in] path A file path, meant relative to the experiment script's directory.
# ------------------------------------------------------------------------------
_knit_bundle_auto_require() {
    _KNIT_BUNDLE_AUTO_REQUIRES+=("$1")
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
# @fn _knit_bundle_relpath()
#
# Store, in the caller-named variable, an absolute path expressed relative to the
# experiment root. A path under the root has its "<root>/" prefix stripped, so it
# lands at the same place when the archive is unpacked.
#
# A path outside the root is a portability hazard: a stored root (setup, job,
# artifact, or resource) that was bootstrapped as an absolute path does not
# relocate with the archive. When a canonical fallback name is given, the path is
# packed under that normalized relative name instead: a warning is emitted, the
# real absolute source is recorded in _KNIT_BUNDLE_EXTERN (so the prune, dry-run,
# and write steps can find its bytes), and the fallback name is returned. Without
# a fallback the outside path is returned unchanged.
#
# @param[out] __knit_ret Name of the variable to hold the relative path.
# @param[in] root The absolute experiment root.
# @param[in] abs The absolute path to make relative.
# @param[in] canonical Optional normalized relative name for an outside path.
# ------------------------------------------------------------------------------
_knit_bundle_relpath() {
    local -n __knit_ret=$1
    local root="$2" abs="$3" canonical="${4:-}"
    if [[ "${abs}" == "${root}/"* ]]; then
        __knit_ret="${abs#"${root}/"}"
    elif [[ -n "${canonical}" ]]; then
        knit_warning "bundle: \"%s\" is outside the experiment tree and will not relocate; packing it under \"%s\"." \
            "${abs}" "${canonical}"
        _KNIT_BUNDLE_EXTERN["${canonical}"]="${abs}"
        __knit_ret="${canonical}"
    else
        __knit_ret="${abs}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_bundle_source()
#
# Store, in the caller-named variable, the real on-disk source of a collected
# relative path. For an ordinary in-tree path this is "<root>/<rel>". For a path
# that stands for out-of-tree content (its prefix is a key in _KNIT_BUNDLE_EXTERN)
# it is the recorded absolute source with the matching prefix swapped back in, so
# the bytes are found where they really live. Used by prune, the dry-run size
# report, and the archive writer.
#
# @param[out] __knit_ret Name of the variable to hold the absolute source path.
# @param[in] root The absolute experiment root.
# @param[in] rel The collected relative path.
# ------------------------------------------------------------------------------
_knit_bundle_source() {
    local -n __knit_ret=$1
    local root="$2" rel="$3"
    local k
    for k in "${!_KNIT_BUNDLE_EXTERN[@]}"; do
        if [[ "${rel}" == "${k}" || "${rel}" == "${k}/"* ]]; then
            __knit_ret="${_KNIT_BUNDLE_EXTERN[${k}]}${rel#"${k}"}"
            return 0
        fi
    done
    __knit_ret="${root}/${rel}"
}

# ------------------------------------------------------------------------------
# @fn _knit_bundle_is_glob()
#
# Test whether a path string is a glob pattern, i.e. it holds an unescaped
# pathname-expansion metacharacter ("*", "?", or "[").
#
# @param[in] path The path string to test.
# @return 0 if the string is a glob pattern, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_bundle_is_glob() {
    [[ "$1" == *[\*\?\[]* ]]
}

# ------------------------------------------------------------------------------
# @fn _knit_bundle_escapes_root()
#
# Test whether a relative path escapes its root, i.e. a ".." component takes it
# above the starting directory. Pure string logic (no filesystem): it walks the
# components, treating "." and empty as no-ops, and reports an escape as soon as
# the depth would go negative.
#
# @param[in] path The relative path to test.
# @return 0 if the path escapes the root, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_bundle_escapes_root() {
    local path="$1"
    local -a comps
    IFS='/' read -r -a comps <<< "${path}"
    local depth=0 c
    for c in "${comps[@]}"; do
        case "${c}" in
            ''|.) ;;
            ..)
                depth=$(( depth - 1 ))
                (( depth < 0 )) && return 0
                ;;
            *) depth=$(( depth + 1 )) ;;
        esac
    done
    return 1
}

# ------------------------------------------------------------------------------
# @fn _knit_bundle_expand_requires()
#
# Fill a caller-named array with the archive-relative paths from a list of
# required entries (see knit_bundle_requires), validating and expanding each one.
# Every entry is meant relative to the experiment root. A glob pattern is expanded
# with pathname expansion relative to the root; every match is added and a pattern
# that matches nothing draws a warning. A literal entry is added as-is.
#
# The strict flag chooses how a portability problem is handled. In strict mode
# (the user's own knit_bundle_requires list) an absolute path, a ".." escape, and
# a missing literal are each a fatal that names the offending path, since the user
# typed it and can fix it. In lenient mode (paths Knit auto-required on the
# experiment's behalf) the same problems draw a warning instead: an absolute path
# is normalized under its basename (its real source recorded in the extern map, so
# its bytes still travel), and an escape or a missing literal is skipped.
#
# @param[out] __knit_ret Name of the array to fill with relative paths.
# @param[in] root The absolute experiment root.
# @param[in] strict "true" to fatal on a bad path, "false" to warn and continue.
# @param[in] ... The required entries.
# ------------------------------------------------------------------------------
_knit_bundle_expand_requires() {
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n __knit_ret=$1; shift
    local root="$1" strict="$2"; shift 2
    __knit_ret=()
    local req abs base
    local -a matches
    for req in "$@"; do
        [[ -z "${req}" ]] && continue

        if [[ "${req}" == /* ]]; then
            if [[ "${strict}" == "true" ]]; then
                knit_fatal "bundle: required path \"%s\" is absolute; give a path relative to the experiment root." "${req}"
            fi
            # Lenient: pack the absolute file under its basename so its bytes still
            # travel, recording the real source in the extern map.
            base="${req##*/}"
            knit_warning "bundle: required path \"%s\" is outside the experiment tree; packing it under \"%s\"." \
                "${req}" "${base}"
            _KNIT_BUNDLE_EXTERN["${base}"]="${req}"
            __knit_ret+=("${base}")
            continue
        fi

        if _knit_bundle_escapes_root "${req}"; then
            if [[ "${strict}" == "true" ]]; then
                knit_fatal "bundle: required path \"%s\" escapes the experiment tree." "${req}"
            fi
            knit_warning "bundle: skipping required path \"%s\" (it escapes the experiment tree)." "${req}"
            continue
        fi

        if _knit_bundle_is_glob "${req}"; then
            # Expand the pattern relative to the root. compgen -G matches paths in
            # the current directory, so run it from the root in a subshell and keep
            # the results relative.
            matches=()
            local m
            while IFS= read -r m; do
                [[ -n "${m}" ]] && matches+=("${m}")
            done < <(cd "${root}" 2>/dev/null && compgen -G "${req}")
            if (( ${#matches[@]} == 0 )); then
                knit_warning "bundle: required pattern \"%s\" matched nothing." "${req}"
            else
                __knit_ret+=("${matches[@]}")
            fi
            continue
        fi

        # A literal path must exist. lstat (-e or -L) is enough: a broken symlink is
        # a real declared entry and is reported later, by the prune step.
        abs="${root}/${req}"
        if [[ ! -e "${abs}" && ! -L "${abs}" ]]; then
            if [[ "${strict}" == "true" ]]; then
                knit_fatal "bundle: required path \"%s\" does not exist." "${req}"
            fi
            knit_warning "bundle: skipping required path \"%s\" (it does not exist)." "${req}"
            continue
        fi
        __knit_ret+=("${req}")
    done
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_bundle_collect()
#
# Fill a caller-named array with the archive contents, each as a path relative to
# the experiment root. The default set carries what makes the experiment readable
# and re-runnable: the experiment script, the knit.sh framework beside it, the
# pruned .knit directory (the database only), the user-declared required files,
# each setup's small manifest files, each job's logs and scripts, and the declared
# artifacts. It leaves out the bulky, regenerable parts: the provisioned tools
# under .knit, each setup's built environment, and the fetched resources.
#
# The options nameref selects what to include. Each key holds "true"/"false"
# except include_resources, which holds a comma-separated resource-name list:
#   - no_knit              drop the knit.sh framework file;
#   - no_db                drop .knit/knit.db;
#   - no_job_logs          drop each job's .stdout / .stderr;
#   - no_job_scripts       drop each job's .job.sh / .job.id;
#   - include_job_content  also pack the user content of each job directory;
#   - no_artifacts         drop the artifacts tree;
#   - include_all_resources  pack every fetched resource;
#   - include_resources    pack the named fetched resources.
#
# The experiment script, knit.sh, .knit/knit.db, and the user-declared required
# files are added unconditionally, so a later prune step can warn about a missing
# one. Every framework-enumerated path (setup, job, artifact, resource) is added
# only when it exists on disk (a regular path or a symlink, even a broken one), so
# an absent optional manifest — a non-Spack setup has no spack.yaml, say — is
# skipped silently rather than warned about. Glob expansion of the required
# entries and the portability validations come in a later milestone.
#
# @param[out] __knit_ret Name of the array to fill with relative paths.
# @param[in] opts Name of an associative array of include/exclude options.
# @param[in] root The absolute experiment root.
# ------------------------------------------------------------------------------
_knit_bundle_collect() {
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n __knit_ret=$1; shift
    # shellcheck disable=SC2178 # nameref to the caller's options array
    local -n __knit_opts=$1; shift
    local root="$1"
    __knit_ret=()

    # The experiment script, relative to the root. The script normally sits at
    # the root, so this strips the root prefix to leave a bare file name.
    local script_rel="${KNIT_SCRIPT_PATH#"${root}/"}"
    [[ -n "${script_rel}" ]] && __knit_ret+=("${script_rel}")

    # The framework: knit.sh sits beside the script, so the experiment can source
    # it. The exact framework version must travel with the bundle.
    [[ "${__knit_opts[no_knit]:-false}" != "true" ]] && __knit_ret+=("knit.sh")

    # The pruned .knit: the provenance database only, not the provisioned tools
    # (.knit/spack, .knit/sqlite, .knit/jq), which bootstrap re-provisions.
    [[ "${__knit_opts[no_db]:-false}" != "true" ]] && __knit_ret+=(".knit/knit.db")

    # The extra files the user declared, validated and glob-expanded. The user's
    # own list is strict (a bad path is fatal); the list Knit auto-required on the
    # experiment's behalf (spack.yaml files) is lenient (a bad path warns).
    local -a expanded_reqs=()
    _knit_bundle_expand_requires expanded_reqs "${root}" "true" \
        "${_KNIT_BUNDLE_REQUIRES[@]}"
    local rq
    for rq in "${expanded_reqs[@]}"; do
        __knit_ret+=("${rq}")
    done
    _knit_bundle_expand_requires expanded_reqs "${root}" "false" \
        "${_KNIT_BUNDLE_AUTO_REQUIRES[@]}"
    for rq in "${expanded_reqs[@]}"; do
        __knit_ret+=("${rq}")
    done

    # Setup manifests: the small identifying files under each setup instance —
    # enough to rebuild the environment — but never the built spack-env tree.
    local setup_root setup_rel
    _knit_setup_root setup_root
    if [[ -d "${setup_root}" ]]; then
        _knit_bundle_relpath setup_rel "${root}" "${setup_root}" "setups"
        local d name f abs
        for d in "${setup_root}"/*/; do
            [[ -d "${d}" ]] || continue
            name="${d%/}"; name="${name##*/}"
            for f in .activate.sh .setup.type .setup.id spack.yaml spack.lock; do
                abs="${d}${f}"
                [[ -e "${abs}" || -L "${abs}" ]] \
                    && __knit_ret+=("${setup_rel}/${name}/${f}")
            done
        done
    fi

    # Job directories: the logs and the scripts by default; the job body's own
    # content only when include_job_content is set (it is unbounded in size).
    local job_root job_rel
    _knit_job_root job_root
    if [[ -d "${job_root}" ]]; then
        _knit_bundle_relpath job_rel "${root}" "${job_root}" "jobs"
        local d name reljob f abs entry base
        for d in "${job_root}"/*/; do
            [[ -d "${d}" ]] || continue
            name="${d%/}"; name="${name##*/}"
            reljob="${job_rel}/${name}"
            if [[ "${__knit_opts[no_job_logs]:-false}" != "true" ]]; then
                for f in .stdout .stderr; do
                    abs="${d}${f}"
                    [[ -e "${abs}" || -L "${abs}" ]] \
                        && __knit_ret+=("${reljob}/${f}")
                done
            fi
            if [[ "${__knit_opts[no_job_scripts]:-false}" != "true" ]]; then
                for f in .job.sh .job.id; do
                    abs="${d}${f}"
                    [[ -e "${abs}" || -L "${abs}" ]] \
                        && __knit_ret+=("${reljob}/${f}")
                done
            fi
            if [[ "${__knit_opts[include_job_content]:-false}" == "true" ]]; then
                # User content is everything the body wrote into its cwd, beyond
                # the framework's own log, script, and submit-metadata dotfiles.
                for entry in "${d}"* "${d}".*; do
                    [[ -e "${entry}" || -L "${entry}" ]] || continue
                    base="${entry##*/}"
                    case "${base}" in
                        .|..|.stdout|.stderr|.job.sh|.job.id|.submit) continue ;;
                    esac
                    __knit_ret+=("${reljob}/${base}")
                done
            fi
        done
    fi

    # Declared artifacts: the whole results tree (tar/zip recurse into it). This
    # is the point of the experiment, so it travels unless dropped explicitly.
    if [[ "${__knit_opts[no_artifacts]:-false}" != "true" ]]; then
        local artifact_root artifact_rel
        _knit_artifact_root artifact_root
        if [[ -d "${artifact_root}" ]]; then
            _knit_bundle_relpath artifact_rel "${root}" "${artifact_root}" "artifacts"
            __knit_ret+=("${artifact_rel}")
        fi
    fi

    # Fetched resources: excluded by default (large, and re-fetchable from their
    # recorded source). Embedded all at once, or by name, on request.
    local include_all="${__knit_opts[include_all_resources]:-false}"
    local include_list="${__knit_opts[include_resources]:-}"
    if [[ "${include_all}" == "true" || -n "${include_list}" ]]; then
        local resource_root resource_rel
        _knit_resource_root resource_root
        if [[ -d "${resource_root}" ]]; then
            _knit_bundle_relpath resource_rel "${root}" "${resource_root}" "resources"
            if [[ "${include_all}" == "true" ]]; then
                # A plain-glob "*" skips the .<name>.resource.* sidecar markers,
                # so only the instances themselves are packed.
                local r base
                for r in "${resource_root}"/*; do
                    [[ -e "${r}" || -L "${r}" ]] || continue
                    base="${r##*/}"
                    __knit_ret+=("${resource_rel}/${base}")
                done
            else
                local rname abs
                local -a rnames
                IFS=',' read -r -a rnames <<< "${include_list}"
                for rname in "${rnames[@]}"; do
                    [[ -n "${rname}" ]] || continue
                    abs="${resource_root}/${rname}"
                    [[ -e "${abs}" || -L "${abs}" ]] \
                        && __knit_ret+=("${resource_rel}/${rname}")
                done
            fi
        fi
    fi

    # Warn about local-only resources left out of the archive. A knit_with_local
    # resource has no remote source to re-fetch, so leaving it out silently would
    # lose it. When such a resource exists and is not selected, warn so the choice
    # is deliberate.
    _knit_bundle_warn_unselected_local "${include_all}" "${include_list}"

    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_bundle_warn_unselected_local()
#
# Warn, for each fetched resource instance that is local-only (its type declared
# knit_with_local) and is not selected for the archive, that it will be left out.
# A local resource has no remote source, so — unlike a git or url resource — it
# cannot be re-fetched later; leaving it out should be a deliberate choice, not a
# silent omission. A resource is selected when --include-all-resources is set or
# its name is in the --include-resources list. The instance's type is read from
# its ".<name>.resource.type" sidecar marker, then mapped to the resource type's
# download method through the per-command _fetch_method marker.
#
# @param[in] include_all "true" when every resource is selected.
# @param[in] include_list Comma-separated selected resource names (may be empty).
# ------------------------------------------------------------------------------
_knit_bundle_warn_unselected_local() {
    local include_all="$1" include_list="$2"
    [[ "${include_all}" == "true" ]] && return 0

    local resource_root
    _knit_resource_root resource_root
    [[ -d "${resource_root}" ]] || return 0

    local -a selected=()
    [[ -n "${include_list}" ]] && IFS=',' read -r -a selected <<< "${include_list}"

    local inst base type_marker rtype mangled method_var sel s
    for inst in "${resource_root}"/*; do
        [[ -e "${inst}" || -L "${inst}" ]] || continue
        base="${inst##*/}"

        # Selected by name? Then it is packed; nothing to warn about.
        sel=""
        for s in "${selected[@]}"; do
            [[ "${s}" == "${base}" ]] && { sel=1; break; }
        done
        [[ -n "${sel}" ]] && continue

        # Only local-only resources are worth warning about. Map instance -> type
        # (from the sidecar) -> download method (from the type's registration).
        type_marker="${resource_root}/.${base}.resource.type"
        [[ -f "${type_marker}" ]] || continue
        IFS= read -r rtype < "${type_marker}" || rtype=""
        [[ -n "${rtype}" ]] || continue
        mangled="$(_knit_command_mangle "fetch:${rtype}")"
        method_var="_KNIT_CMD_${mangled}_fetch_method"
        if [[ "${!method_var:-}" == "local" ]]; then
            knit_warning "bundle: local resource \"%s\" is not selected and will not be in the archive (a local resource has no remote source to re-fetch); add it with --include-resources or --include-all-resources." \
                "${base}"
        fi
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
        _knit_bundle_source abs "${root}" "${rel}"
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
# A path may stand for content outside the experiment tree (an absolute stored
# root, see _KNIT_BUNDLE_EXTERN). Such paths cannot be packed relative to the
# root, so they are staged first: a symlink at the path's normalized relative name
# points to the real source, and the archive tool dereferences it into place. The
# in-tree paths pack straight from the root; only the outside paths need staging.
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

    # Split the paths into those that pack straight from the root and those that
    # stand for content outside the tree (packed via a staging directory).
    local -a intree=() extern=()
    local rel src
    for rel in "${rels[@]}"; do
        _knit_bundle_source src "${root}" "${rel}"
        if [[ "${src}" == "${root}/${rel}" ]]; then
            intree+=("${rel}")
        else
            extern+=("${rel}")
        fi
    done

    # Stage the outside paths: a symlink at each path's relative name pointing to
    # its real source, so the archive tool dereferences the bytes into place.
    local stage=""
    if (( ${#extern[@]} > 0 )); then
        stage="$(mktemp -d)"
        for rel in "${extern[@]}"; do
            _knit_bundle_source src "${root}" "${rel}"
            mkdir -p "${stage}/$(dirname -- "${rel}")"
            ln -s "${src}" "${stage}/${rel}"
        done
    fi

    if [[ "${fmt}" == "zip" ]]; then
        command -v zip &>/dev/null \
            || { [[ -n "${stage}" ]] && rm -rf -- "${stage}"; \
                 knit_fatal "bundle: 'zip' is required for --zip but was not found on PATH."; }
        # zip has no working-directory option, so resolve the output to an
        # absolute path before changing into the root, and remove any existing
        # archive first (zip would otherwise merge into it).
        local abs_out
        abs_out="$(realpath -m -- "${output}")"
        rm -f -- "${abs_out}"
        # zip rejects "--" before the archive name; abs_out is an absolute path
        # from realpath, so it never looks like an option. A second zip run appends
        # the staged outside paths (zip merges into an existing archive).
        if (( ${#intree[@]} > 0 )); then
            ( cd "${root}" && zip -q -r "${abs_out}" "${intree[@]}" ) \
                || { [[ -n "${stage}" ]] && rm -rf -- "${stage}"; \
                     knit_fatal "bundle: failed to write \"%s\"." "${output}"; }
        fi
        if [[ -n "${stage}" ]]; then
            ( cd "${stage}" && zip -q -r "${abs_out}" "${extern[@]}" ) \
                || { rm -rf -- "${stage}"; \
                     knit_fatal "bundle: failed to write \"%s\"." "${output}"; }
        fi
    else
        command -v tar &>/dev/null \
            || { [[ -n "${stage}" ]] && rm -rf -- "${stage}"; \
                 knit_fatal "bundle: 'tar' is required but was not found on PATH."; }
        if [[ -z "${stage}" ]]; then
            # Fast path: one compressed pass straight from the root.
            local listfile
            listfile="$(mktemp)"
            printf '%s\n' "${intree[@]}" > "${listfile}"
            if ! tar -czhf "${output}" -C "${root}" -T "${listfile}"; then
                rm -f -- "${listfile}"
                knit_fatal "bundle: failed to write \"%s\"." "${output}"
            fi
            rm -f -- "${listfile}"
        else
            # Outside paths present: gzip cannot be appended to, so build an
            # uncompressed archive in two passes (in-tree from the root, staged
            # from the staging dir) and gzip it afterwards.
            local tmptar lf ok=1
            tmptar="$(mktemp)"
            lf="$(mktemp)"
            if (( ${#intree[@]} > 0 )); then
                printf '%s\n' "${intree[@]}" > "${lf}"
                tar -chf "${tmptar}" -C "${root}" -T "${lf}" || ok=0
            else
                tar -chf "${tmptar}" -C "${root}" --files-from /dev/null || ok=0
            fi
            if (( ok )); then
                printf '%s\n' "${extern[@]}" > "${lf}"
                tar -rhf "${tmptar}" -C "${stage}" -T "${lf}" || ok=0
            fi
            (( ok )) && { gzip -c -- "${tmptar}" > "${output}" || ok=0; }
            rm -f -- "${tmptar}" "${lf}"
            if (( ! ok )); then
                rm -rf -- "${stage}"
                knit_fatal "bundle: failed to write \"%s\"." "${output}"
            fi
        fi
    fi
    [[ -n "${stage}" ]] && rm -rf -- "${stage}"
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_bundle_print_list()
#
# Print the planned bundle contents as a flat list, one path per line, each
# relative to the experiment root. This is the --dry-run --list form. When size
# mode is on, each line is prefixed with the path's size in bytes and a final
# TOTAL line gives the sum; the size of a symlink is its target's real size (du
# dereferences with -L), and the size of a directory is its recursive content.
#
# @param[in] size_mode "true" to annotate each path with its size in bytes.
# @param[in] root The absolute experiment root.
# @param[in] ... The relative paths to print.
# ------------------------------------------------------------------------------
_knit_bundle_print_list() {
    local size_mode="$1" root="$2"; shift 2
    local rel abs sz total=0
    for rel in "$@"; do
        [[ -z "${rel}" ]] && continue
        if [[ "${size_mode}" == "true" ]]; then
            _knit_bundle_source abs "${root}" "${rel}"
            sz="$(du -sbL -- "${abs}" 2>/dev/null | cut -f1)"; sz="${sz:-0}"
            total=$(( total + sz ))
            printf '%12d  %s\n' "${sz}" "${rel}"
        else
            printf '%s\n' "${rel}"
        fi
    done
    [[ "${size_mode}" == "true" ]] && printf '%12d  %s\n' "${total}" "TOTAL"
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_bundle_render_tree()
#
# Render one directory level of the bundle tree, then recurse into each child
# directory. It draws the box connectors ("├──", "└──", "│") from the child's
# position among its siblings. A node is shown with a trailing "/" when it has
# packed children or is a directory on disk. When size mode is on, a node that is
# a real bundle entry (named in the collected path list, so a leaf here) is
# annotated with its size in bytes and that size is added to the running total.
#
# @param[in] kidsname Name of the parent-to-children map (a value per line).
# @param[in] realname Name of the set of real bundle entries (leaf paths).
# @param[in] prefix The indentation drawn before this level's connectors.
# @param[in] parentpath The path whose children this call renders ("" is root).
# @param[in] size_mode "true" to annotate real entries with their size.
# @param[in] root The absolute experiment root.
# @param[in,out] totalname Name of the running byte-total variable.
# ------------------------------------------------------------------------------
_knit_bundle_render_tree() {
    local kidsname="$1" realname="$2" prefix="$3" parentpath="$4"
    local size_mode="$5" root="$6" totalname="$7"
    local -n _kids="${kidsname}"
    local -n _real="${realname}"
    local -n _tot="${totalname}"
    # A bash associative-array key may not be empty, so the top level is keyed by
    # a sentinel (STX) that no relative path can hold.
    local rootkey=$'\x02'
    local raw="${_kids[${parentpath}]:-}"
    [[ -z "${raw}" ]] && return 0

    local -a arr=()
    local line
    while IFS= read -r line; do
        [[ -n "${line}" ]] && arr+=("${line}")
    done <<< "${raw}"

    local n=${#arr[@]} i comp childpath connector childprefix name haskids abs sz
    for (( i=0; i<n; i++ )); do
        comp="${arr[i]}"
        if [[ "${parentpath}" == "${rootkey}" ]]; then
            childpath="${comp}"
        else
            childpath="${parentpath}/${comp}"
        fi
        if (( i == n-1 )); then
            connector="└── "; childprefix="    "
        else
            connector="├── "; childprefix="│   "
        fi
        haskids=""
        [[ -n "${_kids[${childpath}]:-}" ]] && haskids=1
        _knit_bundle_source abs "${root}" "${childpath}"
        name="${comp}"
        { [[ -n "${haskids}" ]] || [[ -d "${abs}" ]]; } && name="${comp}/"
        if [[ "${size_mode}" == "true" && -n "${_real[${childpath}]:-}" ]]; then
            sz="$(du -sbL -- "${abs}" 2>/dev/null | cut -f1)"; sz="${sz:-0}"
            _tot=$(( _tot + sz ))
            printf '%s%s%s  (%d bytes)\n' "${prefix}" "${connector}" "${name}" "${sz}"
        else
            printf '%s%s%s\n' "${prefix}" "${connector}" "${name}"
        fi
        [[ -n "${haskids}" ]] && _knit_bundle_render_tree \
            "${kidsname}" "${realname}" "${prefix}${childprefix}" \
            "${childpath}" "${size_mode}" "${root}" "${totalname}"
    done
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_bundle_print_tree()
#
# Print the planned bundle contents as a tree, like the layout in the design
# document. This is the default --dry-run form. It builds a parent-to-children
# map from the flat path list (synthesizing the intermediate directories that no
# entry names on its own), prints a root header from the archive label, and hands
# the rendering to _knit_bundle_render_tree. When size mode is on, each real entry
# is annotated with its size and a final TOTAL line gives the sum.
#
# @param[in] size_mode "true" to annotate each entry with its size in bytes.
# @param[in] root The absolute experiment root.
# @param[in] label The archive root name shown as the tree header.
# @param[in] ... The relative paths to render.
# ------------------------------------------------------------------------------
_knit_bundle_print_tree() {
    local size_mode="$1" root="$2" label="$3"; shift 3
    local -A tkids=() tseen=() treal=()
    # A bash associative-array key may not be empty, so the top level is keyed by
    # a sentinel (STX) that no relative path can hold.
    local rootkey=$'\x02'
    local p parent comp childpath seenkey
    local -a comps
    for p in "$@"; do
        [[ -z "${p}" ]] && continue
        # shellcheck disable=SC2034 # treal is read by _knit_bundle_render_tree through a nameref
        treal["${p}"]=1
        IFS='/' read -r -a comps <<< "${p}"
        parent="${rootkey}"
        for comp in "${comps[@]}"; do
            [[ -z "${comp}" ]] && continue
            if [[ "${parent}" == "${rootkey}" ]]; then
                childpath="${comp}"
            else
                childpath="${parent}/${comp}"
            fi
            seenkey="${parent}"$'\x1f'"${comp}"
            if [[ -z "${tseen[${seenkey}]:-}" ]]; then
                tseen["${seenkey}"]=1
                tkids["${parent}"]+="${comp}"$'\n'
            fi
            parent="${childpath}"
        done
    done

    printf '%s/\n' "${label}"
    local total=0
    _knit_bundle_render_tree tkids treal "" "${rootkey}" "${size_mode}" "${root}" total
    [[ "${size_mode}" == "true" ]] && printf '%12d  %s\n' "${total}" "TOTAL"
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_bundle()
#
# Body of "knit bundle": pack the experiment into one shippable archive. It reads
# the --output and --zip options, resolves the experiment root, computes the
# default output path when none is given, collects the minimal default contents,
# and drops any path the writer cannot pack. With --dry-run it prints the planned
# contents (a tree, or a flat list with --list, and sizes with --size) and writes
# nothing; otherwise it writes the archive. The command is read-only: it declares
# no table and takes knit_without_provenance, so it records no row and writes no
# provenance edge.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_bundle() {
    local output zip_flag ro_crate
    output="$(knit_get_parameter "output" "$@")"   || output=""
    zip_flag="$(knit_get_parameter "zip" "$@")"     || zip_flag="false"
    ro_crate="$(knit_get_parameter "ro-crate" "$@")" || ro_crate="false"

    local fmt="tar"
    [[ "${zip_flag}" == "true" ]] && fmt="zip"

    # The include/exclude filters. Each flag is read with a "false" fallback so a
    # direct call (in a test, say) that never went through CLI flag expansion is
    # treated as "flag not set"; include_resources defaults to the empty list.
    local no_knit no_db no_job_logs no_job_scripts include_job_content no_artifacts
    local include_all_resources include_resources
    no_knit="$(knit_get_parameter "no-knit" "$@")"                       || no_knit="false"
    no_db="$(knit_get_parameter "no-db" "$@")"                           || no_db="false"
    no_job_logs="$(knit_get_parameter "no-job-logs" "$@")"               || no_job_logs="false"
    no_job_scripts="$(knit_get_parameter "no-job-scripts" "$@")"         || no_job_scripts="false"
    include_job_content="$(knit_get_parameter "include-job-content" "$@")" || include_job_content="false"
    no_artifacts="$(knit_get_parameter "no-artifacts" "$@")"             || no_artifacts="false"
    include_all_resources="$(knit_get_parameter "include-all-resources" "$@")" || include_all_resources="false"
    include_resources="$(knit_get_parameter "include-resources" "$@")"   || include_resources=""

    # The inspection options: --dry-run writes nothing; --list and --size shape
    # the dry-run output and are meaningful only with it.
    local dry_run list_flag size_flag
    dry_run="$(knit_get_parameter "dry-run" "$@")"   || dry_run="false"
    list_flag="$(knit_get_parameter "list" "$@")"    || list_flag="false"
    size_flag="$(knit_get_parameter "size" "$@")"    || size_flag="false"

    # The two resource selectors overlap, so naming both is a usage error.
    if [[ "${include_all_resources}" == "true" && -n "${include_resources}" ]]; then
        knit_fatal "bundle: --include-all-resources and --include-resources are mutually exclusive."
    fi

    # --list and --size only shape the dry-run report; they do nothing to a real
    # archive, so naming either without --dry-run is a usage error.
    if [[ "${dry_run}" != "true" ]] \
        && { [[ "${list_flag}" == "true" ]] || [[ "${size_flag}" == "true" ]]; }; then
        knit_fatal "bundle: --list and --size are only meaningful with --dry-run."
    fi

    # shellcheck disable=SC2034 # read by _knit_bundle_collect through a nameref
    local -A bundle_opts=(
        [no_knit]="${no_knit}"
        [no_db]="${no_db}"
        [no_job_logs]="${no_job_logs}"
        [no_job_scripts]="${no_job_scripts}"
        [include_job_content]="${include_job_content}"
        [no_artifacts]="${no_artifacts}"
        [include_all_resources]="${include_all_resources}"
        [include_resources]="${include_resources}"
    )

    local root
    _knit_experiment_root root

    [[ -z "${output}" ]] && _knit_bundle_default_output output "${fmt}"

    # The extern map is rebuilt from scratch each run: collection fills it while
    # resolving out-of-tree roots and auto-required paths.
    _KNIT_BUNDLE_EXTERN=()

    local -a candidates=()
    _knit_bundle_collect candidates bundle_opts "${root}"

    local -a paths=()
    _knit_bundle_prune_paths paths "${root}" "${candidates[@]}"

    # With --ro-crate, generate the manifest describing exactly these packed
    # files, then carry it at the archive root. It is written to a temporary file
    # and mapped into the archive through the extern map (like an out-of-tree
    # path), so the writer stages it at "ro-crate-metadata.json" and the dry-run
    # report lists it. The temporary file is removed before returning.
    local rocrate_tmp=""
    if [[ "${ro_crate}" == "true" ]]; then
        rocrate_tmp="$(mktemp)"
        _knit_bundle_rocrate_generate "${rocrate_tmp}" "${root}" "${paths[@]}"
        _KNIT_BUNDLE_EXTERN["ro-crate-metadata.json"]="${rocrate_tmp}"
        paths+=("ro-crate-metadata.json")
    fi

    # --dry-run reports the planned contents and writes no archive.
    if [[ "${dry_run}" == "true" ]]; then
        if [[ "${list_flag}" == "true" ]]; then
            _knit_bundle_print_list "${size_flag}" "${root}" "${paths[@]}"
        else
            # The tree header is the archive root name: the output basename with
            # its format extension removed.
            local label
            label="$(basename -- "${output}")"
            label="${label%.zip}"; label="${label%.tar.gz}"; label="${label%.tgz}"
            _knit_bundle_print_tree "${size_flag}" "${root}" "${label}" "${paths[@]}"
        fi
        [[ -n "${rocrate_tmp}" ]] && rm -f -- "${rocrate_tmp}"
        return 0
    fi

    _knit_bundle_write_archive "${fmt}" "${output}" "${root}" "${paths[@]}"

    [[ -n "${rocrate_tmp}" ]] && rm -f -- "${rocrate_tmp}"

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
knit_with_flag "ro-crate" \
    "Also write an ro-crate-metadata.json manifest at the archive root."
knit_with_flag "no-knit" \
    "Leave out the knit.sh framework file."
knit_with_flag "no-db" \
    "Leave out the provenance database (.knit/knit.db)."
knit_with_flag "no-job-logs" \
    "Leave out each job's .stdout and .stderr."
knit_with_flag "no-job-scripts" \
    "Leave out each job's .job.sh and .job.id."
knit_with_flag "include-job-content" \
    "Also pack the user content of each job directory (unbounded in size)."
knit_with_flag "no-artifacts" \
    "Leave out the declared artifacts."
knit_with_optional "include-resources:string" "" \
    "Pack the named fetched resources (comma-separated names)."
knit_with_flag "include-all-resources" \
    "Pack every fetched resource (mutually exclusive with --include-resources)."
knit_with_flag "dry-run" \
    "Print the planned contents and write no archive."
knit_with_flag "list" \
    "With --dry-run, print a flat list of paths instead of a tree."
knit_with_flag "size" \
    "With --dry-run, annotate each entry with its size and print a total."
knit_done
