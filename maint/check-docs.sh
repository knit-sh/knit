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
LONG_DIR="${ROOT}/docs/source/_code_long"
CONVERTER="${ROOT}/docs/source/_ext/knit_shorthand.py"
KNIT_SH="${ROOT}/knit.sh"
export KNIT_DOC_LIB="${ROOT}/maint/doc-check-lib.sh"

if [[ ! -f "${KNIT_SH}" ]]; then
    echo "check-docs: ${KNIT_SH} not found; run 'make' first." >&2
    exit 1
fi

# ----------------------------------------------------------------------------
# Exercise one example file the way documented experiments are checked: a
# "source-only" marker means syntax-check only; a <base>.check.sh driver means
# run the driver; otherwise syntax-check and confirm --help runs.
#
# $1 example path, $2 filename to run it under, $3 driver path (may be absent),
# $4 a label for the output. Returns non-zero on failure.
# ----------------------------------------------------------------------------
exercise_example() {
    local exp="$1" name="$2" driver="$3" label="$4"
    local workdir rc=0
    workdir="$(mktemp -d)"
    cp "${KNIT_SH}" "${workdir}/knit.sh"
    cp "${exp}" "${workdir}/${name}"
    chmod +x "${workdir}/${name}"
    if grep -q '^# doc-check: source-only' "${exp}"; then
        if ( cd "${workdir}" && bash -n "${name}" ); then
            echo "  ok   ${label}: syntax (source-only)"
        else
            echo "  FAIL ${label}: syntax error (source-only)"
            rc=1
        fi
    elif [[ -f "${driver}" ]]; then
        if ( cd "${workdir}" && EXP="${name}" bash "${driver}" ); then
            :
        else
            rc=1
        fi
    else
        if ( cd "${workdir}" && bash -n "${name}" && ./"${name}" --help >/dev/null 2>&1 ); then
            echo "  ok   ${label}: syntax + --help (no driver)"
        else
            echo "  FAIL ${label}: syntax or --help failed (no driver)"
            rc=1
        fi
    fi
    rm -rf "${workdir}"
    return ${rc}
}

# ----------------------------------------------------------------------------
# Dump the command registrations of an example as compact "describe" JSON, used
# as the converter drift guard. "describe" introspects the registration tables
# without running any command body, so it works for every example (source-only
# ones included) and is stable to compare. $1 example path, $2 filename to run
# it under, $3 output file. Returns non-zero if describe fails.
# ----------------------------------------------------------------------------
describe_dump() {
    local exp="$1" name="$2" out="$3" workdir rc
    workdir="$(mktemp -d)"
    cp "${KNIT_SH}" "${workdir}/knit.sh"
    cp "${exp}" "${workdir}/${name}"
    ( cd "${workdir}" && bash "${name}" describe --format json --compact ) \
        >"${out}" 2>/dev/null
    rc=$?
    rm -rf "${workdir}"
    return ${rc}
}

total=0
failed=0

echo "== shorthand converter selftest =="
if python3 "${CONVERTER}" --selftest; then
    :
else
    failed=$((failed + 1))
fi
echo

# Generate the long-form tree from the shorthand sources. Every documented
# example is then exercised in both forms, and each generated long form must
# register the same commands as its shorthand original (converter drift guard).
echo "== generate long-form tree =="
if python3 "${CONVERTER}" --generate "${CODE_DIR}" "${LONG_DIR}"; then
    echo "  ok   generated $(find "${LONG_DIR}" -maxdepth 1 -name '*.sh' | wc -l) file(s)"
else
    echo "  FAIL long-form generation"
    failed=$((failed + 1))
fi
echo

if [[ -d "${CODE_DIR}" ]]; then
    while IFS= read -r exp; do
        case "${exp}" in
            *.check.sh) continue ;;   # drivers, not examples
        esac
        total=$((total + 1))
        name="$(basename "${exp}")"
        base="${name%.sh}"
        driver="${CODE_DIR}/${base}.check.sh"
        long_exp="${LONG_DIR}/${name}"

        echo "== ${name} =="
        exercise_example "${exp}" "${name}" "${driver}" "shorthand" \
            || failed=$((failed + 1))

        if [[ ! -f "${long_exp}" ]]; then
            echo "  FAIL long-form file was not generated"
            failed=$((failed + 1))
        elif cmp -s "${exp}" "${long_exp}"; then
            # No "@" shorthand: the long form is identical, so it is neither
            # re-exercised nor drift-checked (the two forms are the same file).
            echo "  ok   no shorthand (long form identical)"
        else
            exercise_example "${long_exp}" "${name}" "${driver}" "long form" \
                || failed=$((failed + 1))

            short_reg="$(mktemp)"
            long_reg="$(mktemp)"
            if describe_dump "${exp}" "${name}" "${short_reg}" \
                && describe_dump "${long_exp}" "${name}" "${long_reg}"; then
                if diff -q "${short_reg}" "${long_reg}" >/dev/null; then
                    echo "  ok   registrations match (drift guard)"
                else
                    echo "  FAIL registrations differ between the two forms"
                    failed=$((failed + 1))
                fi
            else
                echo "  FAIL could not compare registrations (describe failed)"
                failed=$((failed + 1))
            fi
            rm -f "${short_reg}" "${long_reg}"
        fi
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
