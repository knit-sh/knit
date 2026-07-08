#!/usr/bin/env bats

setup() {
    source knit.sh
}

# ---------- slurm: cmdline ----------

@test "slurm cmdline translates a full placement" {
    declare -A opts=([procs]=8 [procs-per-node]=4 [hostnames]="h0,h1")
    declare -a argv
    _knit_launch_slurm_cmdline opts argv
    [ "${#argv[@]}" -eq 9 ]
    [ "${argv[0]}" = "srun" ]
    [ "${argv[1]}" = "--ntasks" ]
    [ "${argv[2]}" = "8" ]
    [ "${argv[3]}" = "--ntasks-per-node" ]
    [ "${argv[4]}" = "4" ]
    [ "${argv[5]}" = "--nodelist" ]
    [ "${argv[6]}" = "h0,h1" ]
    [ "${argv[7]}" = "--nodes" ]
    [ "${argv[8]}" = "2" ]
}

@test "slurm cmdline emits only the flags whose options are set" {
    declare -A opts=([procs]=4)
    declare -a argv
    _knit_launch_slurm_cmdline opts argv
    [ "${#argv[@]}" -eq 3 ]
    [ "${argv[0]}" = "srun" ]
    [ "${argv[1]}" = "--ntasks" ]
    [ "${argv[2]}" = "4" ]
}

@test "slurm cmdline with no options is just the executable" {
    declare -A opts
    declare -a argv
    _knit_launch_slurm_cmdline opts argv
    [ "${#argv[@]}" -eq 1 ]
    [ "${argv[0]}" = "srun" ]
}

@test "slurm cmdline derives --nodes from a hostnames subset" {
    declare -A opts=([hostnames]="h3,h7")
    declare -a argv
    _knit_launch_slurm_cmdline opts argv
    [ "${#argv[@]}" -eq 5 ]
    [ "${argv[0]}" = "srun" ]
    [ "${argv[1]}" = "--nodelist" ]
    [ "${argv[2]}" = "h3,h7" ]
    [ "${argv[3]}" = "--nodes" ]
    [ "${argv[4]}" = "2" ]
}

@test "slurm cmdline derives --nodes 1 from a single host" {
    declare -A opts=([hostnames]="h0")
    declare -a argv
    _knit_launch_slurm_cmdline opts argv
    [ "${argv[3]}" = "--nodes" ]
    [ "${argv[4]}" = "1" ]
}

@test "slurm cmdline appends launcher-args verbatim" {
    declare -A opts=([procs]=2 [launcher-args]="--cpu-bind cores")
    declare -a argv
    _knit_launch_slurm_cmdline opts argv
    [ "${#argv[@]}" -eq 5 ]
    [ "${argv[3]}" = "--cpu-bind" ]
    [ "${argv[4]}" = "cores" ]
}

# ---------- pbs: cmdline ----------

@test "pbs cmdline translates a full placement" {
    declare -A opts=([procs]=8 [procs-per-node]=4 [hostnames]="h0,h1")
    declare -a argv
    _knit_launch_pbs_cmdline opts argv
    [ "${#argv[@]}" -eq 7 ]
    [ "${argv[0]}" = "mpiexec" ]
    [ "${argv[1]}" = "-n" ]
    [ "${argv[2]}" = "8" ]
    [ "${argv[3]}" = "-ppn" ]
    [ "${argv[4]}" = "4" ]
    [ "${argv[5]}" = "-hosts" ]
    [ "${argv[6]}" = "h0,h1" ]
}

@test "pbs cmdline emits only the flags whose options are set" {
    declare -A opts=([procs]=4)
    declare -a argv
    _knit_launch_pbs_cmdline opts argv
    [ "${#argv[@]}" -eq 3 ]
    [ "${argv[0]}" = "mpiexec" ]
    [ "${argv[1]}" = "-n" ]
    [ "${argv[2]}" = "4" ]
}

@test "pbs cmdline with no options is just the executable" {
    declare -A opts
    declare -a argv
    _knit_launch_pbs_cmdline opts argv
    [ "${#argv[@]}" -eq 1 ]
    [ "${argv[0]}" = "mpiexec" ]
}

@test "pbs cmdline appends launcher-args verbatim" {
    declare -A opts=([procs]=2 [launcher-args]="-genv FOO bar")
    declare -a argv
    _knit_launch_pbs_cmdline opts argv
    [ "${#argv[@]}" -eq 6 ]
    [ "${argv[3]}" = "-genv" ]
    [ "${argv[4]}" = "FOO" ]
    [ "${argv[5]}" = "bar" ]
}

# ---------- dispatcher routing ----------

@test "_knit_launch_cmdline routes to the slurm backend" {
    declare -A opts=([procs]=2)
    declare -a argv
    _knit_launch_cmdline slurm opts argv
    [ "${argv[0]}" = "srun" ]
}

@test "_knit_launch_cmdline routes to the pbs backend" {
    declare -A opts=([procs]=2)
    declare -a argv
    _knit_launch_cmdline pbs opts argv
    [ "${argv[0]}" = "mpiexec" ]
}

# ---------- backend selection: never auto-detected ----------

@test "_knit_launch_backend selects slurm via an explicit override" {
    _knit_metadata_load()   { printf 'openmpi\n'; }
    _knit_detect_launcher() { printf 'mpich\n'; }
    run _knit_launch_backend slurm
    [ "$status" -eq 0 ]
    [ "$output" = "slurm" ]
}

@test "_knit_launch_backend selects pbs via metadata" {
    _knit_metadata_load()   { printf 'pbs\n'; }
    _knit_detect_launcher() { printf 'openmpi\n'; }
    run _knit_launch_backend
    [ "$output" = "pbs" ]
}

# ---------- exec: prepends the launcher argv to the worker ----------

@test "slurm exec runs the launcher argv followed by the worker command" {
    declare -A opts
    _knit_launch_slurm_cmdline() { local -n _o="$2"; _o=(echo LAUNCHED); }
    run _knit_launch_slurm_exec opts -- worker arg1
    [ "$status" -eq 0 ]
    [ "$output" = "LAUNCHED worker arg1" ]
}

@test "pbs exec runs the launcher argv followed by the worker command" {
    declare -A opts
    _knit_launch_pbs_cmdline() { local -n _o="$2"; _o=(echo LAUNCHED); }
    run _knit_launch_pbs_exec opts -- worker arg1
    [ "$status" -eq 0 ]
    [ "$output" = "LAUNCHED worker arg1" ]
}

@test "slurm exec tolerates a missing -- separator" {
    declare -A opts
    _knit_launch_slurm_cmdline() { local -n _o="$2"; _o=(echo LAUNCHED); }
    run _knit_launch_slurm_exec opts worker
    [ "$status" -eq 0 ]
    [ "$output" = "LAUNCHED worker" ]
}

@test "pbs exec returns the launched command's exit status" {
    declare -A opts
    _knit_launch_pbs_cmdline() { local -n _o="$2"; _o=(env); }
    run _knit_launch_pbs_exec opts -- bash -c 'exit 5'
    [ "$status" -eq 5 ]
}
