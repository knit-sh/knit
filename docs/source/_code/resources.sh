#!/bin/bash
#
# Resources tour snapshot: declare a downloadable input artifact (a "dataset"
# resource), fetch a named instance of it with `knit fetch`, and consume that
# instance from a command with @with_resource / knit_resource_path.
#
# The example uses the `local` backend so it runs entirely offline (the driver
# stages a directory on disk and fetches it by path). The git and url backends
# are one decorator away: swap @with_local for @with_git <url> <ref> or
# @with_url <url> and nothing else changes.

source knit.sh

@set_program_description "Fetch an input dataset, then summarize it."

# START register
# A resource TYPE declares HOW to acquire an artifact --- exactly one download
# decorator selects the backend. The local backend links (or, with --copy, snapshots)
# a path already on disk; swap in @with_git <url> <ref> or @with_url <url>
# to download instead. There is no body: knit supplies the download itself.
@resource "dataset" "An input dataset staged from a local path."
@with_local "./data"
@done
# END register

# START consume
# A command declares the resources it needs with @with_resource
# "<param>:<type>". The value the user passes is the instance NAME, not a path;
# knit validates that the named instance exists and is of the right type before the
# body runs, then knit_resource_path turns the name into an on-disk directory.
@command "summarize" "Summarize a fetched dataset."
@with_resource "data:dataset" "Name of the dataset instance to read."
@with_table
@with_output "lines:integer" "0" "Number of lines in the dataset."
_summarize() {
    local dir
    dir="$(knit_resource_path "$(knit_get_parameter data "$@")")"

    local n
    n=$(wc -l < "${dir}/values.txt")
    knit_output "lines" "${n}"
    printf 'dataset %s has %s line(s)\n' "${dir}" "${n}"
}
@done
# END consume

knit "$@"
