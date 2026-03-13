#!/bin/bash
#
# Check that functions and global variables in a bash source file have proper
# Doxygen comment blocks.
#
# A valid comment block starts and ends with a separator line (# -----...) and
# must appear immediately before the function or variable declaration.
# For functions, the block must also contain @fn function_name().
#
# Global variables are detected via:
#   - 'declare' statements at column 0
#   - Assignments at column 0 matching the KNIT naming convention
#     (_*KNIT_VARNAME=...), unless immediately following a 'declare' of the
#     same variable.
#
# Usage: doccheck.sh <file>
#
# Exit codes:
#   0 - all checks passed
#   1 - documentation issues found
#   2 - usage error

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <file>" >&2
    exit 2
fi

file="$1"

if [ ! -f "$file" ]; then
    echo "Error: file '${file}' not found." >&2
    exit 2
fi

mapfile -t lines < "$file"
total=${#lines[@]}
errors=0

# Returns 0 if the line is a separator (# followed by at least 4 dashes).
is_separator() {
    [[ "$1" =~ ^#[[:space:]]*-{4,} ]]
}

# Given a 0-indexed line number, search backwards for a valid comment block.
# A valid block starts and ends with a separator line, with comment lines
# (starting with #) in between. The closing separator must be immediately
# before the target line.
# Sets COMMENT_BLOCK with the block content.
# Returns 0 if found, 1 otherwise.
find_comment_block() {
    local target=$1
    local i=$((target - 1))
    COMMENT_BLOCK=""

    # The line immediately before must be a closing separator
    if [ "$i" -lt 0 ]; then
        return 1
    fi
    if ! is_separator "${lines[$i]}"; then
        return 1
    fi

    COMMENT_BLOCK="${lines[$i]}"
    i=$((i - 1))

    # Walk backwards through comment lines looking for the opening separator
    while [ "$i" -ge 0 ]; do
        if ! [[ "${lines[$i]}" =~ ^# ]]; then
            break
        fi
        COMMENT_BLOCK="${lines[$i]}"$'\n'"${COMMENT_BLOCK}"
        if is_separator "${lines[$i]}"; then
            return 0
        fi
        i=$((i - 1))
    done

    COMMENT_BLOCK=""
    return 1
}

# Regexes stored in variables so bash =~ handles them correctly.
func_re='^([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\(\)'
declare_re='^declare[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*([a-zA-Z_][a-zA-Z0-9_]*)'
assign_re='^(_*KNIT_[A-Z0-9_]*)\+?='

prev_declare_var=""

for ((i = 0; i < total; i++)); do
    line="${lines[$i]}"
    line_num=$((i + 1))

    # Function definition at column 0
    if [[ "$line" =~ $func_re ]]; then
        func_name="${BASH_REMATCH[1]}"
        prev_declare_var=""

        if ! find_comment_block "$i"; then
            echo "${file}:${line_num}: function '${func_name}()' has no comment block."
            errors=$((errors + 1))
            continue
        fi

        if [[ ! "$COMMENT_BLOCK" =~ @fn[[:space:]]+${func_name}\(\) ]]; then
            echo "${file}:${line_num}: function '${func_name}()' comment block missing '@fn ${func_name}()'."
            errors=$((errors + 1))
        fi
        continue
    fi

    # declare statement at column 0
    if [[ "$line" =~ $declare_re ]]; then
        var_name="${BASH_REMATCH[2]}"

        if ! find_comment_block "$i"; then
            echo "${file}:${line_num}: variable '${var_name}' has no comment block."
            errors=$((errors + 1))
        fi

        prev_declare_var="$var_name"
        continue
    fi

    # Global variable assignment matching KNIT naming convention at column 0.
    # Skip if it immediately follows a declare for the same variable.
    if [[ "$line" =~ $assign_re ]]; then
        var_name="${BASH_REMATCH[1]}"

        if [ "$var_name" != "$prev_declare_var" ]; then
            if ! find_comment_block "$i"; then
                echo "${file}:${line_num}: variable '${var_name}' has no comment block."
                errors=$((errors + 1))
            fi
        fi

        prev_declare_var=""
        continue
    fi

    # Reset prev_declare_var on non-blank, non-comment lines
    if [[ -n "$line" ]] && ! [[ "$line" =~ ^[[:space:]]*# ]]; then
        prev_declare_var=""
    fi
done

if [ "$errors" -gt 0 ]; then
    exit 1
fi
