#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit
}

@test "creating a new set" {
    _knit_set_new MY_SET
    # Check that MY_SET is an associative array
    local output=$(declare -p MY_SET 2>/dev/null)
    [[ "$output" =~ "declare -A" ]]
    # Check that it is empty
    local set_size="${#MY_SET[@]}"
    [ "$set_size" -eq 0 ]
}

@test "checking that array exists" {
   _knit_set_new MY_SET
   _knit_set_exists MY_SET
   # test with a set that is not defined
   run _knit_set_exists MY_OTHER_SET
   [ "$status" -eq 1 ]
   # test with a variable that is not an associative array
   local MY_OTHER_SET="AAA"
   run _knit_set_exists MY_OTHER_SET
   [ "$status" -eq 1 ]
   # test with a regular (non-associative) array
   local -a MY_OTHER_SET2=("AAA" "BBB")
   run _knit_set_exists MY_OTHER_SET2
   [ "$status" -eq 1 ]
}

@test "adding elements in a set" {
    _knit_set_new MY_SET
    _knit_set_add MY_SET "Matthieu" "Rob" "Phil" "Shane" "Amal"
    [ "${#MY_SET[@]}" -eq 5 ]
    [ "${MY_SET[Matthieu]}" = "1" ]
    [ "${MY_SET[Rob]}" = "1" ]
    [ "${MY_SET[Phil]}" = "1" ]
    [ "${MY_SET[Shane]}" = "1" ]
    [ "${MY_SET[Amal]}" = "1" ]
    # Adding no elements does not change the set
    _knit_set_add MY_SET
    [ "${#MY_SET[@]}" -eq 5 ]
}

@test "adding duplicate elements does not increase size" {
    _knit_set_new MY_SET
    _knit_set_add MY_SET "Matthieu" "Rob"
    [ "${#MY_SET[@]}" -eq 2 ]
    _knit_set_add MY_SET "Matthieu"
    [ "${#MY_SET[@]}" -eq 2 ]
}

@test "removing elements from a set" {
    _knit_set_new MY_SET
    _knit_set_add MY_SET "Matthieu" "Rob" "Phil" "Shane" "Amal"
    _knit_set_remove MY_SET "Matthieu"
    [ "${#MY_SET[@]}" -eq 4 ]
    run _knit_set_find MY_SET "Matthieu"
    [ "$status" -eq 1 ]
    _knit_set_remove MY_SET "Amal" "Phil"
    [ "${#MY_SET[@]}" -eq 2 ]
    _knit_set_remove MY_SET "Shane"
    [ "${#MY_SET[@]}" -eq 1 ]
    [ "${MY_SET[Rob]}" = "1" ]
}

@test "removing element that is not in a set" {
    _knit_set_new MY_SET
    _knit_set_add MY_SET "Matthieu" "Rob" "Phil" "Shane" "Amal"
    _knit_set_remove MY_SET "Marc"
    [ "${#MY_SET[@]}" -eq 5 ]
}

@test "finding an element that is in a set" {
    _knit_set_new MY_SET
    _knit_set_add MY_SET "Matthieu" "Rob" "Phil" "Shane" "Amal"
    for name in Matthieu Rob Phil Shane Amal; do
        run _knit_set_find MY_SET "$name"
        [ "$status" -eq 0 ]
    done
}

@test "iterating over a set yields insertion order" {
    _knit_set_new MY_SET
    _knit_set_add MY_SET "zebra" "apple" "mango"
    local result
    result=$(_knit_set_iter MY_SET)
    [ "$result" = "$(printf 'zebra\napple\nmango')" ]
}

@test "duplicates do not change iteration order" {
    _knit_set_new MY_SET
    _knit_set_add MY_SET "zebra" "apple"
    _knit_set_add MY_SET "apple" "mango" "zebra"
    local result
    result=$(_knit_set_iter MY_SET)
    [ "$result" = "$(printf 'zebra\napple\nmango')" ]
}

@test "insertion order is preserved on a set declared with declare -gA" {
    # No _knit_set_new: the order array must be created lazily by _knit_set_add.
    declare -gA MY_DIRECT_SET
    _knit_set_add MY_DIRECT_SET "gamma" "alpha" "beta"
    local result
    result=$(_knit_set_iter MY_DIRECT_SET)
    [ "$result" = "$(printf 'gamma\nalpha\nbeta')" ]
}

@test "iterating over an empty set produces no output" {
    _knit_set_new MY_SET
    local result
    result=$(_knit_set_iter MY_SET)
    [ -z "$result" ]
}

@test "_knit_set_array returns elements in insertion order" {
    _knit_set_new MY_SET
    _knit_set_add MY_SET "zebra" "apple" "mango"
    local -a result
    _knit_set_array result MY_SET
    [ "${#result[@]}" -eq 3 ]
    [ "${result[0]}" = "zebra" ]
    [ "${result[1]}" = "apple" ]
    [ "${result[2]}" = "mango" ]
}

@test "_knit_set_array on an empty set yields an empty array" {
    _knit_set_new MY_SET
    local -a result=("stale")
    _knit_set_array result MY_SET
    [ "${#result[@]}" -eq 0 ]
}

@test "_knit_set_array on a single-element set" {
    _knit_set_new MY_SET
    _knit_set_add MY_SET "only"
    local -a result
    _knit_set_array result MY_SET
    [ "${#result[@]}" -eq 1 ]
    [ "${result[0]}" = "only" ]
}

@test "removal keeps the order array consistent" {
    _knit_set_new MY_SET
    _knit_set_add MY_SET "zebra" "apple" "mango" "kiwi"
    _knit_set_remove MY_SET "apple"
    local result
    result=$(_knit_set_iter MY_SET)
    [ "$result" = "$(printf 'zebra\nmango\nkiwi')" ]
    # Re-adding a removed element appends it at the end.
    _knit_set_add MY_SET "apple"
    result=$(_knit_set_iter MY_SET)
    [ "$result" = "$(printf 'zebra\nmango\nkiwi\napple')" ]
}

@test "removing all elements leaves an empty ordered set" {
    _knit_set_new MY_SET
    _knit_set_add MY_SET "zebra" "apple"
    _knit_set_remove MY_SET "zebra" "apple"
    local -a result
    _knit_set_array result MY_SET
    [ "${#result[@]}" -eq 0 ]
    local iter
    iter=$(_knit_set_iter MY_SET)
    [ -z "$iter" ]
}

@test "finding an element that is not in a set" {
    _knit_set_new MY_SET
    _knit_set_add MY_SET "Matthieu" "Rob" "Phil" "Shane" "Amal"
    run _knit_set_find MY_SET "Marc"
    [ "$status" -eq 1 ]
}
