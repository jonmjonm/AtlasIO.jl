
import json
import sys,os
sys.path.append('../PythonReader/')
import AtlasIO
import helper_functions as hf

atlasDir="../AtlasExamples/"
#atlasFileName="test.jsonl"  #fake simple maps
atlasFileName="atlas_truncated_nc_multiscale.jsonl" #Small number of real maps
#atlasFileName="atlas_nc_multiscale.jsonl.gz" #full set of real maps

pctDataDir="../Shapefile_JSON/"
pctDataFileName="pct21_20votes_wMCD.json"

<<<<<<< HEAD
atlas = Atlas.openAtlas(os.path.join(atlasDir,atlasFileName))    
=======
atlas = AtlasIO.openAtlas(os.path.join(atlasDir,atlasFileName)) ##updated to AtlasIO   
>>>>>>> ba9308f67cd3a96f18e6e4e91d1da07e5e719e2e
pctDataFile = open(os.path.join(pctDataDir,pctDataFileName))
pctData = json.load(pctDataFile)

print(atlas)
map=[]
print("\n")
while map!=None:
    map=Atlas.nextMap(atlas)
    if map==None:
        break
    print(map)
    print("\n")
    




    
