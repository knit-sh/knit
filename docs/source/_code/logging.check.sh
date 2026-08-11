#!/usr/bin/env bash
# Driver for logging.sh (not shown in the documentation). Bootstraps the
# experiment and exercises the log-level threshold (default and raised), the
# knit_log_set_level call from a body, and the non-TTY passthrough of
# knit_framed.
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

exp bootstrap --project logging-demo --scheduler local >/dev/null

# At the default level (info) everything from info down to error shows, and the
# body still runs. Match on the message text: the "[knit:LEVEL]" prefix contains
# brackets, which are glob metacharacters in check_contains.
export KNIT_LOG_LEVEL=info
out="$(exp work 2>&1)"
check_contains "${out}" "starting the computation" "info messages show at info level"
check_contains "${out}" "input looks unusually large" "warning messages show"
check_contains "${out}" "a recoverable step failed" "error messages show"
check_contains "${out}" "done" "the command body runs to completion"
debug_hits="$(printf '%s\n' "${out}" | grep -cF 'computing the result' || true)"
check_eq "${debug_hits}" "0" "debug messages are suppressed at info level"

# Raising the level to warning suppresses info while keeping warnings/errors.
export KNIT_LOG_LEVEL=warning
out="$(exp work 2>&1)"
info_hits="$(printf '%s\n' "${out}" | grep -cF 'starting the computation' || true)"
check_eq "${info_hits}" "0" "info is suppressed at warning level"
check_contains "${out}" "input looks unusually large" "warnings still show at warning level"

# knit_log_set_level warning from the body has the same effect, even when the
# environment asks for info.
export KNIT_LOG_LEVEL=info
out="$(exp quiet 2>&1)"
info_hits="$(printf '%s\n' "${out}" | grep -cF 'starting the computation' || true)"
check_eq "${info_hits}" "0" "knit_log_set_level warning silences info from the body"
check_contains "${out}" "input looks unusually large" "warnings survive knit_log_set_level"

# knit_framed forwards stdin unchanged on a non-TTY, so the captured output is
# exactly the framed command's output.
out="$(exp build)"
check_contains "${out}" "step 1/3" "framed output passes through on a non-TTY (first line)"
check_contains "${out}" "step 3/3" "framed output passes through on a non-TTY (last line)"

dc_summary
