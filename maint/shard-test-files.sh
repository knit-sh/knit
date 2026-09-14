#!/usr/bin/env bash
#
# shard-test-files.sh
#
# Print the bats unit-test files assigned to one shard, one basename per line.
#
# Usage: shard-test-files.sh <index> <total>
#   <index>  0-based shard number (0 <= index < total)
#   <total>  number of shards (positive integer)
#
# Files are assigned round-robin over the sorted tests/test_*.sh list: the i-th
# file (0-based) goes to shard (i mod total). This spreads the files evenly
# across shards without needing per-file run times. The union of shards
# 0..total-1 is exactly the full file list, with no file in two shards. When
# <total> is larger than the file count, the trailing shards are empty (no
# output), which the caller is expected to handle.
#
# Used by .github/workflows/codecov.yml to run coverage in a fixed number of
# shards (one uploaded artifact per shard) instead of one job per file, which
# keeps the artifact-upload count bounded as the test suite grows.
#
# The tests/test_*.sh glob excludes tests/setup_teardown.sh (shared helpers, not
# a test file) by construction, matching list-test-files.sh.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $(basename "$0") <index> <total>" >&2
  exit 2
fi

index=$1
total=$2

if [[ ! ${index} =~ ^[0-9]+$ ]] || [[ ! ${total} =~ ^[0-9]+$ ]]; then
  echo "error: <index> and <total> must be non-negative integers" >&2
  exit 2
fi

if (( total < 1 )); then
  echo "error: <total> must be at least 1" >&2
  exit 2
fi

if (( index >= total )); then
  echo "error: <index> (${index}) must be less than <total> (${total})" >&2
  exit 2
fi

# Run from tests/ so the glob expands to bare basenames, matching
# list-test-files.sh (and regardless of the caller's working directory).
cd "$(dirname "$0")/../tests"

# nullglob so a directory with no matching files yields no output (not the
# literal pattern), which also makes empty trailing shards behave correctly.
shopt -s nullglob

i=0
for f in test_*.sh; do
  if (( i % total == index )); then
    printf '%s\n' "${f}"
  fi
  i=$((i + 1))
done
