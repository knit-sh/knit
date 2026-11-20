#!/usr/bin/env bats

# History eligibility flag (recording M1): the knit_with_history /
# knit_without_history decorators and the _knit_history_enabled resolver. This
# milestone delivers only the switch and its lexical-inheritance resolution; the
# __history__ recording that consumes it is wired in a later milestone. The
# resolver is a pure function over the registration tables, so these tests need
# no database.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_source_knit
}

# ---------- default ----------

@test "an unmarked command is history-eligible by default" {
    knit_register "hdefault" knit_empty "Default."
    knit_done
    _knit_history_enabled "hdefault"
}

@test "the default is ON even for a hidden command (visibility does not gate)" {
    # Unlike provenance, history eligibility ignores visibility: the root gate in
    # _knit_history_record keeps a hidden or nested command out, not this predicate.
    knit_register "_hhidden" knit_empty "Hidden."
    knit_hidden
    knit_done
    _knit_history_enabled "_hhidden"
}

# ---------- own explicit mark ----------

@test "knit_without_history marks a command ineligible" {
    knit_register "hwithout" knit_empty "Without."
    knit_without_history
    knit_done
    run _knit_history_enabled "hwithout"
    [ "$status" -eq 1 ]
}

@test "knit_with_history keeps a command eligible (explicit with)" {
    knit_register "hwith" knit_empty "With."
    knit_with_history
    knit_done
    _knit_history_enabled "hwith"
}

@test "the mark is stored under _KNIT_CMD_<cmd>_history" {
    knit_register "hmark" knit_empty "Mark."
    knit_without_history
    knit_done
    [ "${_KNIT_CMD_hmark_history}" = "without" ]
}

# ---------- lexical inheritance ----------

# The resolver takes mangled command names (colons -> __1__), like
# _knit_provenance_enabled; mangle the demangled name before querying it.

@test "an unmarked nested command inherits a without mark from its lexical parent" {
    knit_register "hgrp" knit_empty "Group."
    knit_without_history
    knit_done

    knit_register "hgrp:leaf" knit_empty "Leaf."
    knit_done

    local leaf; _knit_command_mangle leaf "hgrp:leaf"
    run _knit_history_enabled "${leaf}"
    [ "$status" -eq 1 ]
}

@test "an explicit with on a nested command overrides an inherited without" {
    knit_register "hogrp" knit_empty "Group."
    knit_without_history
    knit_done

    knit_register "hogrp:leaf" knit_empty "Leaf with own mark."
    knit_with_history
    knit_done

    local leaf; _knit_command_mangle leaf "hogrp:leaf"
    _knit_history_enabled "${leaf}"
}

@test "the nearest marked lexical ancestor wins over a farther one" {
    knit_register "htop" knit_empty "Top."
    knit_without_history
    knit_done

    knit_register "htop:mid" knit_empty "Mid."
    knit_with_history
    knit_done

    knit_register "htop:mid:leaf" knit_empty "Leaf."
    knit_done

    # htop is "without" and htop:mid is "with"; the unmarked leaf inherits from the
    # nearer htop:mid, so it is eligible.
    local leaf; _knit_command_mangle leaf "htop:mid:leaf"
    _knit_history_enabled "${leaf}"
}

# ---------- orthogonality with provenance ----------

@test "history eligibility is independent of provenance" {
    # A command excluded from provenance can still be history-eligible, and vice
    # versa: the two axes do not borrow from each other.
    knit_register "horth" knit_empty "Orthogonal."
    knit_without_provenance
    knit_done

    _knit_history_enabled "horth"
    run _knit_provenance_enabled "horth"
    [ "$status" -eq 1 ]
}

# ---------- misuse ----------

@test "knit_with_history outside a registration block is fatal" {
    run knit_with_history
    [ "$status" -eq 1 ]
    [[ "$output" == *"should be used after a call to \"knit_register\""* ]]
}

@test "knit_without_history outside a registration block is fatal" {
    run knit_without_history
    [ "$status" -eq 1 ]
    [[ "$output" == *"should be used after a call to \"knit_register\""* ]]
}

# ---------- shorthand twins ----------

@test "the @with_history / @without_history shorthands map to the knit_* functions" {
    [ "${_KNIT_SHORTHAND_PASSTHROUGH[with_history]}" = "knit_with_history" ]
    [ "${_KNIT_SHORTHAND_PASSTHROUGH[without_history]}" = "knit_without_history" ]
}
