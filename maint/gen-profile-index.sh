#!/usr/bin/env bash
#
# gen-profile-index.sh
#
# Regenerate src/profiles/index.json: the sorted catalogue of the platform
# profiles shipped in the repository, as a JSON array of
# { "name": "<namespace>/<machine>", "description": "..." } objects, e.g.
#
#   [
#   { "name": "anl/aurora", "description": "ALCF Aurora — ..." },
#   { "name": "anl/polaris", "description": "..." }
#   ]
#
# The index is what `knit profile list` downloads to enumerate the available
# profiles (with their descriptions), so it must stay in sync with the profile
# tree. The .github/workflows/profile-index.yml workflow runs this on every push
# that touches src/profiles/ and commits the result if it changed.
#
# One object per line is deliberate: `knit profile list` parses the index
# jq-free (jq may be absent before bootstrap), extracting the name/description
# pair from each object line with sed. That extraction relies on a description
# containing no literal '"' — shipped profile descriptions must avoid one.
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

# One compact JSON object per non-hidden profile, in sorted order.
objects=""
while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    # Skip hidden profiles (jq is available here, in the generator).
    if [[ "$(jq -r '._hide // false' "${f}")" == "true" ]]; then
        continue
    fi
    name="${f#"${root}/"}"
    name="${name%.json}"
    objects+="$(jq -c --arg name "${name}" \
        '{name: $name, description: (.description // "")}' "${f}")"$'\n'
done < <(find "${root}" -mindepth 2 -type f -name '*.json' | LC_ALL=C sort)

objects="${objects%$'\n'}"

if [[ -z "${objects}" ]]; then
    printf '[]\n' > "${root}/index.json"
else
    {
        printf '[\n'
        # Comma-separate the object lines: every line but the last gets a
        # trailing comma.
        printf '%s\n' "${objects}" | sed '$!s/$/,/'
        printf ']\n'
    } > "${root}/index.json"
fi
