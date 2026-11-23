## The simplest use of the atlasio package: open an atlas, print its header, then each map.
##
## Install the package once with:   pip install atlasio
## Run:                             python example_atlas.py
## (Examples for the original PythonReader/AtlasIO.py are at the v0.2.4 tag:
##  https://github.com/jonmjonm/AtlasIO.jl/tree/v0.2.4/PythonExamples)

import os
import atlasio

HERE = os.path.dirname(os.path.abspath(__file__))
atlasDir = os.path.join(HERE, "..", "ExampleAtlas")
#atlasFileName = "test.jsonl"                           # fake simple maps
atlasFileName = "atlas_truncated_nc_multiscale.jsonl"   # a small number of real maps
#atlasFileName = "atlas_nc_multiscale.jsonl.gz"         # the full set of real maps (compressed)

with atlasio.open_atlas(os.path.join(atlasDir, atlasFileName)) as atlas:
    print(atlas)
    print("description:     ", atlas.description)
    print("date:            ", atlas.date)
    print("format version:  ", atlas.format_version)
    print("atlas parameters:", sorted(atlas.params))
    print()
    count = 0
    for m in atlas:                  # one Map per line, in order
        count += 1
        print(m)                     # its name, weight and number of regions
        # m.districting maps each region's key, a tuple of names such as ("WAKE",) or
        # ("MECKLENBURG", "052"), to its district number; m.data holds the map's data.

print("\n%d maps" % count)
