#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/../knit.sh"
}

# ---------- _knit_str_render_cmd ----------

@test "_knit_str_render_cmd joins an argv with single spaces" {
    local -a argv=(sbatch --wait /path/.job.sh)
    [ "$(_knit_str_render_cmd argv)" = "sbatch --wait /path/.job.sh" ]
}

@test "_knit_str_render_cmd renders an empty array to the empty string" {
    local -a argv=()
    [ "$(_knit_str_render_cmd argv)" = "" ]
}

@test "_knit_str_render_cmd quotes arguments that contain spaces" {
    local -a argv=(mpirun -x "A B")
    # The space-bearing argument is %q-quoted so the string round-trips safely.
    [ "$(_knit_str_render_cmd argv)" = "mpirun -x A\\ B" ]
}
