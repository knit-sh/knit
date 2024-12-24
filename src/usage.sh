#!/bin/bash

# ------------------------------------------------------------------------------
# Print the usage of the script.
# ------------------------------------------------------------------------------
_knit_print_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

This script performs the following tasks:
  - Option 1: Does something useful.
  - Option 2: Does something else.
  - Option 3: Yet another useful task.

Options:
  -h, --help    Show this help message and exit.
  -v, --version Show the version of the script.

Example:
  $0 --help
EOF
}
