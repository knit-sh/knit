#!/bin/bash

## @file plugin.sh

# ------------------------------------------------------------------------------
# @var _KNIT_PLUGIN_CACHE_ROOT
#
# Root of the content-addressed plugin cache, shared across experiments and
# invocations. A plugin commit is fetched once into
# "<root>/<host>/<org>/<repo>/<commit>/" and every later import of that commit is
# an offline cache hit. Defaults under XDG_CACHE_HOME (falling back to ~/.cache);
# a test or a reproducer may override it.
# ------------------------------------------------------------------------------
declare -g _KNIT_PLUGIN_CACHE_ROOT
_KNIT_PLUGIN_CACHE_ROOT="${XDG_CACHE_HOME:-${HOME}/.cache}/knit/plugins"

# ------------------------------------------------------------------------------
# @var _KNIT_PLUGIN_REFS
#
# Map of canonical id ("<host>/<org>/<repo>") to the ref it was imported at,
# recorded the moment an import begins (before sourcing) so a transitive or
# cyclic re-import of the same id dedups instead of recursing. An empty value
# means the import pinned no ref (default branch). Used for dedup and for the
# version-conflict check.
# ------------------------------------------------------------------------------
declare -gA _KNIT_PLUGIN_REFS
_KNIT_PLUGIN_REFS=()

# ------------------------------------------------------------------------------
# @var _KNIT_PLUGIN_COMMITS
#
# Map of canonical id to the exact commit SHA its ref resolved to. Populated as
# each plugin is imported; the seed of the provenance recorded at bootstrap.
# ------------------------------------------------------------------------------
declare -gA _KNIT_PLUGIN_COMMITS
_KNIT_PLUGIN_COMMITS=()

# ------------------------------------------------------------------------------
# @var _KNIT_PLUGIN_LOCKFILE
#
# Path to the committed lockfile that pins every imported plugin (canonical id ->
# resolved commit + checksum). It lives next to the experiment script and ships
# in the experiment's VCS, so a fresh checkout resolves the exact commits before
# bootstrap, for both introspection and reproduction. A resolution prefers a
# lockfile pin over the ref; a mutable ref with no pin is resolved once and
# written back here. A test or reproducer may override the path.
# ------------------------------------------------------------------------------
declare -g _KNIT_PLUGIN_LOCKFILE
_KNIT_PLUGIN_LOCKFILE="$(dirname "${_KNIT_SCRIPT_PATH}")/knit-plugins.lock"

# ------------------------------------------------------------------------------
# @var _KNIT_PLUGIN_DEFERRED
#
# Labels ("<id>" or "<id>@<ref>") of plugins that could not be made available in
# the current invocation (offline, with no cached commit and no lockfile pin).
# Their import is deferred rather than fatal, and they are listed in the
# describe/--help footer so the gap is explicit rather than a silent truncation.
# ------------------------------------------------------------------------------
declare -ga _KNIT_PLUGIN_DEFERRED
_KNIT_PLUGIN_DEFERRED=()

# ------------------------------------------------------------------------------
# @var _KNIT_PLUGIN_CNF_INSTALLED
#
# "true" once the command_not_found_handle safety net has been installed (on the
# first deferral), so it is installed at most once. The net keeps a "set -e"
# experiment source loading when it calls a deferred plugin's missing knit_*/@*
# symbol at registration time.
# ------------------------------------------------------------------------------
declare -g _KNIT_PLUGIN_CNF_INSTALLED
_KNIT_PLUGIN_CNF_INSTALLED="false"

# ------------------------------------------------------------------------------
# @var _KNIT_PLUGIN_ORDER
#
# Canonical ids ("<host>/<org>/<repo>") of the plugins imported this invocation,
# in first-import order (a dependency, imported transitively from a dependent's
# plugin.sh, sorts before the dependent's remaining imports but after the
# dependent's own entry). It drives the lockfile write, the plugins-table rows,
# and the management commands; a repeated import of the same id is recorded once.
# ------------------------------------------------------------------------------
declare -ga _KNIT_PLUGIN_ORDER
_KNIT_PLUGIN_ORDER=()

# ------------------------------------------------------------------------------
# @var _KNIT_PLUGIN_SPEC
#
# Map of canonical id to the import spec exactly as the user wrote it, kept for
# the plugins-table "spec" column (the intent, next to the resolved commit).
# ------------------------------------------------------------------------------
declare -gA _KNIT_PLUGIN_SPEC
_KNIT_PLUGIN_SPEC=()

# ------------------------------------------------------------------------------
# @var _KNIT_PLUGIN_CHECKSUM
#
# Map of canonical id to the fetched tarball's sha256 (empty when the commit came
# from the cache with no recorded pin). Written to the lockfile and the
# plugins-table "checksum" column.
# ------------------------------------------------------------------------------
declare -gA _KNIT_PLUGIN_CHECKSUM
_KNIT_PLUGIN_CHECKSUM=()

# ------------------------------------------------------------------------------
# @var _KNIT_PLUGIN_IMPORTED_BY
#
# Map of canonical id to the id of the plugin that imported it, or the empty
# string when the experiment imported it directly. This is the dependency edge
# recorded in the plugins-table "imported_by" column.
# ------------------------------------------------------------------------------
declare -gA _KNIT_PLUGIN_IMPORTED_BY
_KNIT_PLUGIN_IMPORTED_BY=()

# ------------------------------------------------------------------------------
# @var _KNIT_PLUGIN_IMPORT_STACK
#
# Stack of plugin ids currently being sourced, pushed around each "source
# plugin.sh" so a transitive knit_import done from a plugin's own plugin.sh knows
# which plugin imported it (the stack top) and records the dependency edge.
# ------------------------------------------------------------------------------
declare -ga _KNIT_PLUGIN_IMPORT_STACK
_KNIT_PLUGIN_IMPORT_STACK=()

# ------------------------------------------------------------------------------
# @var _KNIT_PLUGIN_TABLE
#
# Name of the provenance table recording which plugins an experiment imported
# and at which exact commit. A normal knit table in .knit/knit.db, visible to
# "knit query" like any other.
# ------------------------------------------------------------------------------
declare -g _KNIT_PLUGIN_TABLE
_KNIT_PLUGIN_TABLE="plugins"

# ------------------------------------------------------------------------------
# @var _KNIT_PLUGIN_TABLE_ENSURED
#
# "1" once the plugins table has been ensured this process, so the idempotent
# create-or-migrate runs at most once per invocation.
# ------------------------------------------------------------------------------
declare -g _KNIT_PLUGIN_TABLE_ENSURED
_KNIT_PLUGIN_TABLE_ENSURED=""

# ------------------------------------------------------------------------------
# @fn _knit_plugin_lock_get()
#
# Look up a plugin's pin in the lockfile. Sets the commit and checksum outputs to
# the recorded values (checksum may be empty) and returns 0 when the canonical id
# is pinned; returns 1 (clearing both outputs) when it is not pinned or the
# lockfile is absent. Blank lines and "#" comment lines are ignored.
#
# @param[out] commit_out   Nameref receiving the pinned commit SHA.
# @param[out] checksum_out Nameref receiving the pinned tarball checksum.
# @param[in]  id           Canonical id ("<host>/<org>/<repo>").
# ------------------------------------------------------------------------------
_knit_plugin_lock_get() {
    local -n __knit_ret1=$1
    local -n __knit_ret2=$2
    local id="$3"
    __knit_ret1=""
    __knit_ret2=""
    [[ -f "${_KNIT_PLUGIN_LOCKFILE}" ]] || return 1
    local lid lcommit lsum
    while read -r lid lcommit lsum; do
        [[ -z "${lid}" || "${lid}" == \#* ]] && continue
        if [[ "${lid}" == "${id}" ]]; then
            __knit_ret1="${lcommit}"
            __knit_ret2="${lsum}"
            return 0
        fi
    done < "${_KNIT_PLUGIN_LOCKFILE}"
    return 1
}

# ------------------------------------------------------------------------------
# @fn _knit_plugin_lock_set()
#
# Record (or update) a plugin's pin in the lockfile, then rewrite the file with
# its entries sorted by canonical id for a stable, review-friendly diff. An empty
# checksum is written as a two-field line; a present checksum as three fields.
#
# @param[in] id       Canonical id ("<host>/<org>/<repo>").
# @param[in] commit   Resolved commit SHA.
# @param[in] checksum Tarball sha256 (may be empty).
# ------------------------------------------------------------------------------
_knit_plugin_lock_set() {
    local id="$1"
    local commit="$2"
    local checksum="$3"
    local -A entries=()
    if [[ -f "${_KNIT_PLUGIN_LOCKFILE}" ]]; then
        local lid lcommit lsum
        while read -r lid lcommit lsum; do
            [[ -z "${lid}" || "${lid}" == \#* ]] && continue
            if [[ -n "${lsum}" ]]; then
                entries["${lid}"]="${lcommit} ${lsum}"
            else
                entries["${lid}"]="${lcommit}"
            fi
        done < "${_KNIT_PLUGIN_LOCKFILE}"
    fi
    if [[ -n "${checksum}" ]]; then
        entries["${id}"]="${commit} ${checksum}"
    else
        entries["${id}"]="${commit}"
    fi
    mkdir -p "$(dirname "${_KNIT_PLUGIN_LOCKFILE}")"
    local -a keys
    mapfile -t keys < <(printf '%s\n' "${!entries[@]}" | sort)
    {
        printf '# knit-plugins.lock: pinned plugin versions '
        printf '(id commit checksum). Generated; commit to VCS.\n'
        local k
        for k in "${keys[@]}"; do
            printf '%s %s\n' "${k}" "${entries[${k}]}"
        done
    } > "${_KNIT_PLUGIN_LOCKFILE}"
}

# ------------------------------------------------------------------------------
# @fn _knit_plugin_defer()
#
# Record a plugin whose code is unavailable this invocation (offline, uncached,
# unpinned) so it shows in the describe/--help footer, and install the
# command_not_found safety net so the experiment source still loads when it calls
# the plugin's (now undefined) symbols under "set -e".
#
# @param[in] id  Canonical id ("<host>/<org>/<repo>").
# @param[in] ref Requested ref (may be empty).
# ------------------------------------------------------------------------------
_knit_plugin_defer() {
    local id="$1"
    local ref="$2"
    local label="${id}"
    [[ -n "${ref}" ]] && label="${id}@${ref}"
    _KNIT_PLUGIN_DEFERRED+=("${label}")
    knit_trace "Deferring plugin ${label} (not available offline)."
    _knit_plugin_install_cnf_net
}

# ------------------------------------------------------------------------------
# @fn _knit_plugin_install_cnf_net()
#
# Install, at most once, a command_not_found_handle that turns a call to an
# undefined knit_*/@* symbol into a no-op returning 0 (so a deferred plugin's
# decorators/commands do not abort a "set -e" experiment at registration time),
# while any other unknown command keeps the default "command not found" failure.
# ------------------------------------------------------------------------------
_knit_plugin_install_cnf_net() {
    [[ "${_KNIT_PLUGIN_CNF_INSTALLED}" == "true" ]] && return 0
    _KNIT_PLUGIN_CNF_INSTALLED="true"
    # shellcheck disable=SC2317 # invoked indirectly by bash as the not-found hook
    command_not_found_handle() {
        local missing="$1"
        if [[ "${missing}" == knit_* || "${missing}" == @* ]]; then
            knit_trace "Ignoring \"${missing}\" from a deferred plugin."
            return 0
        fi
        printf '%s: command not found\n' "${missing}" >&2
        return 127
    }
}

# ------------------------------------------------------------------------------
# @fn _knit_plugin_print_deferred_footer()
#
# Print, to standard error, the footer listing plugins deferred this invocation
# (empty list -> nothing). describe and --help call it after their output so a
# user sees which plugin commands/decorators are missing and how to get them,
# instead of a silently truncated command tree. Standard error is used so the
# footer never corrupts a machine-readable describe format or piped help text.
# ------------------------------------------------------------------------------
_knit_plugin_print_deferred_footer() {
    local n="${#_KNIT_PLUGIN_DEFERRED[@]}"
    (( n > 0 )) || return 0
    local verb="are" plural="s"
    if (( n == 1 )); then
        verb="is"
        plural=""
    fi
    {
        printf '\n%d imported plugin%s %s not available offline ' \
            "${n}" "${plural}" "${verb}"
        printf '(no cached commit, no lockfile pin):\n'
        local p
        for p in "${_KNIT_PLUGIN_DEFERRED[@]}"; do
            printf '  - %s\n' "${p}"
        done
        printf 'Their commands and decorators appear once fetched. Run with '
        # shellcheck disable=SC2016 # literal backticks in a user-facing message
        printf 'network access, commit knit-plugins.lock, or run `knit bootstrap`.\n'
    } >&2
}

# ------------------------------------------------------------------------------
# @fn _knit_plugin_parse_spec()
#
# Parse an import spec into its host, org, repo, and ref parts. Accepted forms:
#   - "[https://]<host>/<org>/<repo>[@<ref>]" — a full spec.
#   - "<org>/<repo>[@<ref>]"                  — host defaults to github.com.
#   - "<name>[@<ref>]"                        — the blessed-namespace shorthand,
#     expanding to github.com/knit-sh/knit-<name>.
# A missing ref is returned empty (the caller treats it as the default branch).
# Fatal on a malformed spec.
#
# @param[out] host_out Nameref receiving the host.
# @param[out] org_out  Nameref receiving the owner (org or user).
# @param[out] repo_out Nameref receiving the repository name.
# @param[out] ref_out  Nameref receiving the ref (empty when none was given).
# @param[in]  spec     The import spec as written by the user.
# ------------------------------------------------------------------------------
_knit_plugin_parse_spec() {
    local -n __knit_ret1=$1
    local -n __knit_ret2=$2
    local -n __knit_ret3=$3
    local -n __knit_ret4=$4
    local spec="$5"

    # Drop an optional scheme; the host is carried by the path below.
    spec="${spec#https://}"
    spec="${spec#http://}"

    # Split off the ref at the first "@"; the path part never contains one. The
    # temporaries below are __-prefixed because a caller passes its output
    # variables named host/org/repo/ref, which the namerefs alias; a plain local
    # of the same name would shadow the nameref (nameref-shadow-collision).
    local path __knit_ref=""
    if [[ "${spec}" == *@* ]]; then
        path="${spec%%@*}"
        __knit_ref="${spec#*@}"
    else
        path="${spec}"
    fi
    path="${path%/}"
    if [[ -z "${path}" ]]; then
        knit_fatal "knit_import: empty plugin spec."
    fi

    local -a parts
    IFS='/' read -r -a parts <<< "${path}"
    local __knit_host __knit_org __knit_repo
    case "${#parts[@]}" in
        1)
            __knit_host="github.com"
            __knit_org="knit-sh"
            __knit_repo="knit-${parts[0]}"
            ;;
        2)
            __knit_host="github.com"
            __knit_org="${parts[0]}"
            __knit_repo="${parts[1]}"
            ;;
        3)
            __knit_host="${parts[0]}"
            __knit_org="${parts[1]}"
            __knit_repo="${parts[2]}"
            ;;
        *)
            knit_fatal "knit_import: malformed plugin spec \"$5\" \
(expected [host/]org/repo or a plugin name)."
            ;;
    esac
    if [[ -z "${__knit_org}" || -z "${__knit_repo}" ]]; then
        knit_fatal "knit_import: malformed plugin spec \"$5\"."
    fi

    __knit_ret1="${__knit_host}"
    __knit_ret2="${__knit_org}"
    __knit_ret3="${__knit_repo}"
    __knit_ret4="${__knit_ref}"
}

# ------------------------------------------------------------------------------
# @fn _knit_plugin_resolve_commit()
#
# Resolve a plugin ref to an exact commit SHA, honoring the lockfile. Precedence:
# a full 40-hex-character SHA resolves to itself with no network access; else a
# lockfile pin for this canonical id is authoritative (deterministic and
# offline-friendly); else the ref is resolved through the host API (an empty ref
# means the default branch, resolved as "HEAD") and the writeback flag is set so
# the caller records the fresh pin. When KNIT_OFFLINE=1 blocks a needed network
# resolution, the function returns 1 (the caller defers the import) rather than
# failing.
#
# @param[out] commit_out    Nameref receiving the resolved commit SHA.
# @param[out] writeback_out Nameref set to "true" when a fresh (unpinned,
#             network-resolved) commit should be written back to the lockfile.
# @param[in]  host          Repository host (only github.com is supported today).
# @param[in]  org           Repository owner.
# @param[in]  repo          Repository name.
# @param[in]  ref           Ref to resolve (empty for the default branch).
# @return 0 when resolved; 1 when it cannot be resolved offline (defer).
# ------------------------------------------------------------------------------
_knit_plugin_resolve_commit() {
    local -n __knit_ret1=$1
    local -n __knit_ret2=$2
    local host="$3"
    local org="$4"
    local repo="$5"
    local ref="$6"
    __knit_ret2="false"

    if [[ "${ref}" =~ ^[0-9a-f]{40}$ ]]; then
        __knit_ret1="${ref}"
        return 0
    fi

    # A lockfile pin wins over the ref: it is the recorded source of truth, so a
    # fresh checkout resolves identically before any bootstrap, even for "@main".
    local __knit_commit __knit_sum
    if _knit_plugin_lock_get __knit_commit __knit_sum "${host}/${org}/${repo}"; then
        __knit_ret1="${__knit_commit}"
        return 0
    fi

    if [[ "${KNIT_OFFLINE:-}" == "1" ]]; then
        return 1
    fi

    # Resolve through the jq-free, nameref resolver: the import runs at source
    # time, before bootstrap provisions jq, and a failure must stay fatal in this
    # shell (a command substitution would swallow it).
    if ! _knit_github_resolve_commit_light __knit_commit "${org}" "${repo}" \
            "${ref:-HEAD}"; then
        knit_fatal "knit_import: could not resolve \"${ref:-HEAD}\" to a commit \
in ${org}/${repo}. Check the ref and network access (set GITHUB_TOKEN if \
rate-limited), or commit a knit-plugins.lock pin."
    fi
    __knit_ret1="${__knit_commit}"
    __knit_ret2="true"
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_plugin_fetch()
#
# Fetch a plugin commit into the content-addressed cache. The tarball is
# downloaded and extracted into a temporary directory; its sha256 is verified
# against an expected digest when one was given; the tree is checked for a
# top-level plugin.sh; then it is published atomically into the cache directory.
# The computed sha256 is returned so the caller can record it in the lockfile.
# Fatal on download failure, checksum mismatch, or a missing plugin.sh.
#
# @param[out] sha256_out Nameref receiving the fetched tarball's sha256.
# @param[in]  host       Repository host.
# @param[in]  org        Repository owner.
# @param[in]  repo       Repository name.
# @param[in]  commit     Commit SHA to fetch.
# @param[in]  dest       Cache directory to publish the extracted tree into.
# @param[in]  expected   Expected tarball sha256 (empty to skip verification).
# ------------------------------------------------------------------------------
_knit_plugin_fetch() {
    local -n __knit_ret=$1
    local host="$2"
    local org="$3"
    local repo="$4"
    local commit="$5"
    local dest="$6"
    local expected="$7"

    local tmp
    tmp="$(mktemp -d)"
    local sha256
    knit_github_download sha256 "${org}" "${repo}" "${tmp}" "${commit}"
    if [[ -n "${expected}" && "${sha256}" != "${expected}" ]]; then
        rm -rf "${tmp}"
        knit_fatal "Plugin ${host}/${org}/${repo}@${commit}: sha256 mismatch \
(expected ${expected}, got ${sha256})."
    fi
    if [[ ! -f "${tmp}/plugin.sh" ]]; then
        rm -rf "${tmp}"
        knit_fatal "Plugin ${host}/${org}/${repo}@${commit}: \
no plugin.sh at the repository root."
    fi
    mkdir -p "$(dirname "${dest}")"
    rm -rf "${dest}"
    mv "${tmp}" "${dest}"
    __knit_ret="${sha256}"
}

# ------------------------------------------------------------------------------
# @fn knit_import()
#
# Import a plugin: resolve its spec to an exact commit, ensure that commit's code
# is present in the content-addressed cache (sourcing from cache when present,
# fetching it otherwise), and source its plugin.sh so its commands and decorators
# become available. Call it at the top of the experiment, after "source knit.sh"
# and before any use of what the plugin provides.
#
# A plugin is sourced once per canonical id ("<host>/<org>/<repo>"); a repeated
# import of the same id dedups. Importing the same id at two different explicit
# refs is a fatal version conflict. A plugin's own plugin.sh may call knit_import
# for its dependencies; because sourcing is synchronous, a dependency is fully
# sourced before the dependent continues.
#
# Resolution prefers a lockfile pin, so a fresh checkout resolves deterministically
# even before bootstrap; a mutable ref resolved for the first time is written back
# to the lockfile. When the plugin's code cannot be obtained (offline, with no
# cached commit and no pin), the import is deferred rather than fatal: it is
# recorded for the describe/--help footer and a command_not_found safety net keeps
# the experiment source loading.
#
# @param[in] spec The import spec (see _knit_plugin_parse_spec for the forms).
# @param[in] --sha256 <hash> Optional hard pin: fail unless the fetched tarball
#            matches this sha256.
# @see KNIT_OFFLINE=1 forces cache-only resolution (never touch the network).
# ------------------------------------------------------------------------------
knit_import() {
    local spec="" expected_sha256=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sha256)
                expected_sha256="$2"
                shift 2
                ;;
            --sha256=*)
                expected_sha256="${1#--sha256=}"
                shift
                ;;
            *)
                if [[ -z "${spec}" ]]; then
                    spec="$1"
                    shift
                else
                    knit_fatal "knit_import: unexpected argument \"$1\"."
                fi
                ;;
        esac
    done
    if [[ -z "${spec}" ]]; then
        knit_fatal "knit_import requires a plugin spec."
    fi

    local host org repo ref
    _knit_plugin_parse_spec host org repo ref "${spec}"
    if [[ "${host}" != "github.com" ]]; then
        knit_fatal "knit_import: plugin host \"${host}\" is not supported yet \
(only github.com)."
    fi
    local id="${host}/${org}/${repo}"

    # Dedup / conflict by canonical id, before any network access. Two explicit
    # and different refs conflict; an unpinned import is compatible with any pin.
    if [[ -v _KNIT_PLUGIN_REFS["${id}"] ]]; then
        local existing="${_KNIT_PLUGIN_REFS[${id}]}"
        if [[ -z "${ref}" || -z "${existing}" || "${ref}" == "${existing}" ]]; then
            if [[ -z "${existing}" && -n "${ref}" ]]; then
                _KNIT_PLUGIN_REFS["${id}"]="${ref}"
            fi
            return 0
        fi
        knit_fatal "Plugin \"${id}\" imported twice with conflicting refs: \
\"${existing}\" and \"${ref}\"."
    fi
    # Record the pin before sourcing so a transitive/cyclic re-import dedups.
    _KNIT_PLUGIN_REFS["${id}"]="${ref}"

    # Resolve the commit (lockfile pin, SHA, or network). A failure means the ref
    # cannot be resolved offline: defer rather than abort.
    local commit writeback
    if ! _knit_plugin_resolve_commit commit writeback "${host}" "${org}" \
            "${repo}" "${ref}"; then
        _knit_plugin_defer "${id}" "${ref}"
        return 0
    fi
    _KNIT_PLUGIN_COMMITS["${id}"]="${commit}"

    local dir="${_KNIT_PLUGIN_CACHE_ROOT}/${host}/${org}/${repo}/${commit}"
    local checksum=""
    if [[ ! -f "${dir}/plugin.sh" ]]; then
        # The commit is known but not cached; offline we cannot fetch it. Defer.
        if [[ "${KNIT_OFFLINE:-}" == "1" ]]; then
            _knit_plugin_defer "${id}" "${ref}"
            return 0
        fi
        _knit_plugin_fetch checksum "${host}" "${org}" "${repo}" "${commit}" \
            "${dir}" "${expected_sha256}"
    fi
    if [[ ! -f "${dir}/plugin.sh" ]]; then
        knit_fatal "Plugin \"${id}\": no plugin.sh at ${dir}."
    fi

    # On a cache hit the tarball was not re-downloaded, so its checksum was not
    # recomputed; recover it from the lockfile pin when one is recorded, so the
    # provenance row and a rewritten lockfile still carry it.
    if [[ -z "${checksum}" ]]; then
        local lcommit lsum
        if _knit_plugin_lock_get lcommit lsum "${id}" && [[ -n "${lsum}" ]]; then
            checksum="${lsum}"
        fi
    fi

    # Freshly resolved a mutable ref (no prior pin): record it so a later run and
    # a fresh checkout resolve to the same commit.
    if [[ "${writeback}" == "true" ]]; then
        _knit_plugin_lock_set "${id}" "${commit}" "${checksum}"
    fi

    # Record this import's provenance (ordered), for the lockfile, the plugins
    # table, and the management commands. The importer is the plugin currently
    # being sourced (the import stack top), or the experiment itself when the
    # stack is empty (recorded as an empty importer).
    _KNIT_PLUGIN_ORDER+=("${id}")
    _KNIT_PLUGIN_SPEC["${id}"]="${spec}"
    _KNIT_PLUGIN_CHECKSUM["${id}"]="${checksum}"
    local importer=""
    (( ${#_KNIT_PLUGIN_IMPORT_STACK[@]} > 0 )) \
        && importer="${_KNIT_PLUGIN_IMPORT_STACK[-1]}"
    _KNIT_PLUGIN_IMPORTED_BY["${id}"]="${importer}"

    knit_trace "Sourcing plugin ${id}@${commit}."
    # A plugin's plugin.sh may import its own dependencies; push this id so those
    # nested imports record it as their importer, and pop it once sourced.
    _KNIT_PLUGIN_IMPORT_STACK+=("${id}")
    # shellcheck disable=SC1091 # plugin path is resolved at runtime
    source "${dir}/plugin.sh"
    unset "_KNIT_PLUGIN_IMPORT_STACK[$(( ${#_KNIT_PLUGIN_IMPORT_STACK[@]} - 1 ))]"
}

# ------------------------------------------------------------------------------
# @fn _knit_plugin_write_lockfile()
#
# Write every imported plugin's resolved pin (commit + checksum) to the committed
# lockfile, so a fresh checkout resolves the same commits before bootstrap. Each
# entry is upserted (see _knit_plugin_lock_set), leaving an unrelated pin already
# in the file untouched. A no-op when nothing was imported.
# ------------------------------------------------------------------------------
_knit_plugin_write_lockfile() {
    local id
    for id in "${_KNIT_PLUGIN_ORDER[@]}"; do
        _knit_plugin_lock_set "${id}" "${_KNIT_PLUGIN_COMMITS[${id}]:-}" \
            "${_KNIT_PLUGIN_CHECKSUM[${id}]:-}"
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_plugin_ensure_table()
#
# Ensure the plugins provenance table exists and carries every column, creating
# or additively migrating it on first use this process (guarded by
# _KNIT_PLUGIN_TABLE_ENSURED). The schema records, per import: the uuid row id,
# the spec as written, the resolved host/org/repo, the requested ref, the
# resolved commit, the tarball checksum, the importing plugin (empty for the
# experiment), and the epoch second it was recorded.
# ------------------------------------------------------------------------------
_knit_plugin_ensure_table() {
    [[ -n "${_KNIT_PLUGIN_TABLE_ENSURED}" ]] && return 0
    _knit_db_ensure_table "${_KNIT_PLUGIN_TABLE}" \
        "id:uuid" "spec:string" "host:string" "org:string" "repo:string" \
        "ref:string" "commit:string" "checksum:string" "imported_by:string" \
        "installed_at:integer"
    _KNIT_PLUGIN_TABLE_ENSURED="1"
}

# ------------------------------------------------------------------------------
# @fn _knit_plugin_record_row()
#
# Insert one provenance row for an imported plugin into the plugins table. The
# insert is idempotent across repeated bootstraps: a row for this host/org/repo
# at this exact commit is written at most once, so re-running bootstrap (or
# bootstrap update mode) never duplicates an unchanged plugin.
#
# @param[in] id Canonical id ("<host>/<org>/<repo>") of a plugin in the order set.
# ------------------------------------------------------------------------------
_knit_plugin_record_row() {
    local id="$1"
    local host org repo
    IFS='/' read -r host org repo <<< "${id}"
    local commit="${_KNIT_PLUGIN_COMMITS[${id}]:-}"

    # Skip when this exact (host/org/repo, commit) is already recorded, so a
    # re-bootstrap does not add a second identical row.
    local esc_host esc_org esc_repo esc_commit commit_ident existing
    _knit_sql_escape esc_host "${host}"
    _knit_sql_escape esc_org "${org}"
    _knit_sql_escape esc_repo "${repo}"
    _knit_sql_escape esc_commit "${commit}"
    _knit_db_sql_ident commit_ident "commit"
    existing="$(_knit_sqlite3 "SELECT COUNT(*) FROM ${_KNIT_PLUGIN_TABLE} \
WHERE host='${esc_host}' AND org='${esc_org}' AND repo='${esc_repo}' \
AND ${commit_ident}='${esc_commit}';")"
    [[ "${existing:-0}" -gt 0 ]] && return 0

    local uuid installed_at
    uuid="$(_knit_uuidv7)"
    installed_at="$(date +%s)"

    local -a names=(id spec host org repo ref commit checksum imported_by installed_at)
    local -a values=(
        "${uuid}"
        "${_KNIT_PLUGIN_SPEC[${id}]:-}"
        "${host}"
        "${org}"
        "${repo}"
        "${_KNIT_PLUGIN_REFS[${id}]:-}"
        "${commit}"
        "${_KNIT_PLUGIN_CHECKSUM[${id}]:-}"
        "${_KNIT_PLUGIN_IMPORTED_BY[${id}]:-}"
        "${installed_at}"
    )

    local -a cols=() vals=()
    local i col_ident val_esc
    for i in "${!names[@]}"; do
        _knit_db_sql_ident col_ident "${names[i]}"
        cols+=("${col_ident}")
        _knit_sql_escape val_esc "${values[i]}"
        vals+=("'${val_esc}'")
    done

    local cols_sql vals_sql table_ident
    cols_sql=$(IFS=', '; printf '%s' "${cols[*]}")
    vals_sql=$(IFS=', '; printf '%s' "${vals[*]}")
    _knit_db_sql_ident table_ident "${_KNIT_PLUGIN_TABLE}"
    _knit_sqlite3_write "INSERT INTO ${table_ident} (${cols_sql}) VALUES (${vals_sql});"
}

# ------------------------------------------------------------------------------
# @fn _knit_plugin_materialize()
#
# Copy an imported plugin's pinned source tree from the shared content-addressed
# cache into the experiment's own ".knit/plugins/<host>/<org>/<repo>/", so the
# experiment directory carries a self-contained copy. The destination is replaced
# atomically-enough (removed then copied). A no-op when the cache tree is absent
# (e.g. the import was deferred offline), so bootstrap does not fail on it.
#
# @param[in] id Canonical id ("<host>/<org>/<repo>") of a plugin in the order set.
# ------------------------------------------------------------------------------
_knit_plugin_materialize() {
    local id="$1"
    local commit="${_KNIT_PLUGIN_COMMITS[${id}]:-}"
    local src="${_KNIT_PLUGIN_CACHE_ROOT}/${id}/${commit}"
    [[ -d "${src}" ]] || return 0
    local dest="${_KNIT_PREFIX}/plugins/${id}"
    mkdir -p "$(dirname "${dest}")"
    rm -rf "${dest}"
    cp -R "${src}" "${dest}"
}

# ------------------------------------------------------------------------------
# @fn _knit_plugin_bootstrap()
#
# Bootstrap-time integration for imported plugins, run from _knit_bootstrap (both
# first bootstrap and update mode). For every plugin imported by the experiment
# this invocation it writes the committed lockfile, ensures the plugins table,
# records a provenance row (idempotent), and materializes the pinned tree under
# .knit for a self-contained experiment directory. A no-op when nothing was
# imported.
# ------------------------------------------------------------------------------
_knit_plugin_bootstrap() {
    (( ${#_KNIT_PLUGIN_ORDER[@]} > 0 )) || return 0
    knit_info "Recording ${#_KNIT_PLUGIN_ORDER[@]} imported plugin(s)..."
    _knit_plugin_write_lockfile
    _knit_plugin_ensure_table
    local id
    for id in "${_KNIT_PLUGIN_ORDER[@]}"; do
        _knit_plugin_record_row "${id}"
        _knit_plugin_materialize "${id}"
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_plugins_lock()
#
# Body of "knit plugins lock": (re)write the committed lockfile from the plugins
# imported this invocation, without a full bootstrap. Useful on a fresh checkout
# to freeze the resolved commits before anything else. Reports, but does not
# fail, when no plugin was imported.
# ------------------------------------------------------------------------------
_knit_plugins_lock() {
    if (( ${#_KNIT_PLUGIN_ORDER[@]} == 0 )); then
        knit_info "No plugins imported; nothing to lock."
        return 0
    fi
    _knit_plugin_write_lockfile
    knit_info "Wrote ${_KNIT_PLUGIN_LOCKFILE} (${#_KNIT_PLUGIN_ORDER[@]} plugin(s))."
}

# ------------------------------------------------------------------------------
# @fn _knit_plugins_table_exists()
#
# Return 0 when the plugins provenance table exists in the database, 1 otherwise.
# The table is created at bootstrap only when the experiment imported at least
# one plugin, so its absence means "no plugins recorded" rather than an error.
# ------------------------------------------------------------------------------
_knit_plugins_table_exists() {
    local esc_table exists
    _knit_sql_escape esc_table "${_KNIT_PLUGIN_TABLE}"
    exists="$(_knit_sqlite3 \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='${esc_table}';")"
    [[ "${exists}" -gt 0 ]]
}

# ------------------------------------------------------------------------------
# @fn _knit_plugins_list()
#
# Body of "knit plugins list": print the plugins recorded in the database, one
# per line, with the canonical id, the requested ref, the resolved commit (short)
# and the importer, aligned into columns and ordered chronologically. Reports (and
# succeeds) when no plugin has been recorded.
# ------------------------------------------------------------------------------
_knit_plugins_list() {
    if ! _knit_plugins_table_exists; then
        knit_info "No plugins have been imported."
        return 0
    fi

    # char(31) (US) is the field delimiter: unlike a tab it is not an IFS
    # whitespace character, so "read" preserves an empty field (an empty ref or
    # importer) instead of collapsing it and shifting the columns.
    local commit_ident
    _knit_db_sql_ident commit_ident "commit"
    local rows
    rows="$(_knit_sqlite3 "SELECT host||'/'||org||'/'||repo||char(31)||ref||char(31)\
||${commit_ident}||char(31)||imported_by \
FROM ${_KNIT_PLUGIN_TABLE} ORDER BY installed_at, id;")"
    if [[ -z "${rows}" ]]; then
        knit_info "No plugins have been imported."
        return 0
    fi

    local -a ids=() refs=() commits=() importers=()
    local maxid=6 cid ref commit importer
    while IFS=$'\037' read -r cid ref commit importer; do
        [[ -z "${ref}" ]] && ref="<default>"
        [[ -z "${importer}" ]] && importer="(experiment)"
        ids+=("${cid}")
        refs+=("${ref}")
        commits+=("${commit:0:12}")
        importers+=("${importer}")
        (( ${#cid} > maxid )) && maxid=${#cid}
    done <<< "${rows}"

    printf '%-*s  %-10s  %-12s  %s\n' \
        "${maxid}" "PLUGIN" "REF" "COMMIT" "IMPORTED BY"
    local i
    for i in "${!ids[@]}"; do
        printf '%-*s  %-10s  %-12s  %s\n' \
            "${maxid}" "${ids[i]}" "${refs[i]}" "${commits[i]}" "${importers[i]}"
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_plugins_show()
#
# Body of "knit plugins show --id <selector>": print the full recorded metadata
# and provenance of a plugin. The selector matches a plugin's row id, its
# canonical id ("host/org/repo"), or its repository short name (with or without
# the "knit-" prefix of the blessed namespace), so "spack", "knit-spack", and
# "github.com/knit-sh/knit-spack" all select the same plugin. A plugin recorded at
# more than one commit over the experiment's life prints one block per recording,
# oldest first. No match is fatal.
# ------------------------------------------------------------------------------
_knit_plugins_show() {
    local sel
    sel="$(knit_get_parameter "id" "$@")"

    if ! _knit_plugins_table_exists; then
        knit_fatal "plugins show: no plugin matching \"${sel}\"."
    fi

    # char(31) field delimiter (see _knit_plugins_list) preserves empty fields.
    local sel_esc commit_ident
    _knit_sql_escape sel_esc "${sel}"
    _knit_db_sql_ident commit_ident "commit"
    local rows
    rows="$(_knit_sqlite3 "SELECT id||char(31)||spec||char(31)||host||char(31)||org\
||char(31)||repo||char(31)||ref||char(31)||${commit_ident}||char(31)||checksum\
||char(31)||imported_by||char(31)||installed_at \
FROM ${_KNIT_PLUGIN_TABLE} \
WHERE id='${sel_esc}' \
OR host||'/'||org||'/'||repo='${sel_esc}' \
OR repo='${sel_esc}' OR repo='knit-${sel_esc}' \
ORDER BY installed_at, id;")"
    if [[ -z "${rows}" ]]; then
        knit_fatal "plugins show: no plugin matching \"${sel}\"."
    fi

    local first=1 rid spec host org repo ref commit checksum importer installed_at when
    while IFS=$'\037' read -r rid spec host org repo ref commit checksum importer installed_at; do
        [[ "${first}" -eq 1 ]] || printf '\n'
        first=0
        [[ -z "${ref}" ]] && ref="<default branch>"
        [[ -z "${checksum}" ]] && checksum="<none>"
        [[ -z "${importer}" ]] && importer="(the experiment)"
        when="${installed_at}"
        if [[ "${installed_at}" =~ ^[0-9]+$ ]]; then
            when="$(date -d "@${installed_at}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                || printf '%s' "${installed_at}")"
        fi
        printf 'Plugin:       %s/%s/%s\n' "${host}" "${org}" "${repo}"
        printf 'Spec:         %s\n' "${spec}"
        printf 'Ref:          %s\n' "${ref}"
        printf 'Commit:       %s\n' "${commit}"
        printf 'Checksum:     %s\n' "${checksum}"
        printf 'Imported by:  %s\n' "${importer}"
        printf 'Installed at: %s\n' "${when}"
        printf 'Row id:       %s\n' "${rid}"
    done <<< "${rows}"
}

# ------------------------------------------------------------------------------
# @fn _knit_plugins_discover()
#
# Register the "plugins" subcommands. Called lazily by the framework the first
# time a plugins subcommand is resolved, listed in "--help", or walked by
# "describe".
#
# @param[in] parent The parent command's display name (unused).
# ------------------------------------------------------------------------------
_knit_plugins_discover() {
    knit_register "plugins:list" _knit_plugins_list \
        "List the plugins the experiment has imported, with their pins."
    _knit_is_builtin
    knit_done

    knit_register "plugins:show" _knit_plugins_show \
        "Show one plugin's recorded metadata and provenance."
    _knit_is_builtin
    knit_with_required "id:string" \
        "Plugin selector: a row id, a canonical id (host/org/repo), or a repository short name (with or without the \"knit-\" prefix)."
    knit_done

    knit_register "plugins:lock" _knit_plugins_lock \
        "(Re)write knit-plugins.lock from the imported plugins, without a full bootstrap."
    _knit_is_builtin
    knit_usable_before_bootstrap
    knit_done
}

knit_register "plugins" knit_empty "Inspect and manage the experiment's imported plugins."
_knit_is_builtin
knit_usable_before_bootstrap
knit_with_subcommand_discovery _knit_plugins_discover
knit_done
