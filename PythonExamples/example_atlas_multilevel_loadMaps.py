## This script reads in one of the multi scale map assignments
## CURRENTLY CODE DOES NOTHING WITH THE MAPS

import json
import sys,os
sys.path.append('../PythonReader/')
import AtlasIO
import helper_functions as hf

import matplotlib.pyplot as plt
import pandas as pd
import seaborn as sns


atlasDir="../ExampleAtlas/"
atlasFileName="atlas_truncated_nc_multiscale.jsonl" #Small number of real maps
#atlasFileName="atlas_nc_multiscale.jsonl.gz" #full set of real maps

pctDataDir="../Shapefile_JSON/"
pctDataFileName="pct21_20votes_wMCD.json" 

atlas = AtlasIO.openAtlas(os.path.join(atlasDir,atlasFileName))    
pctDataFile = open(os.path.join(pctDataDir,pctDataFileName))
pctData = json.load(pctDataFile)

dataElection = pctData['nodes']
hf.addTotalVotes(dataElection)

atlas = AtlasIO.openAtlas(os.path.join(atlasDir,atlasFileName))    
print(atlas)
map = []

electionName = "G16_USS"

pctToDistVotes = {}
for node in pctData["nodes"]:
    pctToDistVotes[node["id"]] = {}

while map is not None:  # This loops through all of the map in the atlas
    try:
        map = AtlasIO.nextMap(atlas)  # Get the next map in the atlas 
        print(map.name)
        # The maps are multi scale in the sense that if a county is kept whole
        # the following fuction makes a map from precicts to districts out of 
        # the multiscale assignement 
        node_to_dist = hf.get_node_to_district(map.districting, 
                                               pctData["nodes"]) 
       
        # The next fuction  sums up the election for this districting (defined 
        # by the map)
        print("summing votes for election: ", electionName)
        distVoteR, distVoteD, distVoteT = hf.sumElection(electionName, 
                                                         node_to_dist, 
                                                         dataElection)
        print("votes: ",distVoteR, distVoteD, distVoteT,"\n")

        # DO SOMETHING WITH THE MAP !!
        # Right Now the code does nothing

    except Exception as e:
        if str(e) == "'NoneType' object has no attribute 'name'":
            print("No more maps in the atlas")
            break
        else:
            print("An unexpected error occurred: ", e)
        break


