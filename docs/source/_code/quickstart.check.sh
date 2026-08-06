#!/usr/bin/env bash
# Driver for quickstart.sh (not shown in the documentation). Bootstraps the
# experiment and exercises every command the Quickstart page introduces,
# asserting the printed output and, for "add", the recorded row.
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

exp bootstrap --project quickstart >/dev/null

# hello: no parameters, no output.
check_eq "$(exp hello)" "Hello World" "hello prints the greeting"

# say: a single required string parameter.
check_eq "$(exp say --message 'good morning')" \
    "User said 'good morning'" "say echoes the message"

# greet: required parameter, optional parameter, boolean flag.
check_eq "$(exp greet --name Alice)" "Hello, Alice!" \
    "greet with only the required parameter"
check_eq "$(exp greet --name Curie --title Prof.)" \
    "Hello, Prof. Curie!" "greet with the optional title"
check_eq "$(exp greet --name Curie --title Prof. --capitalize)" \
    "HELLO, PROF. CURIE!" "greet with the capitalize flag"

# scale: required + optional parameter, plus an emitted output.
check_eq "$(exp scale --value 21)" "result=42" "scale uses the default factor"
check_eq "$(exp scale --value 10 --factor 5)" "result=50" "scale honors --factor"

# add: two required parameters, an output, and a table, so the run is recorded.
check_eq "$(exp add --x 2 --y 3)" "total=5" "add prints the total"
row="$(exp query sql --exec 'SELECT total FROM "add" WHERE x = 2 AND y = 3' \
    2>/dev/null | tr -d '[:space:]')"
check_contains "${row}" "5" "add records total=5"

dc_summary
