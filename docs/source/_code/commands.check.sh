#!/usr/bin/env bash
# Driver for commands.sh (not shown in the documentation). Bootstraps the
# experiment and exercises every command the Commands page introduces: a plain
# command, a nested subcommand, a dispatcher, a hidden command, and a gated
# command (blocked and unblocked).
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

exp bootstrap --project commands-demo --scheduler local >/dev/null

# hello: a plain command with a body.
check_eq "$(exp hello)" "Hello World" "hello prints the greeting"

# say hello / say goodbye: subcommands nested under the knit_empty parent "say".
check_eq "$(exp say hello)" "Hello" "the first nested subcommand runs"
check_eq "$(exp say goodbye)" "Goodbye" "the second nested subcommand runs"

# tool: a dispatcher forwards everything after -- to its body.
check_eq "$(exp tool -- render --size 4)" "running: render --size 4" \
    "the dispatcher forwards the trailing arguments"

# internal: hidden from --help but still invokable.
check_eq "$(exp internal)" "internal" "a hidden command still runs"
help="$(exp --help 2>&1)"
check_contains "${help}" "hello" "--help lists the visible command"
hidden_hits="$(printf '%s\n' "${help}" | grep -c 'internal' || true)"
check_eq "${hidden_hits}" "0" "--help hides the hidden command"

# danger: gated by knit_usable_if. Blocked without the predicate, allowed with it.
if blocked="$(exp danger 2>&1)"; then
    check_eq "ran" "blocked" "danger must not run while blocked"
else
    check_contains "${blocked}" "ALLOW_DANGER=1" \
        "a blocked command explains why it cannot run"
fi

export ALLOW_DANGER=1
check_eq "$(exp danger)" "danger performed" "the gated command runs once allowed"
unset ALLOW_DANGER

# featured: highlighting is cosmetic, so the command runs and is listed as usual.
check_eq "$(exp featured)" "featured" "a highlighted command runs normally"
check_contains "${help}" "featured" "--help lists the highlighted command"

dc_summary
