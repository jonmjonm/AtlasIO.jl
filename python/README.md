# atlasio (Python)

Read [Atlas files](https://github.com/jonmjonm/AtlasIO.jl/blob/main/atlas_format.md), the format the Duke
Quantifying Gerrymandering group's samplers (Cycle Walk, Metropolized Forest Recom) use to store ensembles of
redistricting maps. Reads format versions 1 and 2, plain or compressed (`.jsonl`, `.jsonl.gz`, `.jsonl.bz2`).
Read-only: [AtlasIO.jl](https://github.com/jonmjonm/AtlasIO.jl) (Julia) writes Atlas files.

## Install

From a release tag of the AtlasIO.jl repository (needs git):

    pip install "atlasio @ git+https://github.com/jonmjonm/AtlasIO.jl@v0.2.1#subdirectory=python"

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

## Tests

From the repository root: `pip install ./python pytest && python -m pytest python/tests`.
