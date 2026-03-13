#!/usr/bin/env bats

setup() {
    source knit.sh
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

@test "iterating over a set" {
    _knit_set_new MY_SET
    _knit_set_add MY_SET "Matthieu" "Rob" "Phil"
    local result
    result=$(_knit_set_iter MY_SET | sort)
    [ "$result" = "$(printf 'Matthieu\nPhil\nRob')" ]
}

@test "iterating over an empty set produces no output" {
    _knit_set_new MY_SET
    local result
    result=$(_knit_set_iter MY_SET)
    [ -z "$result" ]
}

@test "finding an element that is not in a set" {
    _knit_set_new MY_SET
    _knit_set_add MY_SET "Matthieu" "Rob" "Phil" "Shane" "Amal"
    run _knit_set_find MY_SET "Marc"
    [ "$status" -eq 1 ]
}
