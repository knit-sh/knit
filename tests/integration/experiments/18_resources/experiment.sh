#!/usr/bin/env bash
# Integration test experiment 18_resources.
#
# A download-only experiment that exercises the resources subsystem end to end:
#
#   - a git resource type ("srctree") cloned from a repository, recording the
#     resolved commit SHA;
#   - a url resource type ("dataset") downloaded and unpacked from an archive;
#   - a plain recorded consumer ("combine") that declares both resources with
#     knit_with_resource and reads them through knit_resource_path, recording a
#     row and a "used_by" provenance edge from each resource to the consumer.
#
# The source locations are read from the environment so the companion test.sh can
# point them at local (file://) sources built in the work directory. This keeps
# the test hermetic: no external host is contacted, yet the real git and curl
# backends run. Both fetches materialize read-only instances under resources/.

source knit.sh

knit_set_program_description "knit resources end-to-end integration test experiment."

# --------------------------------------------------------------------------
# git backend: clone a source tree from a repository at a pinned ref. The URL
# and ref come from the environment (test.sh builds a local repo and tags it).
# --------------------------------------------------------------------------
knit_register_resource "srctree" "A source tree fetched from git."
knit_with_git "${RES_GIT_URL}" "${RES_GIT_REF}"
knit_done

# --------------------------------------------------------------------------
# url backend: download and unpack a dataset archive. The URL comes from the
# environment (test.sh builds a local tarball served over file://).
# --------------------------------------------------------------------------
knit_register_resource "dataset" "A dataset archive downloaded over a URL."
knit_with_url "${RES_URL}"
knit_done

# --------------------------------------------------------------------------
# A plain recorded consumer that depends on both resources. It resolves each
# instance name to its on-disk path and reads the fetched artifacts, recording
# the number of dataset records so the "used_by" edges have a target row.
# --------------------------------------------------------------------------
knit_register "combine" _combine "Read a fetched source tree and dataset."
knit_with_resource "src:srctree"  "Name of the fetched source tree instance."
knit_with_resource "data:dataset" "Name of the fetched dataset instance."
knit_with_table
knit_with_output "records:integer" "0" "Number of dataset records read."
_combine() {
    local srcdir datadir
    srcdir="$(knit_resource_path "$(knit_get_parameter src "$@")")"
    datadir="$(knit_resource_path "$(knit_get_parameter data "$@")")"
    local n
    n=$(wc -l < "${datadir}/records.txt")
    knit_output "records" "${n}"
    printf 'combine: %s + %s -> %s record(s)\n' \
        "$(cat "${srcdir}/name.txt")" "${datadir}" "${n}"
}
knit_done

knit "$@"
