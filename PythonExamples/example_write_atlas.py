## Writing an atlas with the atlasio package: read an atlas, add a statistic to each map's data, and
## write the result as a new atlas. Then read it back.
##
## Install the package once with:   pip install atlasio
## Run:                             python example_write_atlas.py [output file]
## The output defaults to a file in your temporary directory; .gz or .bz2 at the end of the name
## compresses it.

import json
import os
import sys
import tempfile

import atlasio

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.append(os.path.join(HERE, "..", "PythonReader"))   # for the election helpers only
import helper_functions as hf

atlasPath = os.path.join(HERE, "..", "ExampleAtlas", "atlas_truncated_nc_multiscale.jsonl")
outPath = sys.argv[1] if len(sys.argv) > 1 else os.path.join(tempfile.gettempdir(), "atlas_with_seats.jsonl.gz")

with open(os.path.join(HERE, "..", "Shapefile_JSON", "pct21_20votes_wMCD.json")) as f:
    pctData = json.load(f)
dataElection = pctData["nodes"]
hf.addTotalVotes(dataElection)
electionName = "G16_USS"

# like=atlas copies the input's header (description, date, types, format version) and its parameters.
# Arguments given explicitly override them; here the copy is written in format version 2.
with atlasio.open_atlas(atlasPath) as atlas, \
        atlasio.new_atlas(outPath, like=atlas, format_version=2,
                          description=atlas.description + " (with " + electionName + " seats)") as out:
    for m in atlas:
        node_to_dist = hf.get_node_to_district(m.districting, dataElection)
        distVoteR, distVoteD, distVoteT = hf.sumElection(electionName, node_to_dist, dataElection)
        m.data[electionName + " Dem seats"] = sum(distVoteD[d] > distVoteR[d] for d in distVoteT)
        out.add_map(m)     # name, districting, weight and the updated data
    print("wrote %d maps to %s" % (out.count, outPath))

# Read the new atlas back.
with atlasio.open_atlas(outPath) as atlas:
    print(atlas.description, "| format version", atlas.format_version)
    for m in atlas:
        print(m.name, m.data[electionName + " Dem seats"])

# To write maps you made yourself, give each map's districting as a dict from region keys
# (tuples of names) to district numbers:
#
#   with atlasio.new_atlas("my_ensemble.jsonl.gz", description="my ensemble",
#                          params={"districts": 14}) as out:
#       out.add_map("map1", {("WAKE",): 3, ("MECKLENBURG", "052"): 13}, weight=1, data={"score": 0.5})
