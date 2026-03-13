#!/usr/bin/env bats

setup() {
    source knit.sh
}

@test "finding an option that exists" {
    local args=("--abc" "ABC" "--def" "DEF" "--ghi" "GHI")
    run knit_get_parameter "abc" "${args[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "ABC" ]
    run knit_get_parameter "def" "${args[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "DEF" ]
    run knit_get_parameter "ghi" "${args[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "GHI" ]
}

@test "finding an option that does not exist" {
    local args=("--abc" "ABC" "--def" "DEF" "--ghi" "GHI")
    run knit_get_parameter "jkl" "${args[@]}"
    [ "$status" -eq 1 ]
}

# ---------- knit_with_required type annotations ----------

@test "knit_with_required accepts name:type syntax" {
    knit_register my_fn "test_cmd_1" "A test command."
    knit_with_required "count:integer" "A count parameter."
    my_fn() { :; }
    knit_done
}

@test "knit_with_required rejects missing type" {
    knit_register my_fn2 "test_cmd_2" "A test command."
    run knit_with_required "name" "A name parameter."
    [ "$status" -eq 1 ]
}

@test "knit_with_required rejects unknown type" {
    knit_register my_fn3 "test_cmd_3" "A test command."
    run knit_with_required "count:nosuchtype" "A count parameter."
    [ "$status" -eq 1 ]
}

@test "knit_with_required accepts alias types" {
    knit_register my_fn4 "test_cmd_4" "A test command."
    knit_with_required "count:int" "A count parameter."
    my_fn4() { :; }
    knit_done
}

@test "knit_with_required accepts enum types" {
    knit_define_enum "color" "red" "green" "blue"
    knit_register my_fn5 "test_cmd_5" "A test command."
    knit_with_required "shade:color" "A color parameter."
    my_fn5() { :; }
    knit_done
}

# ---------- knit_with_optional type annotations ----------

@test "knit_with_optional accepts name:type syntax" {
    knit_register my_fn6 "test_cmd_6" "A test command."
    knit_with_optional "count:integer" "10" "A count parameter."
    my_fn6() { :; }
    knit_done
}

@test "knit_with_optional rejects missing type" {
    knit_register my_fn7 "test_cmd_7" "A test command."
    run knit_with_optional "name" "world" "A name parameter."
    [ "$status" -eq 1 ]
}

@test "knit_with_optional rejects unknown type" {
    knit_register my_fn8 "test_cmd_8" "A test command."
    run knit_with_optional "count:nosuchtype" "10" "A count parameter."
    [ "$status" -eq 1 ]
}
