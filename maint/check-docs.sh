#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# check-docs.sh
#
# Exercise every documentation code example end to end on the portable local
# backend, then validate that all literalinclude regions referenced by the
# Sphinx sources resolve. Invoked by `make check-docs`.
#
# For each docs/source/_code/<name>.sh (an experiment shown in the docs):
#   * if docs/source/_code/<name>.check.sh exists, run it as the driver — it
#     bootstraps and drives the experiment and asserts the documented behavior;
#   * if the experiment is marked `# doc-check: source-only` (a snippet that
#     cannot run in plain CI, e.g. it needs a live Spack), only syntax-check it;
#   * otherwise, syntax-check it and confirm `--help` runs.
#
# Each example runs in a throwaway temp directory holding a copy of knit.sh and
# the experiment, so the bare `source knit.sh` the examples use resolves exactly
# as it would for a user.
# ----------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODE_DIR="${ROOT}/docs/source/_code"
KNIT_SH="${ROOT}/knit.sh"
export KNIT_DOC_LIB="${ROOT}/maint/doc-check-lib.sh"

if [[ ! -f "${KNIT_SH}" ]]; then
    echo "check-docs: ${KNIT_SH} not found; run 'make' first." >&2
    exit 1
fi

total=0
failed=0

if [[ -d "${CODE_DIR}" ]]; then
    while IFS= read -r exp; do
        case "${exp}" in
            *.check.sh) continue ;;   # drivers, not examples
        esac
        total=$((total + 1))
        name="$(basename "${exp}")"
        base="${name%.sh}"
        driver="${CODE_DIR}/${base}.check.sh"

        workdir="$(mktemp -d)"
        cp "${KNIT_SH}" "${workdir}/knit.sh"
        cp "${exp}" "${workdir}/${name}"
        chmod +x "${workdir}/${name}"

        echo "== ${name} =="
        if grep -q '^# doc-check: source-only' "${exp}"; then
            if ( cd "${workdir}" && bash -n "${name}" ); then
                echo "  ok   syntax (source-only)"
            else
                echo "  FAIL syntax error (source-only)"
                failed=$((failed + 1))
            fi
        elif [[ -f "${driver}" ]]; then
            if ( cd "${workdir}" && EXP="${name}" bash "${driver}" ); then
                :
            else
                failed=$((failed + 1))
            fi
        else
            if ( cd "${workdir}" && bash -n "${name}" && ./"${name}" --help >/dev/null 2>&1 ); then
                echo "  ok   syntax + --help (no driver)"
            else
                echo "  FAIL syntax or --help failed (no driver)"
                failed=$((failed + 1))
            fi
        fi
        rm -rf "${workdir}"
    done < <(find "${CODE_DIR}" -maxdepth 1 -name '*.sh' -type f | sort)
fi

echo
echo "== literalinclude regions =="
if ! bash "${ROOT}/maint/check-doc-regions.sh" "${ROOT}/docs/source"; then
    failed=$((failed + 1))
fi

echo
if [[ ${failed} -gt 0 ]]; then
    echo "check-docs: ${failed} failure(s) across ${total} example(s) + region check." >&2
    exit 1
fi
echo "check-docs: ${total} example(s) passed; regions valid."
