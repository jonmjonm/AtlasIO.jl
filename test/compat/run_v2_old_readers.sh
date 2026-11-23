#!/bin/bash
# Old readers on v2 files fail safely: AtlasIO 0.1.5 and 0.2.0 (which predate v2) read every v2 fixture's
# header, nextMapData and skipMap, and raise AtlasFormatError from nextMap. See v2_with_old_reader.jl.
# Usage (from the repository root): bash test/compat/run_v2_old_readers.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for v in 0.1.5 0.2.0; do
    julia --project="$work/env-$v" -e "import Pkg; Pkg.add([Pkg.PackageSpec(name=\"AtlasIO\", version=\"$v\"), Pkg.PackageSpec(name=\"JSON\")])"
    julia --project="$work/env-$v" test/compat/v2_with_old_reader.jl
done
