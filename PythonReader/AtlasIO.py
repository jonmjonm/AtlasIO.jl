"""AtlasIO.py: the original single-file Python reader for Atlas files, kept for existing code.

New code should use the ``atlasio`` package (python/ in this repository), whose district keys are tuples.
This file keeps the original interface (openAtlas, nextMap, closeAtlas) and its RAW STRING district keys,
such as '["MECKLENBURG", "052"]', so code written for it keeps working, including on format v2 files:

* v1 files: the keys are exactly the strings in the file.
* v2 files: the file stores a tree, not key strings, so the keys are built in the form AtlasIO.jl writes in v1
  (", " between names; only " and \\ escaped), which is what helper_functions.get_node_to_district expects.

It must stay one file with no dependencies beyond the standard library: users load it with httpimport, e.g.
    with httpimport.remote_repo(['AtlasIO'], 'https://raw.githubusercontent.com/jonmjonm/AtlasIO.jl/refs/tags/v0.2.3/PythonReader/'):
        import AtlasIO
"""
import bz2
import gzip
import json
import os

FORMAT_VERSIONS = ("1", "2")


class AtlasFormatError(ValueError):
    """The file or line is not a valid Atlas (or uses a format version this reader does not read)."""


class Atlas:
    description = ""
    date = ""
    atlasParamType = ""
    mapParamType = ""
    weightType = "Int64"
    formatVersion = "1"
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
    ext = os.path.splitext(fileName)[1]
    if ext == '.gz':
        fp = gzip.open(fileName, "rt", encoding="utf-8", newline="\n")
    elif ext == '.bz2':
        fp = bz2.open(fileName, "rt", encoding="utf-8", newline="\n")
    else:
        fp = open(fileName, "r", encoding="utf-8", newline="\n")

    atlas = Atlas()
    atlas.fp = fp
    line = fp.readline()  # drop first line
    line = fp.readline()
    atlasHeader = json.loads(line)
    atlas.description = atlasHeader['description']
    atlas.date = atlasHeader["date"]
    atlas.atlasParamType = atlasHeader["atlasParamType"]
    atlas.mapParamType = atlasHeader["mapParamType"]
    # Old (pre-float_weights) files have no weightType; default to Int64.
    atlas.weightType = atlasHeader.get("weightType", "Int64")
    # Files without formatVersion are v1.
    atlas.formatVersion = atlasHeader.get("formatVersion", "1")
    if atlas.formatVersion not in FORMAT_VERSIONS:
        fp.close()
        raise AtlasFormatError('unsupported Atlas formatVersion "%s": this reader reads format versions %s. '
                               "Use a newer AtlasIO.py or the atlasio package."
                               % (atlas.formatVersion, " and ".join(FORMAT_VERSIONS)))
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
    has_v2 = "assignment" in exp
    if has_v2 == ("districting" in exp):
        raise AtlasFormatError('map line "%s" must have exactly one of "districting" (v1) and "assignment" (v2)'
                               % map.name)
    if has_v2 != (atlas.formatVersion == "2"):
        raise AtlasFormatError('map line "%s" does not match the header\'s formatVersion "%s"; a file holds maps '
                               "of one version only" % (map.name, atlas.formatVersion))
    if has_v2:
        map.districting = _rawKeysFromAssignment(exp["assignment"], map.name)
    else:
        map.districting = {}
        for d in exp["districting"]:
            for k, v in d.items():
                map.districting[k] = v
    map.data = exp["data"]

    return map


def districtKeyString(key):
    """The v1 key string for a tuple of names, as AtlasIO.jl writes it: '["MECKLENBURG", "052"]'."""
    return "[" + ", ".join('"' + p.replace("\\", "\\\\").replace('"', '\\"') + '"' for p in key) + "]"


def _rawKeysFromAssignment(tree, name):
    """Flatten a v2 assignment tree into {v1 key string: district}, checking the spec's reader rules."""
    if not isinstance(tree, dict):
        raise AtlasFormatError('map "%s": "assignment" must be a JSON object' % name)
    out = {}
    stack = [((), tree)]
    while stack:
        prefix, node = stack.pop()
        for part, v in node.items():
            key = prefix + (part,)
            if type(v) is int:
                out[districtKeyString(key)] = v
            elif isinstance(v, dict) and v:
                stack.append((key, v))
            else:
                raise AtlasFormatError('map "%s": the value at key %r in "assignment" must be an integer district '
                                       "or a non-empty object of sub-regions, not %r" % (name, key, v))
    return out
