#!/usr/bin/env bats

setup() {
    source knit.sh
    # The openmpi backend omits --host inside a PBS allocation (TM supplies the
    # node list); ensure a stray PBS_NODEFILE in the runner's environment does
    # not perturb the default (non-PBS) cmdline assertions below.
    unset PBS_NODEFILE
}

# ---------- openmpi: cmdline ----------

@test "openmpi cmdline translates a full placement" {
    declare -A opts=([procs]=8 [procs-per-node]=4 [hostnames]="h0,h1")
    declare -a argv
    _knit_launch_openmpi_cmdline argv opts
    [ "${#argv[@]}" -eq 7 ]
    [ "${argv[0]}" = "mpirun" ]
    [ "${argv[1]}" = "-n" ]
    [ "${argv[2]}" = "8" ]
    [ "${argv[3]}" = "--npernode" ]
    [ "${argv[4]}" = "4" ]
    [ "${argv[5]}" = "--host" ]
    # Each host carries its slot count (= --procs-per-node) so the rank count
    # fits; a bare "h0,h1" would advertise only one slot per host.
    [ "${argv[6]}" = "h0:4,h1:4" ]
}

@test "openmpi cmdline derives host slots from procs when procs-per-node is unset" {
    declare -A opts=([procs]=4 [hostnames]="h0,h1")
    declare -a argv
    _knit_launch_openmpi_cmdline argv opts
    [ "${#argv[@]}" -eq 5 ]
    [ "${argv[0]}" = "mpirun" ]
    [ "${argv[1]}" = "-n" ]
    [ "${argv[2]}" = "4" ]
    [ "${argv[3]}" = "--host" ]
    # ceil(4 / 2 hosts) = 2 slots per host.
    [ "${argv[4]}" = "h0:2,h1:2" ]
}

@test "openmpi cmdline emits only the flags whose options are set" {
    declare -A opts=([procs]=4)
    declare -a argv
    _knit_launch_openmpi_cmdline argv opts
    [ "${#argv[@]}" -eq 3 ]
    [ "${argv[0]}" = "mpirun" ]
    [ "${argv[1]}" = "-n" ]
    [ "${argv[2]}" = "4" ]
}

@test "openmpi cmdline with no options is just the executable" {
    declare -A opts
    declare -a argv
    _knit_launch_openmpi_cmdline argv opts
    [ "${#argv[@]}" -eq 1 ]
    [ "${argv[0]}" = "mpirun" ]
}

@test "openmpi cmdline passes a hostnames subset through --host" {
    declare -A opts=([hostnames]="h3,h7")
    declare -a argv
    _knit_launch_openmpi_cmdline argv opts
    [ "${#argv[@]}" -eq 3 ]
    [ "${argv[0]}" = "mpirun" ]
    [ "${argv[1]}" = "--host" ]
    [ "${argv[2]}" = "h3,h7" ]
}

@test "openmpi cmdline omits --host inside a PBS allocation (TM supplies hosts)" {
    # Open MPI built --with-tm reads the PBS allocation itself; an explicit
    # --host conflicts with its tm mapper, so the backend drops it and keeps
    # only -n / --npernode when $PBS_NODEFILE is set.
    export PBS_NODEFILE=/tmp/does-not-need-to-exist
    declare -A opts=([procs]=4 [procs-per-node]=2 [hostnames]="h0,h1")
    declare -a argv
    _knit_launch_openmpi_cmdline argv opts
    unset PBS_NODEFILE
    [ "${#argv[@]}" -eq 5 ]
    [ "${argv[0]}" = "mpirun" ]
    [ "${argv[1]}" = "-n" ]
    [ "${argv[2]}" = "4" ]
    [ "${argv[3]}" = "--npernode" ]
    [ "${argv[4]}" = "2" ]
}

@test "openmpi cmdline appends launcher-args verbatim" {
    declare -A opts=([procs]=2 [launcher-args]="--bind-to core --map-by node")
    declare -a argv
    _knit_launch_openmpi_cmdline argv opts
    [ "${#argv[@]}" -eq 7 ]
    [ "${argv[3]}" = "--bind-to" ]
    [ "${argv[4]}" = "core" ]
    [ "${argv[5]}" = "--map-by" ]
    [ "${argv[6]}" = "node" ]
}

@test "openmpi cmdline translates cpus-per-proc and bind" {
    declare -A opts=([procs]=8 [cpus-per-proc]=4 [bind]=core)
    declare -a argv
    _knit_launch_openmpi_cmdline argv opts
    [ "${#argv[@]}" -eq 7 ]
    [ "${argv[1]}" = "-n" ]
    [ "${argv[2]}" = "8" ]
    [ "${argv[3]}" = "--map-by" ]
    [ "${argv[4]}" = "slot:PE=4" ]
    [ "${argv[5]}" = "--bind-to" ]
    [ "${argv[6]}" = "core" ]
}

@test "openmpi cmdline maps thread bind to hwthread" {
    declare -A opts=([bind]=thread)
    declare -a argv
    _knit_launch_openmpi_cmdline argv opts
    [ "${argv[1]}" = "--bind-to" ]
    [ "${argv[2]}" = "hwthread" ]
}

@test "openmpi cmdline warns and skips GPU placement" {
    declare -A opts=([procs]=2 [gpus-per-proc]=1 [gpu-bind]=closest)
    declare -a argv
    run _knit_launch_openmpi_cmdline argv opts
    [[ "$output" == *"--gpus-per-proc has no portable mpirun flag"* ]]
    [[ "$output" == *"--gpu-bind has no portable mpirun flag"* ]]
    _knit_launch_openmpi_cmdline argv opts
    [ "${#argv[@]}" -eq 3 ]
    [ "${argv[2]}" = "2" ]
}

# ---------- mpich: cmdline ----------

@test "mpich cmdline translates a full placement" {
    declare -A opts=([procs]=8 [procs-per-node]=4 [hostnames]="h0,h1")
    declare -a argv
    _knit_launch_mpich_cmdline argv opts
    [ "${#argv[@]}" -eq 7 ]
    [ "${argv[0]}" = "mpiexec" ]
    [ "${argv[1]}" = "-n" ]
    [ "${argv[2]}" = "8" ]
    [ "${argv[3]}" = "-ppn" ]
    [ "${argv[4]}" = "4" ]
    [ "${argv[5]}" = "-hosts" ]
    [ "${argv[6]}" = "h0,h1" ]
}

@test "mpich cmdline emits only the flags whose options are set" {
    declare -A opts=([procs]=4)
    declare -a argv
    _knit_launch_mpich_cmdline argv opts
    [ "${#argv[@]}" -eq 3 ]
    [ "${argv[0]}" = "mpiexec" ]
    [ "${argv[1]}" = "-n" ]
    [ "${argv[2]}" = "4" ]
}

@test "mpich cmdline with no options is just the executable" {
    declare -A opts
    declare -a argv
    _knit_launch_mpich_cmdline argv opts
    [ "${#argv[@]}" -eq 1 ]
    [ "${argv[0]}" = "mpiexec" ]
}

@test "mpich cmdline appends launcher-args verbatim" {
    declare -A opts=([procs]=2 [launcher-args]="-genv FOO bar")
    declare -a argv
    _knit_launch_mpich_cmdline argv opts
    [ "${#argv[@]}" -eq 6 ]
    [ "${argv[3]}" = "-genv" ]
    [ "${argv[4]}" = "FOO" ]
    [ "${argv[5]}" = "bar" ]
}

@test "mpich cmdline translates bind and warns/skips cpus-per-proc" {
    declare -A opts=([procs]=4 [cpus-per-proc]=2 [bind]=socket)
    declare -a argv
    run _knit_launch_mpich_cmdline argv opts
    [[ "$output" == *"--cpus-per-proc has no native Hydra flag"* ]]
    _knit_launch_mpich_cmdline argv opts
    [ "${#argv[@]}" -eq 5 ]
    [ "${argv[3]}" = "-bind-to" ]
    [ "${argv[4]}" = "socket" ]
}

@test "mpich cmdline warns and skips GPU placement" {
    declare -A opts=([procs]=2 [gpus-per-proc]=1)
    declare -a argv
    run _knit_launch_mpich_cmdline argv opts
    [[ "$output" == *"--gpus-per-proc has no native Hydra flag"* ]]
}

# ---------- pals: cmdline ----------

@test "pals cmdline translates a full placement" {
    declare -A opts=([procs]=8 [procs-per-node]=4 [hostnames]="h0,h1")
    declare -a argv
    _knit_launch_pals_cmdline argv opts
    [ "${#argv[@]}" -eq 7 ]
    [ "${argv[0]}" = "mpiexec" ]
    [ "${argv[1]}" = "-n" ]
    [ "${argv[2]}" = "8" ]
    [ "${argv[3]}" = "--ppn" ]
    [ "${argv[4]}" = "4" ]
    [ "${argv[5]}" = "--hosts" ]
    [ "${argv[6]}" = "h0,h1" ]
}

@test "pals cmdline emits only the flags whose options are set" {
    declare -A opts=([procs]=4)
    declare -a argv
    _knit_launch_pals_cmdline argv opts
    [ "${#argv[@]}" -eq 3 ]
    [ "${argv[0]}" = "mpiexec" ]
    [ "${argv[1]}" = "-n" ]
    [ "${argv[2]}" = "4" ]
}

@test "pals cmdline with no options is just the executable" {
    declare -A opts
    declare -a argv
    _knit_launch_pals_cmdline argv opts
    [ "${#argv[@]}" -eq 1 ]
    [ "${argv[0]}" = "mpiexec" ]
}

@test "pals cmdline passes a hostnames subset through --hosts" {
    declare -A opts=([hostnames]="h3,h7")
    declare -a argv
    _knit_launch_pals_cmdline argv opts
    [ "${#argv[@]}" -eq 3 ]
    [ "${argv[0]}" = "mpiexec" ]
    [ "${argv[1]}" = "--hosts" ]
    [ "${argv[2]}" = "h3,h7" ]
}

@test "pals cmdline appends launcher-args verbatim" {
    declare -A opts=([procs]=2 [launcher-args]="--depth 8 --cpu-bind depth")
    declare -a argv
    _knit_launch_pals_cmdline argv opts
    [ "${#argv[@]}" -eq 7 ]
    [ "${argv[3]}" = "--depth" ]
    [ "${argv[4]}" = "8" ]
    [ "${argv[5]}" = "--cpu-bind" ]
    [ "${argv[6]}" = "depth" ]
}

@test "pals cmdline translates cpus-per-proc to --depth and bind to --cpu-bind" {
    declare -A opts=([procs]=8 [cpus-per-proc]=4 [bind]=core)
    declare -a argv
    _knit_launch_pals_cmdline argv opts
    [ "${#argv[@]}" -eq 7 ]
    [ "${argv[1]}" = "-n" ]
    [ "${argv[2]}" = "8" ]
    [ "${argv[3]}" = "--depth" ]
    [ "${argv[4]}" = "4" ]
    [ "${argv[5]}" = "--cpu-bind" ]
    [ "${argv[6]}" = "core" ]
}

@test "pals cmdline warns and skips GPU placement" {
    declare -A opts=([procs]=2 [gpus-per-proc]=1 [gpu-bind]=closest)
    declare -a argv
    run _knit_launch_pals_cmdline argv opts
    [[ "$output" == *"--gpus-per-proc has no mpiexec flag"* ]]
    [[ "$output" == *"--gpu-bind has no mpiexec flag"* ]]
    _knit_launch_pals_cmdline argv opts
    [ "${#argv[@]}" -eq 3 ]
}

# ---------- dispatcher routing ----------

@test "_knit_launch_cmdline routes to the openmpi backend" {
    declare -A opts=([procs]=2)
    declare -a argv
    _knit_launch_cmdline openmpi opts argv
    [ "${argv[0]}" = "mpirun" ]
}

@test "_knit_launch_cmdline routes to the mpich backend" {
    declare -A opts=([procs]=2)
    declare -a argv
    _knit_launch_cmdline mpich opts argv
    [ "${argv[0]}" = "mpiexec" ]
}

@test "_knit_launch_cmdline routes to the pals backend" {
    declare -A opts=([procs]=2)
    declare -a argv
    _knit_launch_cmdline pals opts argv
    [ "${argv[0]}" = "mpiexec" ]
    [ "${argv[1]}" = "-n" ]
    [ "${argv[2]}" = "2" ]
}

# ---------- exec: prepends the launcher argv to the worker ----------

@test "openmpi exec runs the launcher argv followed by the worker command" {
    declare -A opts
    _knit_launch_openmpi_cmdline() { local -n _o="$1"; _o=(echo LAUNCHED); }
    run _knit_launch_openmpi_exec opts -- worker arg1
    [ "$status" -eq 0 ]
    [ "$output" = "LAUNCHED worker arg1" ]
}

@test "mpich exec runs the launcher argv followed by the worker command" {
    declare -A opts
    _knit_launch_mpich_cmdline() { local -n _o="$1"; _o=(echo LAUNCHED); }
    run _knit_launch_mpich_exec opts -- worker arg1
    [ "$status" -eq 0 ]
    [ "$output" = "LAUNCHED worker arg1" ]
}

@test "openmpi exec tolerates a missing -- separator" {
    declare -A opts
    _knit_launch_openmpi_cmdline() { local -n _o="$1"; _o=(echo LAUNCHED); }
    run _knit_launch_openmpi_exec opts worker
    [ "$status" -eq 0 ]
    [ "$output" = "LAUNCHED worker" ]
}

@test "openmpi exec returns the launched command's exit status" {
    declare -A opts
    _knit_launch_openmpi_cmdline() { local -n _o="$1"; _o=(env); }
    run _knit_launch_openmpi_exec opts -- bash -c 'exit 5'
    [ "$status" -eq 5 ]
}

@test "pals exec runs the launcher argv followed by the worker command" {
    declare -A opts
    _knit_launch_pals_cmdline() { local -n _o="$1"; _o=(echo LAUNCHED); }
    run _knit_launch_pals_exec opts -- worker arg1
    [ "$status" -eq 0 ]
    [ "$output" = "LAUNCHED worker arg1" ]
}

@test "pals exec returns the launched command's exit status" {
    declare -A opts
    _knit_launch_pals_cmdline() { local -n _o="$1"; _o=(env); }
    run _knit_launch_pals_exec opts -- bash -c 'exit 5'
    [ "$status" -eq 5 ]
}
