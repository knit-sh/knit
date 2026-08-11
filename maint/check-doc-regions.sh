#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# check-doc-regions.sh
#
# Validate that every `literalinclude` region referenced by the Sphinx sources
# resolves: the included file must exist, and each `:start-after:` /
# `:end-before:` value must appear (as a substring, mirroring Sphinx semantics)
# in that file. This guarantees a documentation snippet can never silently
# vanish or be renamed out from under the prose that shows it.
#
# Include paths are resolved the way Sphinx resolves them: a leading `/` is
# relative to the documentation source root (so the Stitch Guide recipe
# fragments, which are inlined into pages in a different directory, can use an
# unambiguous `/_code/...` path); any other path is relative to the .rst file.
#
# Run standalone or via `make check-docs`.
# ----------------------------------------------------------------------------
set -uo pipefail

DOCS_ROOT="${1:-docs/source}"

if [[ ! -d "${DOCS_ROOT}" ]]; then
    echo "check-doc-regions: no such directory: ${DOCS_ROOT}" >&2
    exit 1
fi

errors=0
checked=0

while IFS= read -r rst; do
    rst_dir="$(dirname "${rst}")"
    target=""          # resolved path of the current literalinclude, "" if none
    inc_path=""        # as written in the directive (for messages)

    while IFS= read -r line; do
        # Start of a literalinclude directive.
        if [[ "${line}" =~ ^[[:space:]]*\.\.[[:space:]]+literalinclude::[[:space:]]*(.+)$ ]]; then
            inc_path="${BASH_REMATCH[1]}"
            inc_path="${inc_path%"${inc_path##*[![:space:]]}"}"   # rtrim
            if [[ "${inc_path}" == /* ]]; then
                target="${DOCS_ROOT%/}/${inc_path#/}"    # source-root-relative
            else
                target="${rst_dir}/${inc_path}"          # .rst-file-relative
            fi
            if [[ ! -f "${target}" ]]; then
                echo "${rst}: literalinclude target not found: ${inc_path}"
                errors=$((errors + 1))
                target=""
            fi
            continue
        fi

        [[ -n "${target}" ]] || continue

        if [[ "${line}" =~ ^[[:space:]]+:(start-after|end-before):[[:space:]]*(.+)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            val="${val%"${val##*[![:space:]]}"}"                 # rtrim
            checked=$((checked + 1))
            if ! grep -Fq -- "${val}" "${target}"; then
                echo "${rst}: ${key} marker not found in ${inc_path}: '${val}'"
                errors=$((errors + 1))
            fi
        elif [[ "${line}" =~ ^[[:space:]]+: ]]; then
            :                       # another literalinclude option, ignore
        elif [[ -z "${line//[[:space:]]/}" ]]; then
            target=""               # blank line ends the directive block
        elif [[ ! "${line}" =~ ^[[:space:]] ]]; then
            target=""               # non-indented line ends the directive block
        fi
    done < "${rst}"
done < <(find "${DOCS_ROOT}" -name '*.rst' -type f | sort)

if [[ ${errors} -gt 0 ]]; then
    echo "check-doc-regions: ${errors} problem(s) found." >&2
    exit 1
fi
echo "check-doc-regions: ${checked} region reference(s) valid."
