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
# The profile tree is at least two levels deep (src/profiles/<namespace>/
# <machine>.json, possibly with a further /<variant> segment such as
# nersc/perlmutter/cpu.json), so index.json itself (a top-level file) is excluded
# by -mindepth 2 rather than by name; no maxdepth bound is imposed.
#
# Profiles whose JSON sets "_hide": true are excluded from the index so they are
# not advertised by `knit profile list` (they remain resolvable by name).
#
set -euo pipefail

cd "$(dirname "$0")/.."

root="src/profiles"

while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    # Skip hidden profiles (jq is available here, in the generator).
    if [[ "$(jq -r '._hide // false' "${f}")" == "true" ]]; then
        continue
    fi
    name="${f#"${root}/"}"
    printf '%s\n' "${name%.json}"
done < <(find "${root}" -mindepth 2 -type f -name '*.json' | LC_ALL=C sort) \
    | jq -R -s 'split("\n") | map(select(length > 0))' \
    > "${root}/index.json"
