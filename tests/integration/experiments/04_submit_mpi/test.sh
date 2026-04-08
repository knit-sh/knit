#!/usr/bin/env bash
# Integration test 04_submit_mpi — SKIPPED.
#
# This test will verify:
#   - A setup that compiles an MPI program (using the cluster's MPI library)
#   - knit run dispatches an MPI job across compute nodes
#   - All MPI ranks communicate correctly; output is captured in the DB
#
# Skipped until knit run (MPI placement + launcher) is implemented
# (see ACTIONS.md Phase 3).
# ------------------------------------------------------------------------------
printf 'SKIP: 04_submit_mpi — knit run not yet implemented\n'
exit 0
