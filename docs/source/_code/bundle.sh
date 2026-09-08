#!/bin/bash
#
# Showcase for the "Bundle & export" recipes: knit_bundle_requires and knit
# bundle. This experiment declares a couple of side files that Knit does not
# otherwise track, then runs a job that produces an artifact --- so the driver
# (bundle.check.sh) can pack a self-contained archive, list its planned
# contents, and export its RO-Crate manifest.
#
# Everything runs on the portable local backend (no scheduler, no MPI), so
# check-docs drives the whole produce-then-bundle lifecycle end to end.

source knit.sh

knit_set_program_description "Produce a result, then pack it into a shippable bundle."

# START requires
# Files Knit does not track but the experiment needs. Listed at the top of the
# script (a top-level declaration, like knit_set_program_description), they are
# added to every `knit bundle`. Paths are relative to this script: a plain path
# is a single file or directory, and a glob is expanded at bundle time so every
# match is packed.
knit_bundle_requires "config/params.yaml"
knit_bundle_requires "inputs/*.dat"
# END requires

# A job that writes a result artifact, so the bundle has a recorded run, a log,
# and a result to carry. It needs no setup of its own: it adopts the builtin
# default setup that bootstrap instantiates.
@job "crunch" "Produce a result artifact."
@with_output_artifact "result:file" "The computed result."
_crunch() {
    local out
    out="$(knit_artifact_dir)"
    mkdir -p "${out}"
    printf 'result: 42\n' > "${out}/result.txt"
    knit_artifact "result" "result.txt"
    printf 'crunch done\n'
}
@done

knit "$@"
