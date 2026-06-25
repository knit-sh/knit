#!/usr/bin/env bats

setup() {
    source knit.sh
}

# ---------- knit_framed argument validation ----------

@test "knit_framed rejects an unknown option" {
    run knit_framed --bogus </dev/null
    [ "$status" -ne 0 ]
}

@test "knit_framed rejects an unknown flag" {
    run knit_framed --not-a-flag </dev/null
    [ "$status" -ne 0 ]
}

@test "knit_framed accepts known options and the cleanup flag" {
    run knit_framed --title hello --cleanup </dev/null
    [ "$status" -eq 0 ]
}

@test "knit_framed accepts leading positional height and width" {
    run knit_framed 10 20 --title hello </dev/null
    [ "$status" -eq 0 ]
}
