# atlasio (Python)

Read [Atlas files](https://github.com/jonmjonm/AtlasIO.jl/blob/main/atlas_format.md), the format the Duke
Quantifying Gerrymandering group's samplers (Cycle Walk, Metropolized Forest Recom) use to store ensembles of
redistricting maps. Reads and writes format versions 1 and 2, plain or compressed (`.jsonl`, `.jsonl.gz`, `.jsonl.bz2`),
and converts files between the two versions, compatible with [AtlasIO.jl](https://github.com/jonmjonm/AtlasIO.jl)
(Julia).

## Install

    pip install atlasio

or, from a release tag of the AtlasIO.jl repository (needs git):

    pip install "atlasio @ git+https://github.com/jonmjonm/AtlasIO.jl@v0.2.5#subdirectory=python"

The package's version always equals AtlasIO.jl's: both are released together from one tag.

It needs only the Python standard library (Python 3.9 or later; tested on 3.11 to 3.14). With `pip install orjson` (or the `fast` extra) it
parses lines faster.

## Use

```python
import atlasio

with atlasio.open_atlas("atlas.jsonl.gz") as atlas:
    print(atlas.description, atlas.date, atlas.format_version)
    print(atlas.params)                       # the atlas parameters (line 3)
    for m in atlas:
        m.name, m.weight, m.data
        m.districting                         # {("WAKE",): 3, ("MECKLENBURG", "052"): 13, ...}
```

District keys are tuples of names from the coarsest level down, as in AtlasIO.jl, whichever format version the
file uses. `m.raw_districting()` gives the same districting with v1-style string keys
(`'["MECKLENBURG", "052"]'`), for code written for the original `PythonReader/AtlasIO.py`.

Invalid files, a `formatVersion` this version does not know, and maps that break the format's rules raise
`atlasio.AtlasFormatError` (a `ValueError`).

The full API is in [function_calls.md](https://github.com/jonmjonm/AtlasIO.jl/blob/main/function_calls.md).

## Write

```python
with atlasio.new_atlas("out.jsonl.gz", description="my ensemble", params={"districts": 14}) as out:
    out.add_map("map1", {("WAKE",): 3, ("MECKLENBURG", "052"): 13}, weight=1, data={"score": 0.5})
    out.add_map(m)                            # or a Map, e.g. one read from another atlas
```

`new_atlas(dest, description="", params={}, *, date=now, atlas_param_type, map_param_type, weight_type="Int64",
format_version=1, like=None)`. The compression is chosen by the extension; `dest` can also be an open file
object. `format_version=2` writes v2 (v1 is the default, as in AtlasIO.jl). `like=atlas` copies an open atlas's
header and parameters, for writing a modified copy; explicit arguments override it.

District keys are tuples of names and districts integers. Map data can be anything JSON can hold; numpy numbers
and arrays are converted. NaN and infinity are refused, since JSON has neither. A map that cannot be written
raises before any of it is written, so the file keeps every map written so far. In v2, a region both whole and
split (one key a prefix of another) raises `atlasio.AtlasFormatError`.

The output is laid out exactly as AtlasIO.jl writes it: the same banner, header and field order, and
byte-identical v2 assignments; only floats may be spelled differently (`1e-07` for Julia's `1.0e-7`).

## Convert between format versions

```
python -m atlasio convert atlas.jsonl.gz atlas_v2.jsonl.gz --to 2     # or: atlasio convert ...
```

or `atlasio.convert("atlas.jsonl.gz", "atlas_v2.jsonl.gz", to=2)`. Only the header's `formatVersion` and each
map's assignment are rewritten; everything else is copied byte for byte, and converting back gives the same
districting for every map. A districting v2 cannot hold (a region both whole and split) stops the conversion
with an error naming the line and map. The output is byte-identical to AtlasIO.jl's `convertAtlas`.

## Tests

From the repository root: `pip install ./python pytest && python -m pytest python/tests`.
