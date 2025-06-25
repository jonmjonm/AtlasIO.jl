
import json
import sys,os
sys.path.append('../PythonReader/')
import MapAtlas
import helper_functions as hf

atlasDir="../AtlasExamples/"
#atlasFileName="test.jsonl"  #fake simple maps
atlasFileName="atlas_truncated_nc_multiscale.jsonl" #Small number of real maps
#atlasFileName="atlas_nc_multiscale.jsonl.gz" #full set of real maps

pctDataDir="../Shapefile_JSON/"
pctDataFileName="pct21_20votes_wMCD.json"

atlas = Atlas.openAtlas(os.path.join(atlasDir,atlasFileName))    
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
    




    
