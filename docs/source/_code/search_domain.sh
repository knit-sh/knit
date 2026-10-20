#!/bin/bash

# Showcase for declaring a parameter's search domain with --domain (and the --log
# scale hint for a real range), then discovering the declared domains with
# "knit describe --space". Kept to the local backend so it runs anywhere with
# just bash and sqlite3.

source knit.sh

# START domain
# Declare each tunable parameter's search domain with --domain. Quote the
# descriptor: the shell would otherwise brace-expand {a,b,c}. --log marks a real
# range as log-scaled (a hint a Bayesian-optimization proposer reads; a sweep
# ignores it). The domain is validated against the parameter's type the first
# time it is read, not at registration.
@command "train" "Train a model over a search space."
@with_optional "lr:real"        "0.01" "Learning rate." --domain '[1e-5..1.0]' --log
@with_optional "batch:integer"  "32"   "Batch size."    --domain '{16,32,64,128}'
@with_optional "layers:integer" "4"    "Hidden layers." --domain '[2..12]'
@with_optional "data:string"    ""     "Training data." --domain '@glob:data/*.csv'
_train() {
    echo "lr=$(knit_get_parameter lr "$@") batch=$(knit_get_parameter batch "$@")"
}
@done
# END domain

knit "$@"
