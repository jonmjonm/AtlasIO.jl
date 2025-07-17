## This script reads in one of the multiscale map assignments
## Then it calculates the histogram of the districts containing a given precict


import json
import sys,os
sys.path.append('../PythonReader/')
import AtlasIO
import helper_functions as hf

import matplotlib.pyplot as plt
import pandas as pd
import seaborn as sns


atlasDir="../ExampleAtlas/"
#atlasFileName="atlas_truncated_nc_multiscale.jsonl" #Small number of real maps
atlasFileName="atlas_nc_multiscale.jsonl.gz" #full set of real maps

pctDataDir="../Shapefile_JSON/"
pctDataFileName="pct21_20votes_wMCD.json" 

atlas = AtlasIO.openAtlas(os.path.join(atlasDir,atlasFileName))    
pctDataFile = open(os.path.join(pctDataDir,pctDataFileName))
pctData = json.load(pctDataFile)

dataElection = pctData['nodes']
hf.addTotalVotes(dataElection)

print(atlas)
map = []
print("\n")
electionName = "G16_USS"  # This is the name of the election we will consider.

pctToDistVotes = {}
for node in pctData["nodes"]:
    pctToDistVotes[node["id"]] = {}

mapCount=0
while map is not None:  # This loops through all of the map in the atlas
    mapCount+=1
    try:
        map = AtlasIO.nextMap(atlas)  # Get the next map in the atlas 
        if mapCount % 5000==0 :
            print(map.name)
        # The maps are multi scale in the sense that if a county is kept whole
        # the following fuction makes a map from precicts to districts out of 
        # the multiscale assignement 
        node_to_dist = hf.get_node_to_district(map.districting, 
                                               pctData["nodes"]) 
        # The next fuction  sums up the election for this districting (defined 
        # by the map)
        distVoteR, distVoteD, distVoteT = hf.sumElection(electionName, 
                                                         node_to_dist, 
                                                         dataElection)
        for id in pctToDistVotes.keys():
            votes = {}
            votes["Dem"] = distVoteD[node_to_dist[id]]
            votes["Rep"] = distVoteD[node_to_dist[id]]
            votes["Total"] = distVoteT[node_to_dist[id]]
            pctToDistVotes[id][map.name] = votes
    
        

    except Exception:
        break


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
df["Dem %"] = df["Dem"]/df["Total"]
print(df)

sns.displot(data=df, x="Dem %", bins=10, stat="density")
plt.show()    
