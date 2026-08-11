#!/usr/bin/env bash
# Driver for parameters.sh (not shown in the documentation). Bootstraps the
# experiment and exercises every parameter feature the Parameters page introduces:
# a required parameter, an optional parameter and a flag, an environment-backed
# default, a reusable parameter set, opaque trailing arguments, and a plain helper
# validating its own arguments.
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

exp bootstrap --project parameters-demo --scheduler local >/dev/null

# greet: a required parameter, read back with knit_get_parameter.
check_eq "$(exp greet --name Ada)" "Hello Ada" "the required parameter is read"

# shout: optional parameter default, and a flag read back as true/false.
check_eq "$(exp shout)" "Hello World" "the optional default applies"
check_eq "$(exp shout --name Ada)" "Hello Ada" "the optional parameter overrides the default"
check_eq "$(exp shout --name Ada --excited)" "Hello Ada!" "the flag is read as true when present"

# roll: ENV[SEED] default falls back to $SEED, or empty when unset.
check_eq "$(exp roll)" "seed=" "the env default is empty when the variable is unset"
check_eq "$(SEED=42 exp roll)" "seed=42" "the env default reads the environment variable"
check_eq "$(exp roll --seed 7)" "seed=7" "an explicit value overrides the env default"

# area: parameters imported from the "grid" parameter set.
check_eq "$(exp area --width 3 --height 4)" "12" "the imported parameter set works"

# forward: everything after -- is forwarded to the body.
check_eq "$(exp forward -- a b c)" "a b c" "trailing arguments are forwarded"

# render: the plain helper validates its own arguments (happy path).
check_eq "$(exp render --size 4)" "size=4" "a plain helper validates its own arguments"

dc_summary
