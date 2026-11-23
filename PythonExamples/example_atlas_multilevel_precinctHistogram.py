## This script reads the maps of a multiscale atlas and, for each precinct, records the vote in the
## district containing it in every map. It then plots the histogram of that district's Democratic vote
## share for one precinct.
##
## Install the package once with:   pip install atlasio   (plus pandas, seaborn and matplotlib)
## Run:                             python example_atlas_multilevel_precinctHistogram.py [atlas file]

import json
import os
import sys

import atlasio

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.append(os.path.join(HERE, "..", "PythonReader"))   # for the election helpers only
import helper_functions as hf

import matplotlib.pyplot as plt
import pandas as pd
import seaborn as sns


atlasDir = os.path.join(HERE, "..", "ExampleAtlas")
#atlasFileName = "atlas_truncated_nc_multiscale.jsonl"  # a small number of real maps
atlasFileName = "atlas_nc_multiscale.jsonl.gz"          # the full set of real maps
atlasPath = sys.argv[1] if len(sys.argv) > 1 else os.path.join(atlasDir, atlasFileName)

pctDataDir = os.path.join(HERE, "..", "Shapefile_JSON")
pctDataFileName = "pct21_20votes_wMCD.json"
with open(os.path.join(pctDataDir, pctDataFileName)) as pctDataFile:
    pctData = json.load(pctDataFile)

dataElection = pctData["nodes"]
hf.addTotalVotes(dataElection)

electionName = "G16_USS"  # This is the name of the election we will consider.

pctToDistVotes = {}
for node in pctData["nodes"]:
    pctToDistVotes[node["id"]] = {}

with atlasio.open_atlas(atlasPath) as atlas:
    print(atlas, "\n")
    for mapCount, m in enumerate(atlas, start=1):  # This loops through all of the maps in the atlas
        if mapCount % 5000 == 0:
            print(mapCount, m.name)
        # The maps are multiscale: a county kept whole is assigned as one region, ("WAKE",), and a
        # split county by its precincts, ("MECKLENBURG", "052"). This function turns that into a map
        # from each precinct to its district.
        node_to_dist = hf.get_node_to_district(m.districting, pctData["nodes"])
        # Sum the election in each district of this map.
        distVoteR, distVoteD, distVoteT = hf.sumElection(electionName, node_to_dist, dataElection)
        for id in pctToDistVotes.keys():
            d = node_to_dist[id]
            pctToDistVotes[id][m.name] = {"Dem": distVoteD[d], "Rep": distVoteR[d], "Total": distVoteT[d]}


# now do something with data
id = 100  # Choose precinct
print(dataElection[id]["county"], dataElection[id]["prec_id"])

# or
county = "BEAUFORT"
prec_id = "BLCK"
id = [ii for ii in range(len(dataElection))
      if dataElection[ii]["county"] == county
      and dataElection[ii]["prec_id"] == prec_id][0]
print(id)

df = pd.DataFrame(pctToDistVotes[id]).T
df["Dem %"] = df["Dem"] / df["Total"]
print(df)

sns.displot(data=df, x="Dem %", bins=10, stat="density")
plt.show()
