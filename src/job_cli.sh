#!/bin/bash

## @file job_cli.sh
##
## Commands for inspecting submitted jobs (`job list`, `job status`, `job wait`,
## `job show`, ...). Job *submission* lives in `job.sh`; this file holds the
## read-side commands that query the `jobs` table and a job's working directory.

# ------------------------------------------------------------------------------
# Registration of the job command group.
# ------------------------------------------------------------------------------
knit_register knit_empty job "Inspect submitted jobs."
knit_done
