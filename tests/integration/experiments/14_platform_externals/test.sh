#!/usr/bin/env bash
# Integration test 14_platform_externals.
#
# Bootstrap provisions the knit-private Spack (a git clone, comparable in cost to
# the from-source sqlite build the other tests already do), so this runs as part
# of the normal suite.
#
# Proves that a machine profile can hand Spack a system package as a non-buildable
# external, and that a Spack-backed setup then *uses* that external instead of
# rebuilding it:
#
#   - a shipped profile declares the system `make` (gmake) as an external with
#     buildable: false, pointed at its real prefix. Bootstrap --profile renders
#     it into .knit/packages.yaml.
#   - a setup declares knit_with_spack_specs "gmake"; knit creates the Spack env,
#     merges .knit/packages.yaml, and installs. Because gmake is buildable: false,
#     Spack *cannot* build it — a successful install therefore proves it resolved
#     to the external. The install tree is checked to contain no built gmake, and
#     the concretization is confirmed to point at the external prefix.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/14_platform_externals/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/14-platform-externals-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/14_platform_externals/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# The external to advertise: the system GNU Make. Its prefix is the parent of
# its bin directory (/usr/bin/make -> /usr); its version is declared verbatim in
# the external entry (Spack trusts an explicit external's version).
# --------------------------------------------------------------------------
MAKE_BIN=$(command -v make) || fail "no system 'make' found on the login node"
MAKE_PREFIX=${MAKE_BIN%/bin/make}
[[ "${MAKE_PREFIX}" != "${MAKE_BIN}" ]] || fail "make is not under a bin/ prefix: ${MAKE_BIN}"
MAKE_VER=$(make --version | sed -n '1s/.*Make \([0-9][0-9.]*\).*/\1/p')
[[ -n "${MAKE_VER}" ]] || fail "could not parse the system make version"

# Profile: gmake as a non-buildable external at the system prefix.
cat >"${WORKDIR}/ext.json" <<JSON
{
    "description": "Profile providing the system make (gmake) as a non-buildable Spack external.",
    "externals": [
        { "name": "gmake", "spec": "gmake@${MAKE_VER}", "prefix": "${MAKE_PREFIX}", "buildable": false }
    ]
}
JSON

# --------------------------------------------------------------------------
# Bootstrap with the profile. A registered setup declares a Spack environment,
# so bootstrap provisions the knit-private Spack automatically (no --spack
# needed). This clones Spack and can take several minutes.
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-14" \
    --profile "${WORKDIR}/ext.json"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

check_file ".knit/spack/bin/spack" \
    "bootstrap auto-provisioned the private Spack (setup requires it)"

# --------------------------------------------------------------------------
# The profile's externals rendered into .knit/packages.yaml.
# --------------------------------------------------------------------------
check_file ".knit/packages.yaml" "bootstrap rendered the profile externals"
check_grep "^  gmake:" ".knit/packages.yaml" \
    "packages.yaml has the gmake external entry"
check_grep "prefix: ${MAKE_PREFIX}\$" ".knit/packages.yaml" \
    "packages.yaml records the external prefix"
check_grep "buildable: false" ".knit/packages.yaml" \
    "packages.yaml marks gmake non-buildable"

# --------------------------------------------------------------------------
# Build the Spack-backed setup. knit writes spack.yaml for the "gmake" spec,
# merges .knit/packages.yaml, and installs. gmake is buildable: false, so a
# successful install can only mean the external was used.
# --------------------------------------------------------------------------
./experiment.sh setup --name genv -- makeenv

check_file "setups/genv/.activate.sh" "setup produced .activate.sh"
ENV_DIR="${WORKDIR}/setups/genv/spack-env"
check_file "${ENV_DIR}/spack.lock" "setup concretized the Spack environment"

# --------------------------------------------------------------------------
# The external was used, not rebuilt:
#   - nothing named gmake-* was installed into the knit-private Spack tree; and
#   - the environment's concretized gmake points at the external prefix.
# --------------------------------------------------------------------------
if find .knit/spack/opt -type d -name 'gmake-*' 2>/dev/null | grep -q .; then
    fail "gmake was built into the private Spack tree (external not used)"
else
    __assert_pass "no gmake was built into the private Spack tree"
fi

# The concretized gmake reports the external prefix (not a hash path under the
# private Spack install tree). `spack find --paths` prints "<spec>  <prefix>".
gmake_path=$(./experiment.sh spack -e "${ENV_DIR}" find --paths --no-groups gmake \
    2>/dev/null | sed -n 's/^gmake@[^ ]* *//p' | head -1)
[[ -n "${gmake_path}" ]] || fail "gmake not present in the concretized environment"
check_eq "${gmake_path}" "${MAKE_PREFIX}" \
    "concretized gmake resolves to the external prefix"
case "${gmake_path}" in
    *".knit/spack"*) fail "gmake resolved into the private Spack tree: ${gmake_path}" ;;
    *) __assert_pass "gmake prefix is outside the private Spack tree" ;;
esac

assert_summary
