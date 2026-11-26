#!/usr/bin/env bash
# Integration test experiment 42_tool_cache.
# A minimal knit experiment script — sources knit.sh and dispatches to knit().
# No commands are registered; this experiment only exercises bootstrap and the
# framework-tool cache.

source knit.sh

knit_set_program_description "Tool-cache integration test experiment."

knit "$@"
