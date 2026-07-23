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

#### `MapData{T,W<:Real}`
Like `Map` but without `districting`: just `name::String`, `weight::W`,
`data::T`. Produced by `parseMapData`/`nextMapData`/`parseBufferToMapData` for
callers that only need a map's data fields -- reconstructing `districting`
(one key-tuple per graph node) is by far the most expensive part of parsing a
full `Map`, and `MapData` skips it entirely.

#### `AtlasFormatError(msg) <: Exception`
Raised by `openAtlas` (and the `nextMap`/`nextMapData`/`parseBufferToMap`/
`parseBufferToMapData`/`parseMapData` parse paths) when input doesn't parse as
a valid Atlas file/line -- e.g. the file is some other JSON document (a
dual-graph file, say) rather than an Atlas, it's truncated, or a map line is
malformed. Carries a plain-text `msg` describing what went wrong.

#### `AtlasOutput`
Output sink for an atlas's serialized map bytes that hides how the target is
written. For a `.gz` path it emits byte-targeted gzip members compressed in
parallel; for any other path it writes through a `smartOpen` stream (plain, or
serial `.bz2`). Build with `openAtlasOutput`, feed batches of in-order
serialized maps with `writeMaps!`, and `close` it when done.

Fields: `io::IO`, `gzip::Bool`, `cores::Int`.

### Opening / Closing Streams

#### `smartOpen(fileName::String, io_mode::String; download::Bool=false)::Union{IO,Nothing}`
Opens an `IO` stream, transparently wrapping it in a compression pipe based on
the filename extension (`.gz` → gzip, `.bz2` → bzip2, otherwise uncompressed).
`io_mode` is `"r"`, `"w"`, or `"a"`. If the requested file does not exist it
falls back to the alternative extension (compressed ↔ uncompressed). Returns
`nothing` if it cannot determine what to do.

`fileName` may also be an `http://` or `https://` URL, in which case only
`io_mode="r"` is supported (writing raises `ArgumentError`). Compression is
sniffed from the URL's path, ignoring any query string/fragment.

- By default (`download=false`), the URL is **streamed**: a background task
  feeds a `Base.BufferStream` as bytes arrive over the network, so reading
  (and decompression) can start immediately without ever writing the whole
  file to disk or holding it fully in memory. Existence is checked with a
  cheap `HEAD` request first, so the compressed ↔ uncompressed
  alternate-extension fallback still works the same as for local files.
- With `download=true`, the whole resource is downloaded to a temporary file
  first (as in earlier versions), then opened for reading. The fallback is
  driven by catching a real 404 from the transfer itself.

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

#### `nextMapData(atlas::Atlas)::MapData`
Like `nextMap` but returns a `MapData` -- `districting` is not parsed. ~7x
faster and ~28x fewer allocations per map than `nextMap` in benchmarks on a
several-hundred-node graph. Composes with `skipMap`/`nextMap`/`nextMapData` the
same way `nextMap` does (reads from wherever `atlas` is currently positioned).

#### `parseMapData(buff::String, T, W=Int64)::MapData{T,W}`
Parses a single already-read line `buff` into a `MapData`, touching only
`name`, `weight`, and `data`. Uses JSON3's plain lazy-object read plus three
field lookups, rather than the `StructTypes.CustomStruct` machinery `Map`'s
parse goes through (which eagerly materializes the whole JSON object,
`districting` included, regardless of what the constructor actually uses).
Places the same constraint on `T` that `Map{T,W}` does -- none: a `Dict`-like
`T` gets the fast key-remapping conversion, anything else is built directly
from the raw value.

#### `parseBufferToMapData(atlas::Atlas, buff::String)::MapData`
Like `parseBufferToMap` but returns a `MapData` -- `districting` is not
parsed. Intended for the same batched/threaded use: read lines serially, parse
each with this in parallel.

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

### Parallel Gzip Output

Writes `.gz` atlases as a series of byte-targeted gzip members compressed in
parallel across threads, concatenating into one valid multi-member `.gz`
(RFC 1952) readable by `gunzip`/`zcat`/`openAtlas`. The output is not
byte-identical to a single-stream `.gz` (a different, equally valid encoding of
the same content). Intended for tools that already produce serialized map
bytes (e.g. AtlasUtilities' `add`/`relabel`): `openAtlasOutput`, repeated
`writeMaps!`, then `close`.

#### `openAtlasOutput(path::AbstractString, headerBytes::Vector{UInt8}, cores::Int=Threads.nthreads())::AtlasOutput`
Opens `path` for writing and emits the atlas `headerBytes` (its three header
lines, e.g. from `atlasHeaderBytes`). For `.gz` output the header is written as
its own gzip member and the file is opened raw so subsequent map members can
be appended; otherwise the header is written through a `smartOpen` stream
(plain or `.bz2`). `cores` is the parallel-compression worker count for the map
body. Start Julia with `-t auto` to benefit.

#### `writeMaps!(out::AtlasOutput, bytes::Vector{Vector{UInt8}})`
Appends the in-order serialized map byte-vectors `bytes` to `out`: as
byte-targeted parallel gzip members for a `.gz` target (via
`writeGzipMembers!`), or written straight through the stream otherwise.

#### `writeGzipMembers!(out::IO, bytes::Vector{Vector{UInt8}}, cores::Int=Threads.nthreads(); target::Int=GZIP_MEMBER_TARGET)`
Writes the in-order serialized records `bytes` to `out` as byte-targeted gzip
members: groups consecutive records into ~`target`-byte groups
(`groupByBytes`), gzips each group into one member in parallel across `cores`
tasks, then writes the members serially in record order. The concatenated
members form one valid `.gz`.

#### `groupByBytes(sizes::Vector{Int}, target::Int) -> Vector{UnitRange{Int}}`
Partitions `1:length(sizes)` into consecutive ranges whose summed `sizes` each
reach at least `target` bytes (the final range may be smaller). Each range
becomes one gzip member -- grouping by bytes (not map count) keeps every
member comfortably above deflate's 32 KB history window.

#### `gzipMember(bytes::Vector{UInt8})::Vector{UInt8}`
Compresses `bytes` into one standalone gzip member, concatenable into a
multi-member `.gz`.

#### `isGzipOutput(path::AbstractString)::Bool`
`true` if writing `path` should produce gzip output (drives the
parallel-member path); `.bz2` is excluded and falls back to the serial stream.

#### `atlasHeaderBytes(path::AbstractString)::Vector{UInt8}`
Reads an atlas's three header lines from `path` as raw bytes (with trailing
newlines), for re-emitting through an `AtlasOutput`.

#### `close(out::AtlasOutput)`
Closes the underlying `IO` stream of `out`. (`Base.close` method.)

#### `GZIP_MEMBER_TARGET`
Default target of uncompressed bytes per gzip member (256 KB -- 8x deflate's
32 KB window).

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

**Read from a URL (streamed, no full download):**
```julia
io = smartOpen("https://example.com/atlas.jsonl.gz", "r")
atlas = openAtlas(io)
...
close(atlas)
```

**Read from a URL (download to a temp file first):**
```julia
io = smartOpen("https://example.com/atlas.jsonl.gz", "r"; download=true)
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

**Write with `AtlasOutput` (parallel gzip members, for pre-serialized map bytes):**
```julia
headerBytes = atlasHeaderBytes("in.jsonl.gz")   # or build the 3 header lines yourself
out = openAtlasOutput("out.jsonl.gz", headerBytes)
mapBytes = [JSON3.write(m) |> codeunits |> collect for m in maps]  # Vector{Vector{UInt8}}, in order
writeMaps!(out, mapBytes)
close(out)
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
