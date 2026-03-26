#!/usr/bin/env bats

setup() {
    source knit.sh
}

# ---------- __knit_type_resolve_alias ----------

@test "resolve alias int to integer" {
    local result
    result=$(__knit_type_resolve_alias "int")
    [ "$result" = "integer" ]
}

@test "resolve alias double to real" {
    local result
    result=$(__knit_type_resolve_alias "double")
    [ "$result" = "real" ]
}

@test "resolve alias float to real" {
    local result
    result=$(__knit_type_resolve_alias "float")
    [ "$result" = "real" ]
}

@test "resolve alias bool to boolean" {
    local result
    result=$(__knit_type_resolve_alias "bool")
    [ "$result" = "boolean" ]
}

@test "resolve canonical type returns itself" {
    for t in integer real boolean string path file filename date time datetime uuid; do
        local result
        result=$(__knit_type_resolve_alias "$t")
        [ "$result" = "$t" ]
    done
}

@test "resolve unknown type fails" {
    run __knit_type_resolve_alias "unknown"
    [ "$status" -eq 1 ]
}

@test "resolve enum type returns itself" {
    knit_define_enum "color" "red" "green" "blue"
    local result
    result=$(__knit_type_resolve_alias "color")
    [ "$result" = "color" ]
}

# ---------- knit_type_exists ----------

@test "built-in types exist" {
    for t in integer real boolean string path file filename date time datetime uuid; do
        knit_type_exists "$t"
    done
}

@test "aliases exist" {
    for t in int double float bool; do
        knit_type_exists "$t"
    done
}

@test "unknown type does not exist" {
    run knit_type_exists "unknown"
    [ "$status" -eq 1 ]
}

@test "enum type exists after definition" {
    knit_define_enum "color" "red" "green" "blue"
    knit_type_exists "color"
}

# ---------- knit_define_enum / knit_enum_values ----------

@test "define enum and list values" {
    knit_define_enum "color" "red" "green" "blue"
    local result
    result=$(knit_enum_values "color" | sort)
    [ "$result" = "$(printf 'blue\ngreen\nred')" ]
}

@test "enum values with custom separator" {
    knit_define_enum "direction" "north" "south"
    local result
    result=$(knit_enum_values "direction" ", ")
    [[ "$result" = "north, south" || "$result" = "south, north" ]]
}

@test "enum values for unknown enum fails" {
    run knit_enum_values "nonexistent"
    [ "$status" -eq 1 ]
}

@test "empty enum produces no output" {
    knit_define_enum "empty"
    local result
    result=$(knit_enum_values "empty")
    [ -z "$result" ]
}

# ---------- knit_type_check: integer ----------

@test "type check integer valid" {
    knit_type_check "integer" "42"
    knit_type_check "integer" "0"
    knit_type_check "integer" "-7"
    knit_type_check "integer" "123456789"
}

@test "type check integer invalid" {
    run knit_type_check "integer" "3.14"
    [ "$status" -eq 1 ]
    run knit_type_check "integer" "hello"
    [ "$status" -eq 1 ]
    run knit_type_check "integer" ""
    [ "$status" -eq 1 ]
    run knit_type_check "integer" "12a"
    [ "$status" -eq 1 ]
}

@test "type check int alias works" {
    knit_type_check "int" "42"
    run knit_type_check "int" "hello"
    [ "$status" -eq 1 ]
}

# ---------- knit_type_check: real ----------

@test "type check real valid" {
    knit_type_check "real" "3.14"
    knit_type_check "real" "42"
    knit_type_check "real" "-7.5"
    knit_type_check "real" ".5"
    knit_type_check "real" "1."
    knit_type_check "real" "1e10"
    knit_type_check "real" "1.5e-3"
    knit_type_check "real" "1E10"
    knit_type_check "real" "-.5"
}

@test "type check real invalid" {
    run knit_type_check "real" "hello"
    [ "$status" -eq 1 ]
    run knit_type_check "real" ""
    [ "$status" -eq 1 ]
    run knit_type_check "real" "."
    [ "$status" -eq 1 ]
    run knit_type_check "real" "e5"
    [ "$status" -eq 1 ]
}

@test "type check double and float aliases work" {
    knit_type_check "double" "3.14"
    knit_type_check "float" "3.14"
}

# ---------- knit_type_check: boolean ----------

@test "type check boolean valid" {
    knit_type_check "boolean" "true"
    knit_type_check "boolean" "false"
}

@test "type check boolean invalid" {
    run knit_type_check "boolean" "True"
    [ "$status" -eq 1 ]
    run knit_type_check "boolean" "yes"
    [ "$status" -eq 1 ]
    run knit_type_check "boolean" "1"
    [ "$status" -eq 1 ]
    run knit_type_check "boolean" ""
    [ "$status" -eq 1 ]
}

@test "type check bool alias works" {
    knit_type_check "bool" "true"
    run knit_type_check "bool" "yes"
    [ "$status" -eq 1 ]
}

# ---------- knit_type_check: string ----------

@test "type check string always valid" {
    knit_type_check "string" "hello"
    knit_type_check "string" ""
    knit_type_check "string" "123"
    knit_type_check "string" "special chars: !@#"
}

# ---------- knit_type_check: path / filename ----------

@test "type check path valid" {
    knit_type_check "path" "/some/path"
    knit_type_check "path" "relative/path"
}

@test "type check path invalid when empty" {
    run knit_type_check "path" ""
    [ "$status" -eq 1 ]
}

@test "type check filename valid" {
    knit_type_check "filename" "/some/file.txt"
    knit_type_check "filename" "nonexistent.txt"
}

@test "type check filename invalid when empty" {
    run knit_type_check "filename" ""
    [ "$status" -eq 1 ]
}

# ---------- knit_type_check: file ----------

@test "type check file valid for existing file" {
    local tmpfile
    tmpfile=$(mktemp)
    knit_type_check "file" "$tmpfile"
    rm -f "$tmpfile"
}

@test "type check file invalid for nonexistent file" {
    run knit_type_check "file" "/nonexistent/file.txt"
    [ "$status" -eq 1 ]
}

# ---------- knit_type_check: date ----------

@test "type check date valid" {
    knit_type_check "date" "2025-03-13"
    knit_type_check "date" "2000-01-01"
    knit_type_check "date" "1999-12-31"
}

@test "type check date invalid format" {
    run knit_type_check "date" "2025/03/13"
    [ "$status" -eq 1 ]
    run knit_type_check "date" "03-13-2025"
    [ "$status" -eq 1 ]
    run knit_type_check "date" "2025-3-13"
    [ "$status" -eq 1 ]
    run knit_type_check "date" "not-a-date"
    [ "$status" -eq 1 ]
}

@test "type check date invalid ranges" {
    run knit_type_check "date" "2025-00-13"
    [ "$status" -eq 1 ]
    run knit_type_check "date" "2025-13-13"
    [ "$status" -eq 1 ]
    run knit_type_check "date" "2025-03-00"
    [ "$status" -eq 1 ]
    run knit_type_check "date" "2025-03-32"
    [ "$status" -eq 1 ]
}

# ---------- knit_type_check: time ----------

@test "type check time valid" {
    knit_type_check "time" "12:30:45"
    knit_type_check "time" "00:00:00"
    knit_type_check "time" "23:59:59"
}

@test "type check time invalid format" {
    run knit_type_check "time" "12:30"
    [ "$status" -eq 1 ]
    run knit_type_check "time" "1:30:45"
    [ "$status" -eq 1 ]
    run knit_type_check "time" "not-a-time"
    [ "$status" -eq 1 ]
}

@test "type check time invalid ranges" {
    run knit_type_check "time" "24:00:00"
    [ "$status" -eq 1 ]
    run knit_type_check "time" "12:60:00"
    [ "$status" -eq 1 ]
    run knit_type_check "time" "12:30:60"
    [ "$status" -eq 1 ]
}

# ---------- knit_type_check: datetime ----------

@test "type check datetime valid" {
    knit_type_check "datetime" "2025-03-13 12:30:45"
    knit_type_check "datetime" "2000-01-01 00:00:00"
}

@test "type check datetime invalid" {
    run knit_type_check "datetime" "2025-03-13"
    [ "$status" -eq 1 ]
    run knit_type_check "datetime" "12:30:45"
    [ "$status" -eq 1 ]
    run knit_type_check "datetime" "2025-03-13T12:30:45"
    [ "$status" -eq 1 ]
    run knit_type_check "datetime" "2025-13-13 12:30:45"
    [ "$status" -eq 1 ]
}

# ---------- knit_type_check: enum ----------

@test "type check enum valid value" {
    knit_define_enum "color" "red" "green" "blue"
    knit_type_check "color" "red"
    knit_type_check "color" "green"
    knit_type_check "color" "blue"
}

@test "type check enum invalid value" {
    knit_define_enum "color" "red" "green" "blue"
    run knit_type_check "color" "yellow"
    [ "$status" -eq 1 ]
}

# ---------- knit_type_check: uuid ----------

@test "type check uuid valid" {
    knit_type_check "uuid" "550e8400-e29b-41d4-a716-446655440000"
    knit_type_check "uuid" "00000000-0000-0000-0000-000000000000"
    knit_type_check "uuid" "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
}

@test "type check uuid invalid" {
    run knit_type_check "uuid" "not-a-uuid"
    [ "$status" -eq 1 ]
    run knit_type_check "uuid" "550e8400-e29b-41d4-a716"
    [ "$status" -eq 1 ]
    run knit_type_check "uuid" ""
    [ "$status" -eq 1 ]
    run knit_type_check "uuid" "550e8400-e29b-41d4-a716-44665544000g"
    [ "$status" -eq 1 ]
}

# ---------- knit_type_check: unknown type ----------

@test "type check with unknown type fails" {
    run knit_type_check "unknown" "value"
    [ "$status" -eq 1 ]
}

# ---------- __knit_type_to_sqlite ----------

@test "type to sqlite integer returns INTEGER" {
    local result
    result=$(__knit_type_to_sqlite "integer")
    [ "$result" = "INTEGER" ]
}

@test "type to sqlite int alias returns INTEGER" {
    local result
    result=$(__knit_type_to_sqlite "int")
    [ "$result" = "INTEGER" ]
}

@test "type to sqlite real returns REAL" {
    local result
    result=$(__knit_type_to_sqlite "real")
    [ "$result" = "REAL" ]
}

@test "type to sqlite boolean returns TEXT" {
    local result
    result=$(__knit_type_to_sqlite "boolean")
    [ "$result" = "TEXT" ]
}

@test "type to sqlite string returns TEXT" {
    local result
    result=$(__knit_type_to_sqlite "string")
    [ "$result" = "TEXT" ]
}

@test "type to sqlite date returns TEXT" {
    local result
    result=$(__knit_type_to_sqlite "date")
    [ "$result" = "TEXT" ]
}

@test "type to sqlite uuid returns TEXT" {
    local result
    result=$(__knit_type_to_sqlite "uuid")
    [ "$result" = "TEXT" ]
}

@test "type to sqlite enum returns TEXT" {
    knit_define_enum "color" "red" "green"
    local result
    result=$(__knit_type_to_sqlite "color")
    [ "$result" = "TEXT" ]
}

@test "type to sqlite unknown type fails" {
    run __knit_type_to_sqlite "unknown"
    [ "$status" -ne 0 ]
}
