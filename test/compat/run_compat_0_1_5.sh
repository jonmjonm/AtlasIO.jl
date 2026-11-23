#!/bin/bash
# Test F, run locally: files written by the current AtlasIO must be readable by AtlasIO 0.1.5.
# Usage (from the repository root): bash test/compat/run_compat_0_1_5.sh
# Needs julia and python3; installs AtlasIO 0.1.5 into a throwaway environment.
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

julia --project=. -e 'import Pkg; Pkg.instantiate()'
julia --project=. test/compat/write_with_current.jl "$work/out"
python3 test/compat/make_compat_expected.py "$work/out"
julia --project="$work/env" -e 'import Pkg; Pkg.add([Pkg.PackageSpec(name="AtlasIO", version="0.1.5"), Pkg.PackageSpec(name="JSON")])'
julia --project="$work/env" test/compat/read_with_0_1_5.jl "$work/out"
