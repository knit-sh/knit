#!/usr/bin/env bats

setup() {
    source knit.sh
}

# --- __knit_log_level_to_int ---

@test "log level to int converts all valid levels" {
    [ "$(__knit_log_level_to_int trace)" -eq 0 ]
    [ "$(__knit_log_level_to_int debug)" -eq 1 ]
    [ "$(__knit_log_level_to_int info)" -eq 2 ]
    [ "$(__knit_log_level_to_int warning)" -eq 3 ]
    [ "$(__knit_log_level_to_int error)" -eq 4 ]
    [ "$(__knit_log_level_to_int critical)" -eq 5 ]
}

@test "log level to int defaults to 2 for unrecognized values" {
    [ "$(__knit_log_level_to_int bogus)" -eq 2 ]
    [ "$(__knit_log_level_to_int "")" -eq 2 ]
}

# --- knit_log_set_level ---

@test "set log level accepts and stores valid levels" {
    for level in trace debug info warning error critical; do
        knit_log_set_level "$level"
        [ "$KNIT_LOG_LEVEL" = "$level" ]
    done
}

@test "set log level rejects invalid values" {
    run knit_log_set_level "bogus"
    [ "$status" -eq 1 ]
    run knit_log_set_level ""
    [ "$status" -eq 1 ]
}

@test "set log level does not change level on invalid input" {
    KNIT_LOG_LEVEL=error
    knit_log_set_level "bogus" || true
    [ "$KNIT_LOG_LEVEL" = "error" ]
}

# --- _knit_log ---

@test "_knit_log outputs formatted message to stderr" {
    local output
    output=$(_knit_log info "hello %s" "world" 2>&1)
    [[ "$output" == *"[knit:info]]"* ]]
    [[ "$output" == *"hello world"* ]]
}

# --- knit_trace ---

@test "knit_trace prints at trace level" {
    KNIT_LOG_LEVEL=trace
    local output
    output=$(knit_trace "hello" 2>&1)
    [[ "$output" == *"[knit:trace]]"*"hello"* ]]
}

@test "knit_trace is silent at debug level" {
    KNIT_LOG_LEVEL=debug
    local output
    output=$(knit_trace "hello" 2>&1)
    [ -z "$output" ]
}

# --- knit_debug ---

@test "knit_debug prints at debug level" {
    KNIT_LOG_LEVEL=debug
    local output
    output=$(knit_debug "hello" 2>&1)
    [[ "$output" == *"[knit:debug]]"*"hello"* ]]
}

@test "knit_debug prints at trace level" {
    KNIT_LOG_LEVEL=trace
    local output
    output=$(knit_debug "hello" 2>&1)
    [[ "$output" == *"[knit:debug]]"*"hello"* ]]
}

@test "knit_debug is silent at info level" {
    KNIT_LOG_LEVEL=info
    local output
    output=$(knit_debug "hello" 2>&1)
    [ -z "$output" ]
}

# --- knit_info ---

@test "knit_info prints at info level" {
    KNIT_LOG_LEVEL=info
    local output
    output=$(knit_info "hello" 2>&1)
    [[ "$output" == *"[knit:info]]"*"hello"* ]]
}

@test "knit_info is silent at warning level" {
    KNIT_LOG_LEVEL=warning
    local output
    output=$(knit_info "hello" 2>&1)
    [ -z "$output" ]
}

# --- knit_warning ---

@test "knit_warning prints at warning level" {
    KNIT_LOG_LEVEL=warning
    local output
    output=$(knit_warning "hello" 2>&1)
    [[ "$output" == *"[knit:warning]]"*"hello"* ]]
}

@test "knit_warning is silent at error level" {
    KNIT_LOG_LEVEL=error
    local output
    output=$(knit_warning "hello" 2>&1)
    [ -z "$output" ]
}

# --- knit_error ---

@test "knit_error prints at error level" {
    KNIT_LOG_LEVEL=error
    local output
    output=$(knit_error "hello" 2>&1)
    [[ "$output" == *"[knit:error]]"*"hello"* ]]
}

@test "knit_error is silent at critical level" {
    KNIT_LOG_LEVEL=critical
    local output
    output=$(knit_error "hello" 2>&1)
    [ -z "$output" ]
}

# --- knit_critical ---

@test "knit_critical prints at critical level" {
    KNIT_LOG_LEVEL=critical
    local output
    output=$(knit_critical "hello" 2>&1)
    [[ "$output" == *"[knit:critical]]"*"hello"* ]]
}

# --- knit_fatal ---

@test "knit_fatal exits with status 1 and prints message" {
    run bash -c 'source knit.sh; knit_fatal "boom" 2>&1'
    [ "$status" -eq 1 ]
    [[ "$output" == *"boom"* ]]
}

# --- KNIT_LOG_LEVEL validation on source ---

@test "default KNIT_LOG_LEVEL is info" {
    run bash -c 'unset KNIT_LOG_LEVEL; source knit.sh 2>/dev/null; echo "$KNIT_LOG_LEVEL"'
    [[ "${lines[-1]}" == "info" ]]
}

@test "valid KNIT_LOG_LEVEL is preserved on source" {
    run bash -c 'KNIT_LOG_LEVEL=debug; source knit.sh 2>/dev/null; echo "$KNIT_LOG_LEVEL"'
    [[ "${lines[-1]}" == "debug" ]]
}

@test "invalid KNIT_LOG_LEVEL is reset to info on source" {
    run bash -c 'KNIT_LOG_LEVEL=bogus; source knit.sh 2>/dev/null; echo "$KNIT_LOG_LEVEL"'
    [[ "${lines[-1]}" == "info" ]]
}

@test "invalid KNIT_LOG_LEVEL produces a warning on source" {
    local output
    output=$(KNIT_LOG_LEVEL=bogus bash -c 'source knit.sh' 2>&1)
    [[ "$output" == *"bogus"* ]]
}
