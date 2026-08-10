#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq
    knit_test_db_setup

    _KNIT_JQ_EXE="jq"
    _KNIT_TEST_TMPDIR="$(mktemp -d)"

    _knit_create_metadata_table

    # Isolate the admin-profile lookup from the real /etc/knit.
    _KNIT_PROFILE_ADMIN_DIR="${_KNIT_TEST_TMPDIR}/etc"
    mkdir -p "${_KNIT_PROFILE_ADMIN_DIR}"

    # A minimal, valid profile used across the resolution tests.
    _SAMPLE_PROFILE='{"scheduler":{"type":"slurm"},"launcher":{"type":"openmpi"}}'

    # Materialization writes under _KNIT_PREFIX; isolate it and the module-init
    # search from the host so the render tests are deterministic.
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/.knit"
    mkdir -p "${_KNIT_PREFIX}"
    unset MODULESHOME
    _KNIT_MODULE_INIT_CANDIDATES=("${_KNIT_TEST_TMPDIR}/none/lmod.sh")
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    knit_test_db_teardown
}

# A stub for the network primitive: serves _STUB_BODY and records the requested
# URL both in _STUB_URL and in a file (so it survives bats 'run' subshells).
_stub_http_ok() {
    _STUB_BODY="${1:-${_SAMPLE_PROFILE}}"
    # shellcheck disable=SC2317 # invoked indirectly after redefinition
    _knit_profile_http_get() {
        local -n __r=$1
        _STUB_URL="$2"
        printf '%s' "$2" > "${_KNIT_TEST_TMPDIR}/last_url"
        _KNIT_PROFILE_LAST_HTTP="200"
        __r="${_STUB_BODY}"
        return 0
    }
}

_stub_http_fail() {
    # shellcheck disable=SC2317 # invoked indirectly after redefinition
    _knit_profile_http_get() {
        _STUB_URL="$2"
        printf '%s' "$2" > "${_KNIT_TEST_TMPDIR}/last_url"
        _KNIT_PROFILE_LAST_HTTP="404"
        return 1
    }
}

# ---------- _knit_resolve_profile : URL ----------

@test "resolve fetches a URL spec verbatim" {
    _stub_http_ok
    local json ref
    _knit_resolve_profile json ref "https://example.com/x.json"
    [ "${json}" = "${_SAMPLE_PROFILE}" ]
    [ "${ref}" = "https://example.com/x.json" ]
    [ "${_STUB_URL}" = "https://example.com/x.json" ]
}

@test "resolve fatals when a URL cannot be fetched" {
    _stub_http_fail
    run _knit_resolve_profile json ref "https://example.com/missing.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"HTTP 404"* ]]
}

# ---------- _knit_resolve_profile : local file ----------

@test "resolve reads an existing local file" {
    local f="${_KNIT_TEST_TMPDIR}/mymachine.json"
    printf '%s' "${_SAMPLE_PROFILE}" > "${f}"
    local json ref
    _knit_resolve_profile json ref "${f}"
    [ "${json}" = "${_SAMPLE_PROFILE}" ]
    [ "${ref}" = "${f}" ]
}

@test "resolve appends .json when looking for a local file" {
    local base="${_KNIT_TEST_TMPDIR}/mymachine"
    printf '%s' "${_SAMPLE_PROFILE}" > "${base}.json"
    local json ref
    _knit_resolve_profile json ref "${base}"
    [ "${json}" = "${_SAMPLE_PROFILE}" ]
    [ "${ref}" = "${base}.json" ]
}

# ---------- _knit_resolve_profile : admin /etc/knit ----------

@test "resolve reads an admin profile" {
    mkdir -p "${_KNIT_PROFILE_ADMIN_DIR}/ornl"
    printf '%s' "${_SAMPLE_PROFILE}" > "${_KNIT_PROFILE_ADMIN_DIR}/ornl/frontier.json"
    _stub_http_fail   # ensure GitHub is not what answered
    local json ref
    _knit_resolve_profile json ref "ornl/frontier"
    [ "${json}" = "${_SAMPLE_PROFILE}" ]
    [ "${ref}" = "${_KNIT_PROFILE_ADMIN_DIR}/ornl/frontier.json" ]
}

@test "an admin profile shadows the GitHub store" {
    mkdir -p "${_KNIT_PROFILE_ADMIN_DIR}/anl"
    printf '%s' '{"admin":true}' > "${_KNIT_PROFILE_ADMIN_DIR}/anl/improv.json"
    _stub_http_ok '{"github":true}'
    local json ref
    _knit_resolve_profile json ref "anl/improv"
    [ "${json}" = '{"admin":true}' ]
    [[ "${ref}" == *"/anl/improv.json" ]]
}

# ---------- _knit_resolve_profile : GitHub shorthand ----------

@test "resolve shorthand defaults the ref to the default branch" {
    _stub_http_ok
    local json ref
    _knit_resolve_profile json ref "anl/polaris"
    [ "${json}" = "${_SAMPLE_PROFILE}" ]
    [[ "${_STUB_URL}" == *"/${_KNIT_PROFILE_DEFAULT_REF}/src/profiles/anl/polaris.json" ]]
    [ "${ref}" = "anl/polaris@${_KNIT_PROFILE_DEFAULT_REF}" ]
}

@test "resolve shorthand honours an explicit @ref" {
    _stub_http_ok
    local json ref
    _knit_resolve_profile json ref "anl/polaris@v1.2.3"
    [[ "${_STUB_URL}" == *"/v1.2.3/src/profiles/anl/polaris.json" ]]
    [ "${ref}" = "anl/polaris@v1.2.3" ]
}

@test "resolve shorthand @latest resolves via the releases API" {
    _stub_http_ok
    # shellcheck disable=SC2317 # invoked indirectly after redefinition
    _knit_profile_latest_ref() { printf 'v9.9.9'; }
    local json ref
    _knit_resolve_profile json ref "anl/polaris@latest"
    [[ "${_STUB_URL}" == *"/v9.9.9/src/profiles/anl/polaris.json" ]]
    [ "${ref}" = "anl/polaris@v9.9.9" ]
}

@test "resolve shorthand accepts a multi-segment path" {
    _stub_http_ok
    local json ref
    _knit_resolve_profile json ref "nersc/perlmutter/cpu"
    [ "${json}" = "${_SAMPLE_PROFILE}" ]
    [[ "${_STUB_URL}" == *"/${_KNIT_PROFILE_DEFAULT_REF}/src/profiles/nersc/perlmutter/cpu.json" ]]
    [ "${ref}" = "nersc/perlmutter/cpu@${_KNIT_PROFILE_DEFAULT_REF}" ]
}

@test "resolve shorthand accepts a multi-segment path with an @ref" {
    _stub_http_ok
    local json ref
    _knit_resolve_profile json ref "nersc/perlmutter/gpu@v1.2.3"
    [[ "${_STUB_URL}" == *"/v1.2.3/src/profiles/nersc/perlmutter/gpu.json" ]]
    [ "${ref}" = "nersc/perlmutter/gpu@v1.2.3" ]
}

# ---------- _knit_resolve_profile : not found ----------

@test "resolve fatals and enumerates the sources tried" {
    _stub_http_fail
    run _knit_resolve_profile json ref "anl/nope"
    [ "$status" -ne 0 ]
    [[ "$output" == *"anl/nope"* ]]
    [[ "$output" == *"no file"* ]]
    [[ "$output" == *"${_KNIT_PROFILE_ADMIN_DIR}"* ]]
    [[ "$output" == *"HTTP 404"* ]]
}

@test "resolve reports a non-shorthand spec that matched nothing" {
    _stub_http_fail
    run _knit_resolve_profile json ref "weird spec"
    [ "$status" -ne 0 ]
    [[ "$output" == *"shorthand"* ]]
}

# ---------- knit_get_profile_field ----------

@test "knit_get_profile_field reads the frozen profile JSON" {
    _knit_metadata_store --key "__profile_json__" \
        --value '{"scheduler":{"default_queue":"prod"}}'
    [ "$(knit_get_profile_field '.scheduler.default_queue')" = "prod" ]
}

@test "knit_get_profile_field is empty when no profile is configured" {
    [ -z "$(knit_get_profile_field '.scheduler.default_queue')" ]
}

@test "knit_get_profile_field is empty for an absent field" {
    _knit_metadata_store --key "__profile_json__" --value '{"scheduler":{}}'
    [ -z "$(knit_get_profile_field '.scheduler.default_queue')" ]
}

# ---------- index parsing / listing ----------

# A repo index in the shipped format: an array of one-line
# { "name": ..., "description": ..., "hidden": bool } objects.
_INDEX_BODY='[
{ "name": "ornl/frontier", "description": "Frontier machine", "hidden": false },
{ "name": "anl/improv", "description": "Improv machine", "hidden": false },
{ "name": "anl/aurora", "description": "Aurora machine", "hidden": false }
]'

@test "_knit_profile_parse_index extracts name<TAB>description<TAB>hidden per entry" {
    local out
    _knit_profile_parse_index out '[
{ "name": "anl/aurora", "description": "Aurora desc", "hidden": true },
{ "name": "anl/improv", "description": "Improv desc", "hidden": false }
]'
    [ "${out}" = $'anl/aurora\tAurora desc\ttrue\nanl/improv\tImprov desc\tfalse' ]
}

@test "knit_list_profiles fetches, sorts and marks the repo index" {
    _stub_http_ok "${_INDEX_BODY}"
    run knit_list_profiles
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == *"anl/aurora"* ]]
    [[ "${lines[0]}" == *"[github]"* ]]
    [[ "${lines[1]}" == *"anl/improv"* ]]
    [[ "${lines[2]}" == *"ornl/frontier"* ]]
    [[ "$(cat "${_KNIT_TEST_TMPDIR}/last_url")" == *"/src/profiles/index.json" ]]
}

@test "knit_list_profiles shows each profile's description" {
    _stub_http_ok '[
{ "name": "anl/aurora", "description": "ALCF Aurora big machine", "hidden": false }
]'
    run knit_list_profiles
    [ "$status" -eq 0 ]
    [[ "$output" == *"anl/aurora"*"[github]"*"ALCF Aurora big machine"* ]]
}

@test "knit_list_profiles word-wraps a long description under a narrow width" {
    # Force a usable-but-narrow terminal width so wrapping engages.
    # shellcheck disable=SC2317 # invoked indirectly by knit_list_profiles
    _knit_terminal_width() { local -n __w=$1; __w=40; }
    _stub_http_ok '[
{ "name": "anl/aurora", "description": "alpha bravo charlie delta echo foxtrot golf hotel india", "hidden": false }
]'
    run knit_list_profiles
    [ "$status" -eq 0 ]
    # The description wrapped onto more than one line.
    [ "${#lines[@]}" -gt 1 ]
    # Continuation lines hang-indent (leading spaces) and carry no profile name.
    [[ "${lines[1]}" == "  "* ]]
    [[ "${lines[1]}" != *"anl/aurora"* ]]
}

@test "knit_list_profiles hides hidden profiles by default and shows them with --hidden" {
    _stub_http_ok '[
{ "name": "anl/aurora", "description": "visible", "hidden": false },
{ "name": "anl/secret", "description": "top secret", "hidden": true }
]'
    run knit_list_profiles
    [ "$status" -eq 0 ]
    [[ "$output" == *"anl/aurora"* ]]
    [[ "$output" != *"anl/secret"* ]]

    run knit_list_profiles true
    [ "$status" -eq 0 ]
    [[ "$output" == *"anl/aurora"* ]]
    [[ "$output" == *"anl/secret"*"[github, hidden]"*"top secret"* ]]
}

@test "_knit_profile_admin_entries lists /etc/knit profiles by relative path" {
    mkdir -p "${_KNIT_PROFILE_ADMIN_DIR}/anl" "${_KNIT_PROFILE_ADMIN_DIR}/site"
    printf '%s' "${_SAMPLE_PROFILE}" > "${_KNIT_PROFILE_ADMIN_DIR}/anl/improv.json"
    printf '%s' "${_SAMPLE_PROFILE}" > "${_KNIT_PROFILE_ADMIN_DIR}/site/local.json"
    local entries
    _knit_profile_admin_entries entries
    [ "$(printf '%s\n' "${entries}" | cut -f1)" = $'anl/improv\nsite/local' ]
}

@test "_knit_profile_admin_entries carries each profile's description and hidden flag" {
    mkdir -p "${_KNIT_PROFILE_ADMIN_DIR}/site"
    printf '%s' '{"description":"A site profile"}' \
        > "${_KNIT_PROFILE_ADMIN_DIR}/site/local.json"
    local entries
    _knit_profile_admin_entries entries
    [ "${entries}" = $'site/local\tA site profile\tfalse' ]
}

@test "_knit_profile_admin_entries is empty when the admin dir is absent" {
    _KNIT_PROFILE_ADMIN_DIR="${_KNIT_TEST_TMPDIR}/absent"
    local entries="unset"
    _knit_profile_admin_entries entries
    [ -z "${entries}" ]
}

@test "_knit_profile_admin_entries flags profiles marked _hide as hidden" {
    mkdir -p "${_KNIT_PROFILE_ADMIN_DIR}/site"
    printf '%s' '{"description":"shown"}' \
        > "${_KNIT_PROFILE_ADMIN_DIR}/site/shown.json"
    printf '%s' '{"description":"secret","_hide": true}' \
        > "${_KNIT_PROFILE_ADMIN_DIR}/site/secret.json"
    local entries
    _knit_profile_admin_entries entries
    # Both are listed; the marker distinguishes them (sorted by path).
    [ "${entries}" = $'site/secret\tsecret\ttrue\nsite/shown\tshown\tfalse' ]
}

@test "knit_list_profiles omits a hidden admin profile by default, shows it with --hidden" {
    _stub_http_ok '[]'
    mkdir -p "${_KNIT_PROFILE_ADMIN_DIR}/site"
    printf '%s' '{"description":"secret","_hide":true}' \
        > "${_KNIT_PROFILE_ADMIN_DIR}/site/secret.json"
    run knit_list_profiles
    [ "$status" -eq 0 ]
    [[ "$output" != *"site/secret"* ]]

    run knit_list_profiles true
    [ "$status" -eq 0 ]
    [[ "$output" == *"site/secret"*"[admin, hidden]"* ]]
}

@test "knit_list_profiles unions the repo index and the admin store" {
    _stub_http_ok '[
{ "name": "anl/improv", "description": "Improv machine", "hidden": false },
{ "name": "ornl/frontier", "description": "Frontier machine", "hidden": false }
]'
    mkdir -p "${_KNIT_PROFILE_ADMIN_DIR}/site"
    printf '%s' "${_SAMPLE_PROFILE}" > "${_KNIT_PROFILE_ADMIN_DIR}/site/local.json"
    run knit_list_profiles
    [ "$status" -eq 0 ]
    [[ "$output" == *"anl/improv"* ]]
    [[ "$output" == *"ornl/frontier"* ]]
    [[ "$output" == *"site/local"* ]]
    # The admin-only entry is marked as admin, not github.
    [[ "$output" == *"site/local"*"admin"* ]]
}

@test "knit_list_profiles marks an admin profile as shadowing the repo" {
    _stub_http_ok '[
{ "name": "anl/improv", "description": "Improv machine", "hidden": false },
{ "name": "ornl/frontier", "description": "Frontier machine", "hidden": false }
]'
    mkdir -p "${_KNIT_PROFILE_ADMIN_DIR}/anl"
    printf '%s' "${_SAMPLE_PROFILE}" > "${_KNIT_PROFILE_ADMIN_DIR}/anl/improv.json"
    run knit_list_profiles
    [ "$status" -eq 0 ]
    # anl/improv is in both -> shadowing; appears exactly once.
    [ "$(printf '%s\n' "$output" | grep -c 'anl/improv')" -eq 1 ]
    [[ "$output" == *"anl/improv"*"admin (shadows github)"* ]]
}

@test "knit_list_profiles still lists admin profiles when the index is unreachable" {
    _stub_http_fail
    mkdir -p "${_KNIT_PROFILE_ADMIN_DIR}/site"
    printf '%s' "${_SAMPLE_PROFILE}" > "${_KNIT_PROFILE_ADMIN_DIR}/site/local.json"
    run knit_list_profiles
    [ "$status" -eq 0 ]
    [[ "$output" == *"site/local"*"admin"* ]]
}

# ---------- profile show ----------

@test "profile show prints the frozen profile of a bootstrapped experiment" {
    _knit_metadata_store --key "__profile_json__" \
        --value '{"scheduler":{"type":"slurm"}}'
    run _knit_profile_show
    [ "$status" -eq 0 ]
    [[ "$output" == *'"scheduler"'* ]]
    [[ "$output" == *'"slurm"'* ]]
}

@test "profile show fatals when bootstrapped without a profile" {
    run _knit_profile_show
    [ "$status" -ne 0 ]
    [[ "$output" == *"without a profile"* ]]
}

@test "profile show resolves and prints a spec when not bootstrapped" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/absent-knit"
    local f="${_KNIT_TEST_TMPDIR}/mymachine.json"
    printf '%s' "${_SAMPLE_PROFILE}" > "${f}"
    run _knit_profile_show --profile "${f}"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"openmpi"'* ]]
}

@test "profile show requires a spec when not bootstrapped" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/absent-knit"
    run _knit_profile_show
    [ "$status" -ne 0 ]
    [[ "$output" == *"profile spec is required"* ]]
}

# ---------- _knit_render_platform_files : platform.sh ----------

@test "render writes a well-formed platform.sh (init, purge, load, exports)" {
    local init="${_KNIT_TEST_TMPDIR}/init.sh"
    touch "${init}"
    local json
    json="$(jq -nc --arg i "${init}" \
        '{module_init:$i, module_purge:true,
          modules:["PrgEnv-gnu","cray-mpich","cmake"],
          environment:{MPICH_GPU_SUPPORT_ENABLED:1, FOO:"a b"}}')"
    _knit_render_platform_files "${json}"

    local f="${_KNIT_PREFIX}/platform.sh"
    [ -f "${f}" ]
    grep -Fqx "source ${init}" "${f}"
    grep -Fqx "module purge" "${f}"
    grep -Fqx "module load PrgEnv-gnu cray-mpich cmake" "${f}"
    # One module load line only.
    [ "$(grep -c '^module load ' "${f}")" -eq 1 ]
    grep -Fqx "export MPICH_GPU_SUPPORT_ENABLED=1" "${f}"
    # The space in the value is shell-quoted by %q.
    grep -Fqx 'export FOO=a\ b' "${f}"
}

@test "render omits module purge when module_purge is absent/false" {
    local init="${_KNIT_TEST_TMPDIR}/init.sh"
    touch "${init}"
    local json
    json="$(jq -nc --arg i "${init}" '{module_init:$i, modules:["cmake"]}')"
    _knit_render_platform_files "${json}"
    ! grep -Fqx "module purge" "${_KNIT_PREFIX}/platform.sh"
}

@test "render leaves platform.sh absent when no modules or environment" {
    _knit_render_platform_files '{"scheduler":{"type":"slurm"}}'
    [ ! -f "${_KNIT_PREFIX}/platform.sh" ]
}

@test "render writes an environment-only platform.sh with no module lines" {
    _knit_render_platform_files '{"environment":{"X":"1"}}'
    local f="${_KNIT_PREFIX}/platform.sh"
    [ -f "${f}" ]
    grep -Fqx "export X=1" "${f}"
    ! grep -q "^module " "${f}"
    ! grep -q "^source " "${f}"
}

@test "render finds the module init via the candidate search" {
    local cand="${_KNIT_TEST_TMPDIR}/search/lmod.sh"
    mkdir -p "$(dirname "${cand}")"
    touch "${cand}"
    _KNIT_MODULE_INIT_CANDIDATES=("${cand}")
    _knit_render_platform_files '{"modules":["cmake"]}'
    grep -Fqx "source ${cand}" "${_KNIT_PREFIX}/platform.sh"
}

@test "render honours the MODULESHOME-derived init path" {
    export MODULESHOME="${_KNIT_TEST_TMPDIR}/mh"
    mkdir -p "${MODULESHOME}/init"
    touch "${MODULESHOME}/init/bash"
    _knit_render_platform_files '{"modules":["cmake"]}'
    grep -Fqx "source ${MODULESHOME}/init/bash" "${_KNIT_PREFIX}/platform.sh"
}

@test "render fatals when modules are listed but no init resolves" {
    # Candidate list points at nothing and module is not a shell function here.
    _KNIT_MODULE_INIT_CANDIDATES=("${_KNIT_TEST_TMPDIR}/absent/lmod.sh")
    run _knit_render_platform_files '{"modules":["cmake"]}'
    [ "$status" -ne 0 ]
    [[ "$output" == *"no 'module' init script"* ]]
    [ ! -f "${_KNIT_PREFIX}/platform.sh" ]
}

# ---------- _knit_render_platform_files : spack-config.json ----------

@test "render writes spack-config.json wrapping the spack object verbatim" {
    local json='{"spack":{
        "packages":{
            "cray-mpich":{"externals":[{"spec":"cray-mpich@9.0.1","prefix":"/opt/cray"}],"buildable":false},
            "mpi":{"require":["cray-mpich"]}
        },
        "concretizer":{"reuse":true}
    }}'
    _knit_render_platform_files "${json}"

    local f="${_KNIT_PREFIX}/spack-config.json"
    [ -f "${f}" ]
    # A single file wrapped under a top-level `spack` key (env-manifest form).
    [ "$(jq -r 'keys[]' "${f}")" = "spack" ]
    # Every section and its content is passed through verbatim.
    [ "$(jq -r '.spack.packages.mpi.require[0]' "${f}")" = "cray-mpich" ]
    [ "$(jq -r '.spack.packages["cray-mpich"].buildable' "${f}")" = "false" ]
    [ "$(jq -r '.spack.packages["cray-mpich"].externals[0].spec' "${f}")" = "cray-mpich@9.0.1" ]
    [ "$(jq -r '.spack.concretizer.reuse' "${f}")" = "true" ]
}

@test "render leaves spack-config.json absent when no spack object" {
    _knit_render_platform_files '{"modules":["cmake"],"module_init":"/dev/null"}'
    [ ! -f "${_KNIT_PREFIX}/spack-config.json" ]
}

@test "render writes nothing for an empty spack object" {
    _knit_render_platform_files '{"spack":{}}'
    [ ! -f "${_KNIT_PREFIX}/spack-config.json" ]
}
