#!/bin/bash

# Minimal experiment used to exercise the `knit bootstrap` command lines shown in
# the Bootstrap stitch recipes. It registers no commands of its own --- bootstrap,
# metadata, and query are all built in --- so the driver can bootstrap it with the
# documented flags and read the resulting configuration back out. Kept to the
# local backend so it runs anywhere with just bash and sqlite3.

source knit.sh

@set_program_description "Bootstrap recipes demo experiment."

knit "$@"
