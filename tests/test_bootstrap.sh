#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit

    # Each test controls _KNIT_PREFIX and _KNIT_IS_BOOTSTRAPPED explicitly.
    # Point _KNIT_PREFIX at a temp path that does not yet exist.
    __TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${__TEST_TMPDIR}/fake-knit"
    _KNIT_IS_BOOTSTRAPPED=""
}

teardown() {
    rm -rf "${__TEST_TMPDIR}"
    _KNIT_IS_BOOTSTRAPPED=""
}

# ---------- _knit_is_bootstrapped ----------

@test "is bootstrapped returns 1 when prefix directory does not exist" {
    run _knit_is_bootstrapped
    [ "$status" -eq 1 ]
}

@test "is bootstrapped returns 0 when prefix directory exists" {
    mkdir "${_KNIT_PREFIX}"
    run _knit_is_bootstrapped
    [ "$status" -eq 0 ]
}

@test "is bootstrapped caches positive result — survives directory deletion" {
    mkdir "${_KNIT_PREFIX}"
    _knit_is_bootstrapped   # populate cache
    rm -rf "${_KNIT_PREFIX}"
    # Directory is gone but cache says bootstrapped — must still return 0
    run _knit_is_bootstrapped
    [ "$status" -eq 0 ]
}

@test "is bootstrapped re-checks filesystem after cache is cleared" {
    mkdir "${_KNIT_PREFIX}"
    _knit_is_bootstrapped           # populate cache
    rm -rf "${_KNIT_PREFIX}"
    _KNIT_IS_BOOTSTRAPPED=""        # clear cache
    run _knit_is_bootstrapped
    [ "$status" -eq 1 ]
}

# ---------- prerequisites: sha256sum ----------

@test "prerequisite check passes when sha256sum is present" {
    _knit_command_path() { printf '/usr/bin/sha256sum'; }
    run _knit_bootstrap_check_prerequisites
    [ "$status" -eq 0 ]
}

@test "prerequisite check fatals when sha256sum is absent" {
    _knit_command_path() { printf ''; }
    run _knit_bootstrap_check_prerequisites
    [ "$status" -ne 0 ]
    [[ "$output" == *"sha256sum is required"* ]]
}

@test "bootstrap fatals early and creates no prefix when sha256sum is absent" {
    _knit_command_path() { printf ''; }
    run _knit_bootstrap --scheduler local --launcher none
    [ "$status" -ne 0 ]
    [[ "$output" == *"sha256sum is required"* ]]
    [ ! -e "${_KNIT_PREFIX}" ]
}

# ---------- sqlite: symlink vs build decision ----------

# Fake system sqlite3 path handed back by the stubbed _knit_command_path.
__fake_sqlite=""
# Marker created by the stubbed build path.
__sqlite_build_marker=""

# Prepare the prefix and install decision-logic stubs for the sqlite tests.
# _knit_detect_sqlite_dev defaults to "available" (0); tests that need the
# dev-files-absent path override it.
_setup_sqlite_decision() {
    mkdir "${_KNIT_PREFIX}"
    _KNIT_SQLITE_EXE="${_KNIT_PREFIX}/sqlite/bin/sqlite3"
    _KNIT_SQLITE_PREFIX="__unset__"
    __fake_sqlite="${__TEST_TMPDIR}/system-sqlite3"
    printf '#!/bin/sh\n' > "${__fake_sqlite}"
    chmod +x "${__fake_sqlite}"
    __sqlite_build_marker="${__TEST_TMPDIR}/sqlite-built"
    # Stub the from-source build and the framework table creation.
    eval '_knit_build_sqlite() { : > "'"${__sqlite_build_marker}"'"; }'
    eval '_knit_create_metadata_table() { :; }'
    eval '_knit_prov_create_table() { :; }'
    eval '_knit_detect_sqlite_dev() { return 0; }'
}

@test "bootstrap sqlite symlinks the system binary when present with usable dev files" {
    _setup_sqlite_decision
    _knit_command_path() { printf '%s' "${__fake_sqlite}"; }

    _knit_bootstrap_sqlite

    [ -L "${_KNIT_SQLITE_EXE}" ]
    [ "$(readlink "${_KNIT_SQLITE_EXE}")" = "${__fake_sqlite}" ]
    [ ! -e "${__sqlite_build_marker}" ]
    # System sqlite: knit-graph builds against the default paths (no prefix).
    [ "${_KNIT_SQLITE_PREFIX}" = "" ]
}

@test "bootstrap sqlite builds from source when system dev files are unusable" {
    _setup_sqlite_decision
    _knit_command_path() { printf '%s' "${__fake_sqlite}"; }
    _knit_detect_sqlite_dev() { return 1; }

    _knit_bootstrap_sqlite

    [ ! -L "${_KNIT_SQLITE_EXE}" ]
    [ -e "${__sqlite_build_marker}" ]
    # From-source: knit-graph builds against this prefix.
    [ "${_KNIT_SQLITE_PREFIX}" = "${_KNIT_PREFIX}/sqlite" ]
}

@test "bootstrap sqlite builds from source when ignore flag is set" {
    _setup_sqlite_decision
    _knit_command_path() { printf '%s' "${__fake_sqlite}"; }

    _knit_bootstrap_sqlite true

    [ ! -L "${_KNIT_SQLITE_EXE}" ]
    [ -e "${__sqlite_build_marker}" ]
    [ "${_KNIT_SQLITE_PREFIX}" = "${_KNIT_PREFIX}/sqlite" ]
}

@test "bootstrap sqlite builds from source when no system binary present" {
    _setup_sqlite_decision
    _knit_command_path() { printf ''; }

    _knit_bootstrap_sqlite

    [ ! -L "${_KNIT_SQLITE_EXE}" ]
    [ -e "${__sqlite_build_marker}" ]
    [ "${_KNIT_SQLITE_PREFIX}" = "${_KNIT_PREFIX}/sqlite" ]
}

# ---------- jq: symlink vs download decision ----------

__fake_jq=""
__jq_download_marker=""

_setup_jq_decision() {
    mkdir "${_KNIT_PREFIX}"
    _KNIT_JQ_EXE="${_KNIT_PREFIX}/jq/bin/jq"
    __fake_jq="${__TEST_TMPDIR}/system-jq"
    printf '#!/bin/sh\n' > "${__fake_jq}"
    chmod +x "${__fake_jq}"
    __jq_download_marker="${__TEST_TMPDIR}/jq-downloaded"
    eval '_knit_download_jq() { : > "'"${__jq_download_marker}"'"; }'
}

@test "bootstrap jq symlinks the system binary when present and no flag" {
    _setup_jq_decision
    _knit_command_path() { printf '%s' "${__fake_jq}"; }

    _knit_bootstrap_jq

    [ -L "${_KNIT_JQ_EXE}" ]
    [ "$(readlink "${_KNIT_JQ_EXE}")" = "${__fake_jq}" ]
    [ ! -e "${__jq_download_marker}" ]
}

@test "bootstrap jq downloads when ignore flag is set" {
    _setup_jq_decision
    _knit_command_path() { printf '%s' "${__fake_jq}"; }

    _knit_bootstrap_jq true

    [ ! -L "${_KNIT_JQ_EXE}" ]
    [ -e "${__jq_download_marker}" ]
}

@test "bootstrap jq downloads when no system binary present" {
    _setup_jq_decision
    _knit_command_path() { printf ''; }

    _knit_bootstrap_jq

    [ ! -L "${_KNIT_JQ_EXE}" ]
    [ -e "${__jq_download_marker}" ]
}

# ---------- knit-graph: provisioning + provenance ----------

# Marker written by the stubbed build (records the version/url it was built with).
__kg_build_marker=""
# File capturing the (stubbed) "knit metadata store" provenance calls.
__kg_meta=""

# Stub the network+compiler build and capture the metadata calls so the
# provisioning logic (version/url resolution, provenance recording) can be
# exercised without downloading or compiling anything.
_setup_knitgraph_decision() {
    mkdir "${_KNIT_PREFIX}"
    _KNIT_KNITGRAPH_EXE="${_KNIT_PREFIX}/knit-graph/bin/knit-graph"
    __kg_build_marker="${__TEST_TMPDIR}/kg-built"
    __kg_meta="${__TEST_TMPDIR}/kg-meta"
    : > "${__kg_meta}"
    eval '_knit_build_knitgraph() { printf "%s\n" "$*" > "'"${__kg_build_marker}"'"; }'
    eval 'knit() { printf "%s\n" "$*" >> "'"${__kg_meta}"'"; }'
}

@test "knit-graph url is derived from the version" {
    run _knit_knitgraph_url "0.2.0"
    [ "$status" -eq 0 ]
    [ "$output" = "https://github.com/knit-sh/knit-graph/releases/download/v0.2.0/knit-graph-0.2.0.tar.gz" ]
}

@test "bootstrap knit-graph builds the pinned default and records provenance" {
    _setup_knitgraph_decision

    _knit_bootstrap_knitgraph

    # Built with the pinned version and its derived url.
    grep -q "${_KNIT_KNITGRAPH_VERSION}" "${__kg_build_marker}"
    grep -q "knit-graph-${_KNIT_KNITGRAPH_VERSION}.tar.gz" "${__kg_build_marker}"
    # Provenance recorded (version + url).
    grep -q "metadata store --key __knit_graph_version__ --value ${_KNIT_KNITGRAPH_VERSION}" "${__kg_meta}"
    grep -q "metadata store --key __knit_graph_url__ --value https://github.com/knit-sh/knit-graph/releases/download/v${_KNIT_KNITGRAPH_VERSION}/knit-graph-${_KNIT_KNITGRAPH_VERSION}.tar.gz" "${__kg_meta}"
}

@test "bootstrap knit-graph honours an explicit version" {
    _setup_knitgraph_decision

    _knit_bootstrap_knitgraph "9.9.9"

    grep -q "9.9.9" "${__kg_build_marker}"
    grep -q "metadata store --key __knit_graph_version__ --value 9.9.9" "${__kg_meta}"
    grep -q "download/v9.9.9/knit-graph-9.9.9.tar.gz" "${__kg_meta}"
}

@test "bootstrap knit-graph honours an explicit url override" {
    _setup_knitgraph_decision

    _knit_bootstrap_knitgraph "1.2.3" "https://example.com/kg.tgz"

    grep -q "https://example.com/kg.tgz" "${__kg_build_marker}"
    grep -q "metadata store --key __knit_graph_version__ --value 1.2.3" "${__kg_meta}"
    grep -q "metadata store --key __knit_graph_url__ --value https://example.com/kg.tgz" "${__kg_meta}"
}

@test "knit-graph resolver execs the installed binary" {
    _KNIT_KNITGRAPH_EXE="${__TEST_TMPDIR}/fake-kg"
    printf '#!/bin/sh\nprintf "kg:%%s" "$*"\n' > "${_KNIT_KNITGRAPH_EXE}"
    chmod +x "${_KNIT_KNITGRAPH_EXE}"

    run _knit_knit_graph --explain foo
    [ "$status" -eq 0 ]
    [ "$output" = "kg:--explain foo" ]
}

# ---------- bootstrap wiring: sqlite + knit-graph ----------

@test "bootstrap provisions sqlite, jq, and knit-graph" {
    local calls="${__TEST_TMPDIR}/calls"
    : > "${calls}"
    # Stub the heavy provisioning steps and detection so the wiring can run.
    eval '_knit_bootstrap_sqlite() { printf "sqlite:%s\n" "$*" >> "'"${calls}"'"; }'
    eval '_knit_bootstrap_jq() { printf "jq:%s\n" "$*" >> "'"${calls}"'"; }'
    eval '_knit_bootstrap_knitgraph() { printf "knitgraph:%s\n" "$*" >> "'"${calls}"'"; }'
    eval '_knit_bootstrap_need_spack() { return 1; }'
    eval '_knit_detect_job_manager() { printf "local"; }'
    eval '_knit_detect_launcher() { printf "openmpi"; }'
    eval '_knit_detect_node_ncpus() { printf "1"; }'
    eval 'knit() { :; }'

    run _knit_bootstrap
    [ "$status" -eq 0 ]

    # sqlite, jq, and knit-graph are all provisioned. The from-source-vs-system
    # sqlite decision is left to _knit_bootstrap_sqlite.
    grep -q "^sqlite:" "${calls}"
    grep -q "^jq:" "${calls}"
    grep -q "^knitgraph:" "${calls}"
}

# ---------- bootstrap --launcher none (explicit "no launcher", §8.1) ----------

# Stub the heavy provisioning/detection steps and capture metadata writes so the
# launcher-resolution wiring can run without a real DB or network. Detection is
# stubbed to record if it is consulted, so a test can assert it was NOT.
_bootstrap_launcher_stubs() {
    local calls="$1" meta="$2"
    : > "${calls}"; : > "${meta}"
    eval '_knit_bootstrap_sqlite() { :; }'
    eval '_knit_bootstrap_jq() { :; }'
    eval '_knit_bootstrap_knitgraph() { :; }'
    eval '_knit_bootstrap_need_spack() { return 1; }'
    eval '_knit_detect_job_manager() { printf "local"; }'
    eval '_knit_detect_node_ncpus() { printf "1"; }'
    # Fail loudly if detection is consulted for an explicit launcher choice.
    eval '_knit_detect_launcher() { printf "detected\n" >> "'"${calls}"'"; printf "openmpi"; }'
    # Capture only the metadata-store writes.
    eval 'knit() { if [ "$1" = metadata ] && [ "$2" = store ]; then printf "%s\n" "$*" >> "'"${meta}"'"; fi; }'
}

@test "bootstrap --launcher none freezes __launcher__=none without detection" {
    local calls="${__TEST_TMPDIR}/calls" meta="${__TEST_TMPDIR}/meta"
    _bootstrap_launcher_stubs "${calls}" "${meta}"

    run _knit_bootstrap --scheduler local --launcher none
    [ "$status" -eq 0 ]

    # __launcher__ frozen to the explicit "none"...
    grep -q -- '--key __launcher__ --value none' "${meta}"
    # ...and bootstrap-time detection was never consulted.
    [ ! -s "${calls}" ]
}

@test "bootstrap falls back to srun when no MPI-native launcher is detected under slurm" {
    local calls="${__TEST_TMPDIR}/calls" meta="${__TEST_TMPDIR}/meta"
    _bootstrap_launcher_stubs "${calls}" "${meta}"
    # No MPI-native launcher on PATH.
    eval '_knit_detect_launcher() { printf "<unknown>"; }'

    run _knit_bootstrap --scheduler slurm --launcher auto
    [ "$status" -eq 0 ]

    grep -q -- '--key __launcher__ --value slurm' "${meta}"
}

@test "bootstrap falls back to the PBS launcher when no MPI-native launcher is detected under pbs" {
    local calls="${__TEST_TMPDIR}/calls" meta="${__TEST_TMPDIR}/meta"
    _bootstrap_launcher_stubs "${calls}" "${meta}"
    eval '_knit_detect_launcher() { printf "<unknown>"; }'

    run _knit_bootstrap --scheduler pbs --launcher auto
    [ "$status" -eq 0 ]

    grep -q -- '--key __launcher__ --value pbs' "${meta}"
}

@test "bootstrap prefers a detected MPI-native launcher over the scheduler fallback" {
    local calls="${__TEST_TMPDIR}/calls" meta="${__TEST_TMPDIR}/meta"
    _bootstrap_launcher_stubs "${calls}" "${meta}"
    # An MPI-native launcher IS present, so the fallback must not fire.
    eval '_knit_detect_launcher() { printf "openmpi"; }'

    run _knit_bootstrap --scheduler slurm --launcher auto
    [ "$status" -eq 0 ]

    grep -q -- '--key __launcher__ --value openmpi' "${meta}"
}

@test "bootstrap does not fall back to a scheduler launcher without a batch scheduler" {
    local calls="${__TEST_TMPDIR}/calls" meta="${__TEST_TMPDIR}/meta"
    _bootstrap_launcher_stubs "${calls}" "${meta}"
    eval '_knit_detect_launcher() { printf "<unknown>"; }'

    # local scheduler => no scheduler-integrated launcher to fall back to.
    run _knit_bootstrap --scheduler local --launcher auto
    [ "$status" -eq 0 ]

    grep -q -- '--key __launcher__ --value <unknown>' "${meta}"
}

@test "bootstrap __launcher__ enum accepts every documented launcher" {
    # The bootstrap --launcher help advertises these values; the enum must accept
    # each one, including the scheduler-integrated slurm, pbs, and flux backends
    # that are only ever selected explicitly (never auto-detected).
    local v
    for v in auto openmpi mpich pals flux slurm pbs none; do
        knit_type_check "__launcher__" "${v}"
    done
}

@test "bootstrap __scheduler__ enum accepts every documented scheduler" {
    local v
    for v in auto slurm pbs flux local none; do
        knit_type_check "__scheduler__" "${v}"
    done
}

# ---------- bootstrap --platform / __platform__ ----------

@test "bootstrap --platform freezes __platform__" {
    local calls="${__TEST_TMPDIR}/calls" meta="${__TEST_TMPDIR}/meta"
    _bootstrap_launcher_stubs "${calls}" "${meta}"

    run _knit_bootstrap --scheduler local --launcher none --platform mymachine
    [ "$status" -eq 0 ]

    grep -q -- '--key __platform__ --value mymachine' "${meta}"
}

@test "bootstrap derives __platform__ from the profile name when --platform is omitted" {
    if ! command -v jq >/dev/null 2>&1; then skip "jq not available"; fi
    local calls="${__TEST_TMPDIR}/calls" meta="${__TEST_TMPDIR}/meta"
    _bootstrap_launcher_stubs "${calls}" "${meta}"
    _KNIT_JQ_EXE="jq"

    # A resolved profile carrying a "name": bootstrap must freeze it as the
    # platform when the user did not pass --platform.
    eval '_knit_resolve_profile() { local -n __j=$1 __l=$2; __j='"'"'{"name":"anl/polaris"}'"'"'; __l="anl/polaris@main"; }'
    eval '_knit_render_platform_files() { :; }'
    eval '_knit_load_profile() { :; }'

    run _knit_bootstrap --scheduler local --launcher none --profile anl/polaris
    [ "$status" -eq 0 ]

    grep -q -- '--key __platform__ --value anl/polaris' "${meta}"
}

@test "bootstrap --platform overrides the profile name" {
    if ! command -v jq >/dev/null 2>&1; then skip "jq not available"; fi
    local calls="${__TEST_TMPDIR}/calls" meta="${__TEST_TMPDIR}/meta"
    _bootstrap_launcher_stubs "${calls}" "${meta}"
    _KNIT_JQ_EXE="jq"

    eval '_knit_resolve_profile() { local -n __j=$1 __l=$2; __j='"'"'{"name":"anl/polaris"}'"'"'; __l="anl/polaris@main"; }'
    eval '_knit_render_platform_files() { :; }'
    eval '_knit_load_profile() { :; }'

    run _knit_bootstrap --scheduler local --launcher none \
        --profile anl/polaris --platform override
    [ "$status" -eq 0 ]

    grep -q -- '--key __platform__ --value override' "${meta}"
}

@test "bootstrap with a none-launcher profile freezes __launcher__=none without detection" {
    local calls="${__TEST_TMPDIR}/calls" meta="${__TEST_TMPDIR}/meta"
    _bootstrap_launcher_stubs "${calls}" "${meta}"

    # A resolved profile whose launcher.type is "none": it must flow through the
    # profile-as-default path to __launcher__ = none, skipping detection.
    eval '_knit_resolve_profile() { local -n __j=$1 __l=$2; __j="{}"; __l="testprof"; }'
    eval '_knit_render_platform_files() { :; }'
    eval '_knit_load_profile() {
        _KNIT_PROFILE_SCHEDULER_TYPE=""
        _KNIT_PROFILE_LAUNCHER_TYPE="none"
        _KNIT_PROFILE_SCHEDULER_DEFAULT_QUEUE=""
        _KNIT_PROFILE_SCHEDULER_DEFAULT_ARGS=""
        _KNIT_PROFILE_LAUNCHER_DEFAULT_ARGS=""
        _KNIT_PROFILE_CORES_PER_NODE=""
        _KNIT_PROFILE_GPUS_PER_NODE=""
    }'

    # --launcher auto is what the CLI expansion layer injects as the declared
    # default before the body runs; the profile's "none" then supersedes it.
    run _knit_bootstrap --scheduler local --launcher auto --profile testprof
    [ "$status" -eq 0 ]

    grep -q -- '--key __launcher__ --value none' "${meta}"
    [ ! -s "${calls}" ]
}

# ---------- update mode (re-runnable bootstrap): free-to-update options ----------

# File capturing the (stubbed) "knit metadata store" calls of an update.
__update_meta=""

# Prepare a valid, already-bootstrapped experiment for an update-mode call: a
# .knit/ directory with a (fake) database, the prerequisite check satisfied, and
# a knit() stub that records only the metadata-store writes.
_setup_update_mode() {
    mkdir "${_KNIT_PREFIX}"
    _KNIT_DATABASE="${_KNIT_PREFIX}/knit.db"
    : > "${_KNIT_DATABASE}"
    _KNIT_IS_BOOTSTRAPPED="1"
    _knit_command_path() { printf '/usr/bin/sha256sum'; }
    __update_meta="${__TEST_TMPDIR}/update-meta"
    : > "${__update_meta}"
    eval 'knit() { if [ "$1" = metadata ] && [ "$2" = store ]; then printf "%s\n" "$*" >> "'"${__update_meta}"'"; fi; }'
}

@test "update mode stores only the typed free option and leaves the rest" {
    _setup_update_mode
    _KNIT_INVOCATION_RAW_ARGS=(--account new-alloc)

    run _knit_bootstrap --account new-alloc
    [ "$status" -eq 0 ]

    grep -q -- '--key __account__ --value new-alloc --force' "${__update_meta}"
    # Exactly one key was written; no other setting was touched.
    [ "$(grep -c -- '--key' "${__update_meta}")" -eq 1 ]
}

@test "update mode updates every typed free option" {
    _setup_update_mode
    _KNIT_INVOCATION_RAW_ARGS=(--project demo --platform mymachine --account acct \
        --default-walltime 01:00:00 --default-cpus-per-node 64)

    run _knit_bootstrap --project demo --platform mymachine --account acct \
        --default-walltime 01:00:00 --default-cpus-per-node 64
    [ "$status" -eq 0 ]

    grep -q -- '--key __project__ --value demo --force' "${__update_meta}"
    grep -q -- '--key __platform__ --value mymachine --force' "${__update_meta}"
    grep -q -- '--key __account__ --value acct --force' "${__update_meta}"
    grep -q -- '--key __default_walltime__ --value 01:00:00 --force' "${__update_meta}"
    grep -q -- '--key __node_ncpus__ --value 64 --force' "${__update_meta}"
}

@test "a bare re-bootstrap is a no-op that succeeds" {
    _setup_update_mode
    _KNIT_INVOCATION_RAW_ARGS=()

    run _knit_bootstrap
    [ "$status" -eq 0 ]

    # Nothing was written and the user was told there was nothing to update.
    [ ! -s "${__update_meta}" ]
    [[ "$output" == *"nothing to update"* ]]
}

@test "update mode fatals when .knit holds no database" {
    mkdir "${_KNIT_PREFIX}"
    _KNIT_DATABASE="${_KNIT_PREFIX}/knit.db"   # deliberately not created -> malformed
    _KNIT_IS_BOOTSTRAPPED="1"
    _knit_command_path() { printf '/usr/bin/sha256sum'; }
    _KNIT_INVOCATION_RAW_ARGS=(--account x)

    run _knit_bootstrap --account x
    [ "$status" -ne 0 ]
    [[ "$output" == *"no Knit database"* ]]
    # A malformed directory is reported, never silently deleted.
    [ -d "${_KNIT_PREFIX}" ]
}

@test "a failed update leaves .knit intact (no destructive exit trap)" {
    _setup_update_mode
    # A metadata write fatals partway through the update.
    eval 'knit() { if [ "$1" = metadata ]; then knit_fatal "boom"; fi; }'
    _KNIT_INVOCATION_RAW_ARGS=(--account x)

    run _knit_bootstrap --account x
    [ "$status" -ne 0 ]
    # Update mode installs no cleanup trap, so the experiment survives.
    [ -d "${_KNIT_PREFIX}" ]
    [ -f "${_KNIT_DATABASE}" ]
}

@test "update mode preserves the database and untouched rows" {
    knit_test_require_sqlite
    mkdir "${_KNIT_PREFIX}"
    _KNIT_SQLITE_EXE="sqlite3"
    _KNIT_DATABASE="${_KNIT_PREFIX}/knit.db"
    _KNIT_IS_BOOTSTRAPPED="1"
    _knit_command_path() { printf '/usr/bin/sha256sum'; }
    # A real metadata table with two pre-existing rows and the real dispatcher.
    _knit_create_metadata_table
    knit metadata store --key __project__ --value old-project
    knit metadata store --key __account__ --value old-account

    _KNIT_INVOCATION_RAW_ARGS=(--account new-account)
    run _knit_bootstrap --account new-account
    [ "$status" -eq 0 ]

    # The typed key changed, the untyped key kept its value, the DB survived.
    [ "$(_knit_sqlite3 "SELECT value FROM metadata WHERE key='__account__';")" = "new-account" ]
    [ "$(_knit_sqlite3 "SELECT value FROM metadata WHERE key='__project__';")" = "old-project" ]
    [ -f "${_KNIT_DATABASE}" ]
}

@test "update mode --scheduler auto re-runs detection and stores the result" {
    _setup_update_mode
    eval '_knit_detect_job_manager() { printf "slurm"; }'
    _KNIT_INVOCATION_RAW_ARGS=(--scheduler auto)

    run _knit_bootstrap --scheduler auto
    [ "$status" -eq 0 ]

    grep -q -- '--key __scheduler__ --value slurm --force' "${__update_meta}"
}

@test "update mode --scheduler auto maps an undetected scheduler to local" {
    _setup_update_mode
    eval '_knit_detect_job_manager() { printf "<unknown>"; }'
    _KNIT_INVOCATION_RAW_ARGS=(--scheduler auto)

    run _knit_bootstrap --scheduler auto
    [ "$status" -eq 0 ]

    grep -q -- '--key __scheduler__ --value local --force' "${__update_meta}"
}

@test "update mode --scheduler stores an explicit value without detection" {
    _setup_update_mode
    eval '_knit_detect_job_manager() { printf "SHOULD-NOT-RUN"; }'
    _KNIT_INVOCATION_RAW_ARGS=(--scheduler pbs)

    run _knit_bootstrap --scheduler pbs
    [ "$status" -eq 0 ]

    grep -q -- '--key __scheduler__ --value pbs --force' "${__update_meta}"
}

@test "update mode --launcher auto re-runs detection and stores the result" {
    _setup_update_mode
    eval '_knit_detect_launcher() { printf "mpich"; }'
    _KNIT_INVOCATION_RAW_ARGS=(--launcher auto)

    run _knit_bootstrap --launcher auto
    [ "$status" -eq 0 ]

    grep -q -- '--key __launcher__ --value mpich --force' "${__update_meta}"
}

@test "update mode --default-nodefile is stored as an absolute path" {
    _setup_update_mode
    _KNIT_INVOCATION_RAW_ARGS=(--default-nodefile hosts.txt)

    run _knit_bootstrap --default-nodefile hosts.txt
    [ "$status" -eq 0 ]

    grep -q -- '--key __default_nodefile__ --value /' "${__update_meta}"
    grep -q -- 'hosts.txt --force' "${__update_meta}"
}

@test "update meta helper is a no-op for an untyped option" {
    __update_meta="${__TEST_TMPDIR}/update-meta"; : > "${__update_meta}"
    eval 'knit() { printf "%s\n" "$*" >> "'"${__update_meta}"'"; }'

    run _knit_bootstrap_update_meta "account" "__account__" "v" "--project" "demo"
    [ "$status" -eq 1 ]
    [ ! -s "${__update_meta}" ]
}

@test "update meta helper writes and succeeds for a typed option" {
    __update_meta="${__TEST_TMPDIR}/update-meta"; : > "${__update_meta}"
    eval 'knit() { printf "%s\n" "$*" >> "'"${__update_meta}"'"; }'

    run _knit_bootstrap_update_meta "account" "__account__" "v" "--account" "v"
    [ "$status" -eq 0 ]
    grep -q -- 'metadata store --key __account__ --value v --force' "${__update_meta}"
}
