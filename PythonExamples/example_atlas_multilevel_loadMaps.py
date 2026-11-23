## This script reads the maps of a multiscale atlas and sums an election in each map's districts.
## (It prints the totals; do something more with each map where marked.)
##
## Install the package once with:   pip install atlasio
## Run:                             python example_atlas_multilevel_loadMaps.py [atlas file]

import json
import os
import sys

import atlasio

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.append(os.path.join(HERE, "..", "PythonReader"))   # for the election helpers only
import helper_functions as hf

atlasDir = os.path.join(HERE, "..", "ExampleAtlas")
atlasFileName = "atlas_truncated_nc_multiscale.jsonl"   # a small number of real maps
#atlasFileName = "atlas_nc_multiscale.jsonl.gz"         # the full set of real maps
atlasPath = sys.argv[1] if len(sys.argv) > 1 else os.path.join(atlasDir, atlasFileName)

pctDataDir = os.path.join(HERE, "..", "Shapefile_JSON")
pctDataFileName = "pct21_20votes_wMCD.json"
with open(os.path.join(pctDataDir, pctDataFileName)) as pctDataFile:
    pctData = json.load(pctDataFile)

dataElection = pctData["nodes"]
hf.addTotalVotes(dataElection)

electionName = "G16_USS"

with atlasio.open_atlas(atlasPath) as atlas:
    print(atlas)
    for m in atlas:  # This loops through all of the maps in the atlas
        print(m.name)
        # The maps are multiscale: a county kept whole is assigned as one region, ("WAKE",), and a
        # split county by its precincts, ("MECKLENBURG", "052"). This function turns that into a map
        # from each precinct to its district.
        node_to_dist = hf.get_node_to_district(m.districting, pctData["nodes"])

        # Sum the election in each district of this map.
        print("summing votes for election: ", electionName)
        distVoteR, distVoteD, distVoteT = hf.sumElection(electionName, node_to_dist, dataElection)
        print("votes: ", distVoteR, distVoteD, distVoteT, "\n")

        # DO SOMETHING WITH THE MAP HERE
