# AtlasIO Public Function Calls

This document describes the public function calls exposed by the AtlasIO library.
Atlas files are JSONL with a fixed 3-line header (comment, `AtlasHeader`, atlas
parameters) followed by one `Map` per line. Files may be uncompressed
(`.jsonl`), gzip-compressed (`.jsonl.gz`), or bzip2-compressed (`.jsonl.bz2`).

The **Julia** library is the full read/write implementation. The **Python
Reader** is read-only and mirrors a subset of the API, plus election-analysis
helpers.

---

## Julia Library (`src/AtlasIO.jl`)

All names below are `export`ed from `module AtlasIO`.

### Types

#### `AtlasHeader`
Metadata struct describing an atlas file.

Fields: `description::String`, `date::String`, `atlasParamType::String`,
`mapParamType::String`, `weightType::String` (currently unused at the type
level; defaults to `"Int64"`).

Constructors:
```julia
AtlasHeader(name, date, atlasParamType, mapParamType; weightType=Int64)   # DataType args
AtlasHeader(name, atlasParamType, mapParamType; weightType=Int64)         # date defaults to now()
AtlasHeader(name, date, atlasParamType::String, mapParamType::String; weightType="Int64")  # back-compat
```
The `DataType` constructors stringify the supplied types. The `String`
constructor exists for backward compatibility with pre-`weightType` headers and
defaults `weightType` to `"Int64"`.

#### `Atlas{T}`
Wraps an open `IO` stream plus the header info. `T` is the map parameter type
(defaults to `Dict{String,Any}` on read).

Fields: `io::IO`, `description::String`, `date::String`, `atlasParam::T`,
`mapParamType::DataType`, `weightType::DataType`.

#### `Districting`
```julia
Districting = Dict{Tuple{Vararg{String}}, Int64}
```
Maps hierarchical region keys (e.g. `("county", "precinct")`) to integer
district numbers. The tuple-key design supports multi-scale redistricting.

#### `Map{T,W<:Real}`
A single map assignment.

Fields: `name::String`, `districting::Districting`, `weight::W`, `data::T`.

Constructors:
```julia
Map{T}(; name, districting, weight, data)     # W inferred from weight
Map{T}(name, districting, weight, data)       # positional
Map{T,W}(x::Dict{String,Any})                 # build from a parsed JSON dict
```

### Opening / Closing Streams

#### `smartOpen(fileName::String, io_mode::String)::Union{IO,Nothing}`
Opens an `IO` stream, transparently wrapping it in a compression pipe based on
the filename extension (`.gz` → gzip, `.bz2` → bzip2, otherwise uncompressed).
`io_mode` is `"r"`, `"w"`, or `"a"`. If the requested file does not exist it
falls back to the alternative extension (compressed ↔ uncompressed). Returns
`nothing` if it cannot determine what to do.

`fileName` may also be an `http://` or `https://` URL, in which case the
resource is downloaded to a temporary file and opened for reading; compression
is sniffed from the URL's path (ignoring any query string/fragment), and the
same alternate-extension fallback applies on a 404. Only `io_mode="r"` is
supported for URLs -- writing raises `ArgumentError`.

#### `close(atlas::Atlas)`
Closes the underlying `IO` stream of the atlas. (`Base.close` method.)

### Reading

#### `openAtlas(io::IO)::Atlas`
Reads the 3-line header from `io` and returns an `Atlas`. The comment line is
discarded; the header and atlas parameters are parsed. Missing `weightType` in
older files defaults to `Int64`.

#### `nextMap(atlas::Atlas)::Map`
Reads and parses the next map line from the atlas stream.

#### `nextMap(atlas::Atlas, ioIterator::Base.EachLine)::Map`
Reads the next map from an `EachLine` iterator over the stream.

#### `parseBufferToMap(atlas::Atlas, buff::String)::Map`
Parses a single already-read line `buff` into a `Map`, using the atlas's map
parameter and weight types. Useful for custom/parallel read loops.

#### `nextMaps(atlas::Atlas; n=typemax(Int), batch=256) -> Vector{Map}`
Reads up to `n` maps, parsing them across all available threads. Lines are read
serially in chunks of `batch` (with the next chunk prefetched on a separate
task) and parsed in parallel. Returned maps are in on-disk order, identical to a
serial `nextMap` loop, and reading continues from the current stream position
(composes with `skipMap`/`nextMap`). Start Julia with `-t auto` to benefit.

#### `skipMap(atlas::Atlas; numSkip=1)`
Skips `numSkip` map lines without parsing them.

#### `eof(atlas::Atlas)::Bool`
Returns `true` if the atlas stream is at end-of-file. (`Base.eof` method.)

### Writing

#### `newAtlas(io::IO, atlasHeader::AtlasHeader, atlasParam)`
Writes the 3-line header (comment line, `atlasHeader`, `atlasParam`) to `io`.

#### `addMap(io::IO, map::Map{T})`
Serializes and writes a single `Map` as one JSON line.

#### `addMap(io::IO, dist::Districting, name::String, w::Real, mapParams)`
Convenience overload: builds a `Map` from the districting, name, weight, and map
parameters, then writes it.

#### `addMaps(io::IO, maps) -> Int`
Writes a collection of `Map`s. JSON serialization is done in parallel across
threads, then the strings are written to `io` serially in order. Output is
byte-identical to calling `addMap` per map. Returns total bytes written. Start
Julia with `-t auto` to benefit.

### Utilities

#### `copyAtlasHeader(sourceFilename::String, outFilename::String)`
Copies the 3-line header from one atlas file to another (handling compression on
both ends via `smartOpen`).

### Typical Usage

**Read:**
```julia
io = smartOpen("atlas.jsonl.gz", "r")
atlas = openAtlas(io)
while !eof(atlas)
    m = nextMap(atlas)
end
close(atlas)
```

**Read from a URL:**
```julia
io = smartOpen("https://example.com/atlas.jsonl.gz", "r")
atlas = openAtlas(io)
...
close(atlas)
```

**Write:**
```julia
io = smartOpen("out.jsonl.gz", "w")
newAtlas(io, atlasHeader, atlasParams)
addMap(io, map)
close(io)
```

---

## Python Reader Library (`PythonReader/`)

Read-only. Import by adding `../PythonReader/` to `sys.path`.

### `AtlasIO.py`

#### Classes

##### `Atlas`
Holds an open file pointer plus header info: `description`, `date`,
`atlasParamType`, `mapParamType`, `weightType` (defaults to `"Int64"`),
`atlasParam`, and `fp`. Provides `__repr__` / `__str__`.

##### `Map`
A single map: `name`, `weight`, `data`, `districting`. Provides `__repr__` /
`__str__`.

#### Functions

##### `openAtlas(fileName)`
Opens an atlas file (gzip-aware via the `.gz` extension), reads the 3-line
header, and returns an `Atlas`. Missing `weightType` defaults to `"Int64"`.

##### `nextMap(atlas)`
Reads and parses the next map line, returning a `Map` (or `None` at EOF). The
districting list-of-dicts is flattened into a single `districting` dict.

##### `closeAtlas(atlas)`
Closes the atlas's underlying file pointer.

### `helper_functions.py`

Election-analysis utilities operating on the parsed map/election data.

#### Districting / vote summation

##### `get_node_to_district(districting, nodes)`
Reconstructs the precinct-ID → district mapping from a multiscale districting
description and a list of `nodes`.

##### `sumElection(electionName, node_to_dist, data)`
Sums one election's votes per district. Returns `(distVoteR, distVoteD,
distVoteT)` dicts keyed by district.

##### `stateWideVotes(electionName, dataElection)`
Returns a dict with statewide `"Total"`, `"Rep"`, and `"Dem"` vote totals for an
election.

##### `addUniformSwings(targetDemFractions, electionNames, dataElection)`
Adds uniform-swing vote columns (`_USF<frac>_D/_R/_T`) to each precinct, swinging
each named election so the statewide Democratic vote fraction equals each target.

##### `listElections(dataElection, prefix="G", exluded={...}, idx=0)`
Returns the list of election names present in the data (derived from the `_D`
suffixed keys, excluding metadata fields).

##### `addTotalVotes(dataElection)`
Adds the `_T` (total) vote entry for each election where it is missing
(`_T = _D + _R`); does nothing if it already exists.

##### `demWinByPrecicts(elections, node_to_dist, dataElection)`
Returns a NumPy array counting, per precinct, the number of given elections in
which the Democrats won.

#### Histogram statistics

- `histMode(hist)` — key with the maximum value.
- `histNormalize(hist)` — normalized copy summing to 1.
- `histMean(hist)` — mean.
- `histStd(hist, scale=1.0)` — standard deviation (optionally scaled).
- `histMedean(hist)` — (median) interpolated middle of the distribution.
- `histSpread(hist, scale=1.0)` — `(max key − min key)` (optionally scaled).
