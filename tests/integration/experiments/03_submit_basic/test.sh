#!/usr/bin/env bash
# Integration test 03_submit_basic — SKIPPED.
#
# This test will verify:
#   - knit submit dispatches a job to the cluster scheduler
#   - The job runs, its stdout is captured, a DB entry is created
#   - knit stdout --id <uuid> retrieves the captured output
#
# Skipped until knit submit (job script generation + cluster submission) is
# implemented (see ACTIONS.md Phase 3).
# ------------------------------------------------------------------------------
printf 'SKIP: 03_submit_basic — knit submit not yet implemented\n'
exit 0
