#!/usr/bin/env bats

setup() {
    source knit.sh
}

@test "creating a new set" {
    _knit_set_new MY_SET
    # Check that MY_SET is an array
    local output=$(declare -p MY_SET 2>/dev/null)
    [[ "$output" =~ "declare -a" ]]
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
   # test with a variable that is not a list
   local MY_OTHER_SET="AAA"
   run _knit_set_exists MY_OTHER_SET
   [ "$status" -eq 1 ]
   # test with a list that is not sorted
   local MY_OTHER_SET=("BBB" "AAA" "CCC")
   run _knit_set_exists MY_OTHER_SET
   [ "$status" -eq 1 ]
   # test with a list that has double elements
   local MY_OTHER_SET=("AAA" "BBB" "BBB" "CCC")
   run _knit_set_exists MY_OTHER_SET
   [ "$status" -eq 1 ]
}

@test "adding elements in a set" {
    _knit_set_new MY_SET
    _knit_set_add MY_SET "Matthieu" "Rob" "Phil" "Shane" "Amal"
    local content=$(echo "${MY_SET[@]}")
    [ "$content" == "Amal Matthieu Phil Rob Shane" ]
    _knit_set_add MY_SET
    local content=$(echo "${MY_SET[@]}")
    [ "$content" == "Amal Matthieu Phil Rob Shane" ]
}

@test "removing elements in a set" {
    _knit_set_new MY_SET
    _knit_set_add MY_SET "Matthieu" "Rob" "Phil" "Shane" "Amal"
    _knit_set_remove MY_SET "Matthieu"
    local content=$(echo "${MY_SET[@]}")
    [ "$content" == "Amal Phil Rob Shane" ]
    _knit_set_remove MY_SET "Amal" "Phil"
    local content=$(echo "${MY_SET[@]}")
    [ "$content" == "Rob Shane" ]
    _knit_set_remove MY_SET "Shane"
    local content=$(echo "${MY_SET[@]}")
    [ "$content" == "Rob" ]
}

@test "removing element that is not in a set" {
    _knit_set_new MY_SET
    _knit_set_add MY_SET "Matthieu" "Rob" "Phil" "Shane" "Amal"
    _knit_set_remove MY_SET "Marc"
    local content=$(echo "${MY_SET[@]}")
    [ "$content" == "Amal Matthieu Phil Rob Shane" ]
}

@test "finding an element that is in a set" {
    _knit_set_new MY_SET
    _knit_set_add MY_SET "Matthieu" "Rob" "Phil" "Shane" "Amal"
    for name in "${MY_SET[@]}"; do
        run _knit_set_find MY_SET "$name"
        [ "$status" -eq 0 ]
    done
}

@test "finding an element that is not in a set" {
    _knit_set_new MY_SET
    _knit_set_add MY_SET "Matthieu" "Rob" "Phil" "Shane" "Amal"
    run _knit_set_find MY_SET "Marc"
    [ "$status" -eq 1 ]
}
