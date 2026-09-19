#!/bin/bash
#
# Showcase for the "Cleanup" recipes: knit remove. This experiment builds a
# small provenance lineage that remove then prunes ---
#
#     resource srcpkg --used_by--> setup env --used_by--> job crunch --produced--> artifact
#
# so the driver (remove.check.sh) can exercise every removal mode: a dry-run
# preview, removal by --name / --type / --id, the whole-lineage --from-root
# removal, and --keep-files.
#
# Everything runs on the portable local backend (no scheduler, no MPI), so
# check-docs drives the build-then-remove lifecycle end to end.

source knit.sh

knit_set_program_description "Build a small lineage, then prune it with knit remove."

# A resource TYPE: a source package staged from a local path (the driver stages
# the directory). The setup below consumes an instance of it.
@resource "srcpkg" "A source package staged from a local path."
@with_local "./pkg"
@done

# A setup that consumes a srcpkg instance. Depending on the resource records a
# used_by edge resource --> setup, so removing the resource cascades to the setup
# (and removing the setup leaves the resource in place).
@setup "env" "Build environment from a source package."
@with_resource "src:srcpkg" "Name of the srcpkg instance to build from."
_env_setup() {
    local dir
    dir="$(knit_resource_path "$(knit_get_parameter src "$@")")"
    # A stand-in "build": copy the staged marker into the setup prefix.
    cp "${dir}/marker.txt" "${KNIT_SETUP_PREFIX}/marker.txt"
    printf 'built env from %s\n' "${dir}"
}
@done

# A job that runs in the setup and produces an artifact. @with_setup records
# a used_by edge setup --> job; @with_output_artifact + knit_artifact record the
# produced edge job --> artifact.
@job "crunch" "Produce a result inside the env setup."
@with_setup "env"
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

# START failing
# A command that records a row and may fail. Because it declares a table and is
# NOT @no_record_on_failure, knit adds a reserved __exit_status__ column and
# records it on every invocation: 0 on success, the non-zero code on failure. A
# failed row stays in the database (with any output it produced) so you can query
# what failed, and prune it later with `remove --failed`.
@command "boom" "Fail when --code is non-zero, so a failed row is recorded."
@with_table
@with_optional "code:integer" "0" "Exit code to return."
_boom() {
    return "$(knit_get_parameter code "$@")"
}
@done
# END failing

knit "$@"
