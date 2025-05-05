import json
import gzip
import os


class Atlas:
    description = ""
    date = ""
    atlasParamType = ""
    mapParamType = ""
    atlasParam = dict()
    fp = None

    def __repr__(self):
        return "Atlas()"
    
    def __str__(self):
        return "atlas\ndescription: " + self.description + "\ndate: " + \
               self.date + "\natlasParam: " + str(self.atlasParam)


class Map:
    name = ""
    weight = 1
    data = dict()
    districting = dict()
    
    def __repr__(self):
        return "Map()"
    
    def __str__(self):
        return "map\nname: " + self.name + "\nweight: " + str(self.weight) + \
               "\ndistricting: " + str(self.districting)


def openAtlas(fileName):
    s_name = os.path.splitext(fileName)
    if s_name[1] == '.gz':
        fp = gzip.open(fileName, "r")
    else:
        fp = open(fileName, "r")
    
    atlas = Atlas()
    atlas.fp = fp
    line = fp.readline()  # drop first line
    line = fp.readline() 
    atlasHeader = json.loads(line)
    atlas.description = atlasHeader['description']
    atlas.date = atlasHeader["date"]
    atlas.atlasParamType = atlasHeader["atlasParamType"]
    atlas.mapParamType = atlasHeader["mapParamType"]
    line = fp.readline() 
    atlas.atlasParam = json.loads(line)

    return atlas


def closeAtlas(atlas):
    atlas.fp.close()


def nextMap(atlas):
    line = atlas.fp.readline()
    if not line:
        return None
    exp = json.loads(line)

    map = Map()
    map.name = exp["name"]
    map.weight = exp["weight"]
    map.districting = {}
    for d in exp["districting"]:
        for k, v in d.items():
            map.districting[k] = v
    map.data = exp["data"]
    
    return map






    
