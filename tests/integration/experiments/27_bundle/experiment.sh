#!/usr/bin/env bash
# Integration test experiment 27_bundle.
#
# Exercises `knit bundle` and `knit export ro-crate` end to end on a live
# scheduler. It declares:
#
#   - a side file Knit does not track, listed with knit_bundle_requires so the
#     bundle carries it (config/params.txt);
#   - a local resource "dataset" — excluded from the bundle by default,
#     re-fetchable from its recorded source, and packed only on demand with
#     --include-resources;
#   - a job "produce" that writes two artifacts: one in-tree file, and one that
#     references an OUT-OF-TREE file in place through an absolute-target symlink
#     under artifacts/. `knit bundle` must dereference that symlink so the content
#     travels in the archive instead of a link that would dangle on a reproducer's
#     machine.
#
# Everything runs through the job path so the archive holds a real job directory
# (log, script) and a real artifacts/ tree.

source knit.sh

knit_set_program_description "bundle integration test experiment."

# A side file the experiment needs but Knit does not otherwise track. Recorded
# verbatim; validated (exists, relative, in-tree) only when `knit bundle` runs.
knit_bundle_requires "config/params.txt"

# --------------------------------------------------------------------------
# A local resource. Fetched into resources/<name>; excluded from the bundle by
# default (re-fetchable), packed with --include-resources.
# --------------------------------------------------------------------------
knit_register_resource "dataset" "A dataset staged from a local path."
knit_with_local "./staged"
knit_done

# --------------------------------------------------------------------------
# Job "produce" — an in-tree artifact and an out-of-tree linked artifact.
# knit_register_job backs the job with a table named after it, so no
# knit_with_table is needed.
# --------------------------------------------------------------------------
knit_register_job "produce" __produce_job_fn \
    "Produce an in-tree result and an out-of-tree linked artifact."
knit_with_required "link_target:string" \
    "Absolute path of an out-of-tree file to reference in place."
knit_with_output_artifact "result:file" "An in-tree result file."
knit_with_output_artifact "linked:file" "A result referenced in place by an out-of-tree symlink."
__produce_job_fn() {
    local target out
    target=$(knit_get_parameter "link_target" "$@")

    out="$(knit_artifact_dir)"
    mkdir -p "${out}"

    # An ordinary in-tree artifact, written straight into artifacts/.
    printf 'result: 42\n' > "${out}/result.txt"
    knit_artifact "result" "result.txt"

    # Reference an out-of-tree file in place: knit records an absolute-target
    # symlink under artifacts/, which `knit bundle` must dereference.
    knit_artifact "linked" "linked.txt" --link-from "${target}"

    printf 'produce done\n'
}
knit_done

knit "$@"
