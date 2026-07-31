#!/usr/bin/env bash
#
# gen-profile-index.sh
#
# Regenerate src/profiles/index.json: the sorted catalogue of the platform
# profiles shipped in the repository, as a JSON array of "<namespace>/<machine>"
# entries, e.g. ["anl/aurora","anl/polaris","ornl/frontier"].
#
# The index is what `knit profile list` downloads to enumerate the available
# profiles, so it must stay in sync with the profile tree. The
# .github/workflows/profile-index.yml workflow runs this on every push that
# touches src/profiles/ and commits the result if it changed.
#
# The profile tree is exactly two levels deep (src/profiles/<namespace>/
# <machine>.json), so index.json itself (a top-level file) is excluded by the
# mindepth/maxdepth bounds rather than by name.
#
set -euo pipefail

cd "$(dirname "$0")/.."

root="src/profiles"

find "${root}" -mindepth 2 -maxdepth 2 -type f -name '*.json' \
    | sed -e "s#^${root}/##" -e 's#\.json$##' \
    | LC_ALL=C sort \
    | jq -R -s 'split("\n") | map(select(length > 0))' \
    > "${root}/index.json"
