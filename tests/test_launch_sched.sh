#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit
}

# ---------- slurm: cmdline ----------

@test "slurm cmdline translates a full placement" {
    declare -A opts=([procs]=8 [procs-per-node]=4 [hostnames]="h0,h1")
    declare -a argv
    _knit_launch_slurm_cmdline argv opts
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
    _knit_launch_slurm_cmdline argv opts
    [ "${#argv[@]}" -eq 3 ]
    [ "${argv[0]}" = "srun" ]
    [ "${argv[1]}" = "--ntasks" ]
    [ "${argv[2]}" = "4" ]
}

@test "slurm cmdline with no options is just the executable" {
    declare -A opts
    declare -a argv
    _knit_launch_slurm_cmdline argv opts
    [ "${#argv[@]}" -eq 1 ]
    [ "${argv[0]}" = "srun" ]
}

@test "slurm cmdline derives --nodes from a hostnames subset" {
    declare -A opts=([hostnames]="h3,h7")
    declare -a argv
    _knit_launch_slurm_cmdline argv opts
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
    _knit_launch_slurm_cmdline argv opts
    [ "${argv[3]}" = "--nodes" ]
    [ "${argv[4]}" = "1" ]
}

@test "slurm cmdline appends launcher-args verbatim" {
    declare -A opts=([procs]=2 [launcher-args]="--cpu-bind cores")
    declare -a argv
    _knit_launch_slurm_cmdline argv opts
    [ "${#argv[@]}" -eq 5 ]
    [ "${argv[3]}" = "--cpu-bind" ]
    [ "${argv[4]}" = "cores" ]
}

@test "slurm cmdline translates cpus-per-proc, bind, and GPU placement" {
    declare -A opts=([procs]=8 [cpus-per-proc]=4 [bind]=core \
        [gpus-per-proc]=1 [gpu-bind]=closest)
    declare -a argv
    _knit_launch_slurm_cmdline argv opts
    [ "${#argv[@]}" -eq 9 ]
    [ "${argv[1]}" = "--ntasks" ]
    [ "${argv[2]}" = "8" ]
    [ "${argv[3]}" = "--cpus-per-task" ]
    [ "${argv[4]}" = "4" ]
    # bind is normalized: core -> cores for Slurm, on the --cpu-bind=VALUE form.
    [ "${argv[5]}" = "--cpu-bind=cores" ]
    [ "${argv[6]}" = "--gpus-per-task" ]
    [ "${argv[7]}" = "1" ]
    # --gpu-bind value is passed through verbatim (no normalization).
    [ "${argv[8]}" = "--gpu-bind=closest" ]
}

@test "slurm cmdline maps numa bind to ldoms" {
    declare -A opts=([bind]=numa)
    declare -a argv
    _knit_launch_slurm_cmdline argv opts
    [ "${argv[1]}" = "--cpu-bind=ldoms" ]
}

# ---------- pbs: cmdline ----------

@test "pbs cmdline translates a full placement" {
    declare -A opts=([procs]=8 [procs-per-node]=4 [hostnames]="h0,h1")
    declare -a argv
    _knit_launch_pbs_cmdline argv opts
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
    _knit_launch_pbs_cmdline argv opts
    [ "${#argv[@]}" -eq 3 ]
    [ "${argv[0]}" = "mpiexec" ]
    [ "${argv[1]}" = "-n" ]
    [ "${argv[2]}" = "4" ]
}

@test "pbs cmdline with no options is just the executable" {
    declare -A opts
    declare -a argv
    _knit_launch_pbs_cmdline argv opts
    [ "${#argv[@]}" -eq 1 ]
    [ "${argv[0]}" = "mpiexec" ]
}

@test "pbs cmdline appends launcher-args verbatim" {
    declare -A opts=([procs]=2 [launcher-args]="-genv FOO bar")
    declare -a argv
    _knit_launch_pbs_cmdline argv opts
    [ "${#argv[@]}" -eq 6 ]
    [ "${argv[3]}" = "-genv" ]
    [ "${argv[4]}" = "FOO" ]
    [ "${argv[5]}" = "bar" ]
}

@test "pbs cmdline translates bind and warns/skips cpus-per-proc and GPU" {
    declare -A opts=([procs]=4 [cpus-per-proc]=2 [bind]=core [gpus-per-proc]=1)
    declare -a argv
    run _knit_launch_pbs_cmdline argv opts
    [[ "$output" == *"--cpus-per-proc has no native Hydra flag"* ]]
    [[ "$output" == *"--gpus-per-proc has no native Hydra flag"* ]]
    _knit_launch_pbs_cmdline argv opts
    [ "${#argv[@]}" -eq 5 ]
    [ "${argv[3]}" = "-bind-to" ]
    [ "${argv[4]}" = "core" ]
}

# ---------- flux: cmdline ----------

@test "flux cmdline translates a full placement" {
    declare -A opts=([procs]=8 [procs-per-node]=4 [hostnames]="h0,h1")
    declare -a argv
    _knit_launch_flux_cmdline argv opts
    # procs-per-node becomes a node count: nnodes = ceil(8 / 4) = 2.
    [ "${#argv[@]}" -eq 7 ]
    [ "${argv[0]}" = "flux" ]
    [ "${argv[1]}" = "run" ]
    [ "${argv[2]}" = "-n" ]
    [ "${argv[3]}" = "8" ]
    [ "${argv[4]}" = "-N" ]
    [ "${argv[5]}" = "2" ]
    [ "${argv[6]}" = "--requires=host:h0,h1" ]
}

@test "flux cmdline rounds the node count up when procs is not a multiple" {
    declare -A opts=([procs]=5 [procs-per-node]=2)
    declare -a argv
    _knit_launch_flux_cmdline argv opts
    # nnodes = ceil(5 / 2) = 3.
    [ "${#argv[@]}" -eq 6 ]
    [ "${argv[2]}" = "-n" ]
    [ "${argv[3]}" = "5" ]
    [ "${argv[4]}" = "-N" ]
    [ "${argv[5]}" = "3" ]
}

@test "flux cmdline omits the node count when procs-per-node has no procs" {
    declare -A opts=([procs-per-node]=4)
    declare -a argv
    _knit_launch_flux_cmdline argv opts
    # Without procs the node count cannot be computed, so -N is not emitted.
    [ "${#argv[@]}" -eq 2 ]
    [ "${argv[0]}" = "flux" ]
    [ "${argv[1]}" = "run" ]
}

@test "flux cmdline emits only the flags whose options are set" {
    declare -A opts=([procs]=4)
    declare -a argv
    _knit_launch_flux_cmdline argv opts
    [ "${#argv[@]}" -eq 4 ]
    [ "${argv[0]}" = "flux" ]
    [ "${argv[1]}" = "run" ]
    [ "${argv[2]}" = "-n" ]
    [ "${argv[3]}" = "4" ]
}

@test "flux cmdline with no options is just the launcher" {
    declare -A opts
    declare -a argv
    _knit_launch_flux_cmdline argv opts
    [ "${#argv[@]}" -eq 2 ]
    [ "${argv[0]}" = "flux" ]
    [ "${argv[1]}" = "run" ]
}

@test "flux cmdline translates cpus-per-proc and gpus-per-proc natively" {
    declare -A opts=([procs]=8 [cpus-per-proc]=4 [gpus-per-proc]=1)
    declare -a argv
    _knit_launch_flux_cmdline argv opts
    [ "${#argv[@]}" -eq 8 ]
    [ "${argv[2]}" = "-n" ]
    [ "${argv[3]}" = "8" ]
    [ "${argv[4]}" = "-c" ]
    [ "${argv[5]}" = "4" ]
    [ "${argv[6]}" = "-g" ]
    [ "${argv[7]}" = "1" ]
}

@test "flux cmdline maps a bind level to per-task cpu-affinity" {
    declare -A opts=([bind]=core)
    declare -a argv
    _knit_launch_flux_cmdline argv opts
    [ "${#argv[@]}" -eq 4 ]
    [ "${argv[2]}" = "-o" ]
    [ "${argv[3]}" = "cpu-affinity=per-task" ]
}

@test "flux cmdline maps a none bind to off cpu-affinity" {
    declare -A opts=([bind]=none)
    declare -a argv
    _knit_launch_flux_cmdline argv opts
    [ "${argv[2]}" = "-o" ]
    [ "${argv[3]}" = "cpu-affinity=off" ]
}

@test "flux cmdline passes gpu-bind through as a gpu-affinity policy" {
    declare -A opts=([gpu-bind]=per-task)
    declare -a argv
    _knit_launch_flux_cmdline argv opts
    [ "${argv[2]}" = "-o" ]
    [ "${argv[3]}" = "gpu-affinity=per-task" ]
}

@test "flux cmdline appends launcher-args verbatim" {
    declare -A opts=([procs]=2 [launcher-args]="-o mpi=spectrum")
    declare -a argv
    _knit_launch_flux_cmdline argv opts
    [ "${#argv[@]}" -eq 6 ]
    [ "${argv[4]}" = "-o" ]
    [ "${argv[5]}" = "mpi=spectrum" ]
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

@test "_knit_launch_cmdline routes to the flux backend" {
    declare -A opts=([procs]=2)
    declare -a argv
    _knit_launch_cmdline flux opts argv
    [ "${argv[0]}" = "flux" ]
    [ "${argv[1]}" = "run" ]
}

# ---------- backend selection: never auto-detected ----------

@test "_knit_launch_backend selects slurm via an explicit override" {
    _knit_metadata_get()    { local -n __r=$1; __r='openmpi'; }
    _knit_detect_launcher() { printf 'mpich\n'; }
    local out
    _knit_launch_backend out slurm
    [ "$out" = "slurm" ]
}

@test "_knit_launch_backend selects pbs via metadata" {
    _knit_metadata_get()    { local -n __r=$1; __r='pbs'; }
    _knit_detect_launcher() { printf 'openmpi\n'; }
    local out
    _knit_launch_backend out
    [ "$out" = "pbs" ]
}

# ---------- exec: prepends the launcher argv to the worker ----------

@test "slurm exec runs the launcher argv followed by the worker command" {
    declare -A opts
    _knit_launch_slurm_cmdline() { local -n _o="$1"; _o=(echo LAUNCHED); }
    run _knit_launch_slurm_exec opts -- worker arg1
    [ "$status" -eq 0 ]
    [ "$output" = "LAUNCHED worker arg1" ]
}

@test "pbs exec runs the launcher argv followed by the worker command" {
    declare -A opts
    _knit_launch_pbs_cmdline() { local -n _o="$1"; _o=(echo LAUNCHED); }
    run _knit_launch_pbs_exec opts -- worker arg1
    [ "$status" -eq 0 ]
    [ "$output" = "LAUNCHED worker arg1" ]
}

@test "slurm exec tolerates a missing -- separator" {
    declare -A opts
    _knit_launch_slurm_cmdline() { local -n _o="$1"; _o=(echo LAUNCHED); }
    run _knit_launch_slurm_exec opts worker
    [ "$status" -eq 0 ]
    [ "$output" = "LAUNCHED worker" ]
}

@test "pbs exec returns the launched command's exit status" {
    declare -A opts
    _knit_launch_pbs_cmdline() { local -n _o="$1"; _o=(env); }
    run _knit_launch_pbs_exec opts -- bash -c 'exit 5'
    [ "$status" -eq 5 ]
}

@test "flux exec runs the launcher argv followed by the worker command" {
    declare -A opts
    _knit_launch_flux_cmdline() { local -n _o="$1"; _o=(echo LAUNCHED); }
    run _knit_launch_flux_exec opts -- worker arg1
    [ "$status" -eq 0 ]
    [ "$output" = "LAUNCHED worker arg1" ]
}

@test "flux exec returns the launched command's exit status" {
    declare -A opts
    _knit_launch_flux_cmdline() { local -n _o="$1"; _o=(env); }
    run _knit_launch_flux_exec opts -- bash -c 'exit 5'
    [ "$status" -eq 5 ]
}
