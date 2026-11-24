# AtlasIO Public Function Calls

This document describes the public function calls exposed by the AtlasIO library.
Atlas files are JSONL with a fixed 3-line header (comment, `AtlasHeader`, atlas
parameters) followed by one `Map` per line. Files may be uncompressed
(`.jsonl`), gzip-compressed (`.jsonl.gz`), or bzip2-compressed (`.jsonl.bz2`).

The **Julia** library is the full read/write implementation. It reads format
versions 1 and 2 (see [atlas_format.md](atlas_format.md)) and writes either
(v1 by default; `formatVersion=2` on the write functions), and `convertAtlas`
converts files between them. The **Python** side has the `atlasio` package
(`python/`), which reads and writes both versions and converts files between them, and the
original read-only `PythonReader/AtlasIO.py`, plus election-analysis helpers.

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
`mapParamType::DataType`, `weightType::DataType`, `formatVersion::String` (`"1"`
or `"2"`, from the header; added in 0.2.1, and an `Atlas` constructed without it
is v1).

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
Map{T,W}(x::Dict{String,Any})                 # build from a parsed JSON dict (v1 or v2)
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

#### `openAtlas(f::Function, path::AbstractString)`
Opens the atlas at `path`, calls `f(atlas)`, and closes it afterwards, even if `f` throws or a loop in it
stops early (a `break` or `return`). Returns what `f` returns: `openAtlas("atlas.jsonl.gz") do atlas ... end`.

### Reading

#### `eachMap(path; skip=0, max=typemax(Int), batch)` / `eachMap(atlas::Atlas; ...)`
An iterator over the maps, in file order: `for m in eachMap("atlas.jsonl.gz") ... end`. It gives the same
`Map{T,W}`s as a `while !eof(atlas); nextMap(atlas); end` loop, holding one batch in memory at a time.

- With several threads (`julia -t auto`), each batch of `batch` lines (default 256) is read and then parsed in
  parallel; with one thread the default `batch` is 1.
- `skip` maps are skipped without parsing (e.g. a burn-in); at most `max` maps are given.
- An error (malformed line, corrupt file) is raised when the iteration reaches that map, after the maps before it.
- From a `path`, the file is closed when the last map has been read, or on an error; after a `break` it stays
  open until garbage collection, so use `openAtlas(f, path)` with `eachMap(atlas)` to close it at once. From an
  `atlas`, it reads from the current position and never closes it; don't mix it with `nextMap` on the same
  atlas, since it reads a batch ahead.

**Performance.** Measured with [benchmark/bench_eachmap.jl](benchmark/bench_eachmap.jl) on whole files
(decompression included), in µs per map, with the speedup over the `nextMap` loop:

| Atlas | Threads | `nextMap` loop | `eachMap` | `eachMapData` | Reading lines only |
|---|---|---|---|---|---|
| NC multiscale, 79,997 maps, 28 KB per line | 8 | 942 | 356 (2.6×) | 133 (7.1×) | 129 |
| CycleWalk NC precincts, 10,001 maps, 66 KB per line | 8 | 2459 | 1083 (2.3×) | 404 (6.1×) | 394 |
| NC multiscale | 1 | 894 | 946 (0.95×) | 152 (5.9×) | 125 |
| CycleWalk NC precincts | 1 | 2203 | 2205 (1.0×) | 381 (5.8×) | 380 |

- The cost per map grows with the size of the map line; the speedups barely change between a 2,000-map and an
  80,000-map file.
- Parsing the district assignment is most of the cost. `eachMap` parses it in parallel, and the limit is then
  parsing and garbage collection (30–36% of its time); batch sizes from 16 to 1024 were within about 20% of
  each other.
- `eachMapData` skips the district assignment and runs as fast as the compressed stream can be read, which is
  serial, so more threads don't help it.
- On one thread `eachMap` takes about the same time as the loop.

#### `eachMapData(path; skip=0, max=typemax(Int), batch)` / `eachMapData(atlas::Atlas; ...)`
`eachMap` for `MapData` (each map's `name`, `weight` and `data`, without the district assignment): about 6
to 7 times faster.

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

#### `parseMap(line::AbstractString, T, W=Int64)::Map{T,W}`
Parses one map line (with or without its trailing newline) into a `Map{T,W}`,
without needing an `Atlas` or any JSON library. Raises `AtlasFormatError` on
malformed input. *(New in 0.2.)* Use it instead of `JSON3.read(line, Map{T,W})`,
which no longer works since AtlasIO 0.2.

#### `nextMapData(atlas::Atlas)::MapData`
Like `nextMap` but returns a `MapData` -- `districting` is not parsed, nor even
scanned. Composes with `skipMap`/`nextMap`/`nextMapData` the same way `nextMap`
does (reads from wherever `atlas` is currently positioned).

#### `parseMapData(buff::AbstractString, T, W=Int64)::MapData{T,W}`
Parses a single already-read line `buff` into a `MapData`, touching only
`name`, `weight`, and `data`. It uses JSON.jl's lazy parser, and `districting`
is the last field of a map line, so it is never scanned. `data` is converted
exactly as `parseMap` converts it, so a `MapData` and a `Map` read from the
same line hold equal data. `T` need not be a `Dict`, and `data` need not be a
JSON object.

#### Values read from JSON
Every reader (`openAtlas` for the atlas parameters, `nextMap`/`parseMap`,
`nextMapData`/`parseMapData`) returns JSON values as plain Julia values:
objects as `Dict{String,Any}` and arrays as `Vector{Any}` at every level,
strings as `String`, `null` as `nothing`. Numbers are exact: `0.0` and `1.0`
read as `Float64`, integers as `Int64` (or `BigInt` beyond the `Int64` range),
and `-0.0` keeps its sign. *(Changed in 0.2: AtlasIO 0.1.x read whole-number
floats as `Int` and lost precision on integers beyond 2^53 in `Map` data and
atlas parameters.)*

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

Every write function takes a keyword `formatVersion`: `1` (the default) or `2`
(`"1"`/`"2"` also work). v1 output is exactly what earlier versions wrote. Use
the **same** `formatVersion` for `newAtlas` and for every map of that atlas: a
file whose maps differ from its header's version is rejected by every reader.
*(New in 0.2.2.)*

```julia
newAtlas(io, atlasHeader, atlasParams; formatVersion=2)
addMap(io, map; formatVersion=2)
```

The v2 writer writes the tree with names sorted at every level (so the same
map always gives the same bytes), and raises `AtlasFormatError` for a
districting v2 cannot hold: a key that is a prefix of another (a region both
whole and split) or the empty key `()`. Such a map can still be written as v1.

#### `newAtlas(io::IO, atlasHeader::AtlasHeader, atlasParam; formatVersion=1)`
Writes the 3-line header (comment line, `atlasHeader`, `atlasParam`) to `io`.
For v2 the header gains `"formatVersion":"2"`.

#### `addMap(io::IO, map::Map{T}; formatVersion=1)`
Serializes and writes a single `Map` as one JSON line.

#### `addMap(io::IO, dist::Districting, name::String, w::Real, mapParams; formatVersion=1)`
Convenience overload: builds a `Map` from the districting, name, weight, and map
parameters, then writes it.

#### `addMaps(io::IO, maps; formatVersion=1) -> Int`
Writes a collection of `Map`s. JSON serialization is done in parallel across
threads, then the strings are written to `io` serially in order. Output is
byte-identical to calling `addMap` per map. Returns total bytes written. Start
Julia with `-t auto` to benefit.

#### `mapJSON(m::Map; formatVersion=1)::String`
The JSON text of `m` exactly as it appears on one line of an Atlas file,
**without** the trailing newline. *(New in 0.2.)*

#### `mapBytes(m::Map; formatVersion=1)::Vector{UInt8}`
One complete Atlas map line for `m`, **including** the trailing newline:
exactly the bytes `addMap` writes. Use it to build the input of `writeMaps!`,
e.g. `writeMaps!(out, mapBytes.(maps))`. *(New in 0.2.)* Use `mapJSON`/`mapBytes`
instead of `JSON3.write(m)`, which no longer works since AtlasIO 0.2.

#### How values are written
Output is byte-identical to AtlasIO 0.1.x: `Dict` keys keep their iteration
order, and value types whose JSON form differs between JSON3 and JSON.jl keep
the 0.1.x form (`Rational` as a float, `BigFloat` with all its digits,
`DateTime`/`Time` always with a fractional second, arrays of 2+ dimensions
flattened in column-major order). `NaN` and `Inf` cannot be written.

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
`writeGzipMembers!`), or written straight through the stream otherwise. The
bytes are written as given, with nothing added: each element must be a complete
line **including its trailing newline**, as `mapBytes` returns.

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

#### `convertAtlas(src, dst; formatVersion, batch=1024, cores=Threads.nthreads()) -> Int`
Copies the atlas file `src` to `dst`, converting every map to format version
`formatVersion` (`1` or `2`), and returns the number of maps. Either file may
be plain, `.gz` or `.bz2`. Only the header's `formatVersion` and each map's
assignment field are rewritten; the banner, the atlas parameters and each map's
name, weight and data are copied **byte for byte**. v2 trees are sorted; v1
entries are written in sorted key order; every line ends with a newline.
Converting back gives the same districting for every map. Map lines are
converted in parallel; a `.gz` `dst` is written as parallel gzip members. An
`AtlasFormatError` names the line and map of anything that cannot be converted
(a line not in the header's version, a districting v2 cannot hold, an
assignment that is not the line's last field), and `dst` is removed.
The Python package's `atlasio.convert` produces the same bytes. *(New in 0.2.2.)*

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
writeMaps!(out, mapBytes.(maps))   # one complete line per map, newline included, in order
close(out)
```

---

## Python: the `atlasio` package (`python/`)

Reads and writes format v1 and v2, plain, `.gz` or `.bz2`, and converts files between them. Standard library only (uses
`orjson` if it is installed). Install with `pip install atlasio` (PyPI, from 0.2.4), or from a release tag:
`pip install "atlasio @ git+https://github.com/jonmjonm/AtlasIO.jl@v0.2.4#subdirectory=python"`.

```python
import atlasio
with atlasio.open_atlas("atlas.jsonl.gz") as atlas:
    atlas.description, atlas.date, atlas.format_version, atlas.params
    for m in atlas:
        m.name, m.weight, m.data
        m.districting[("MECKLENBURG", "052")]
```

- `open_atlas(source)` — `source` is a path (compression chosen by extension) or an open file object (text or
  binary; left open on `close`). Returns an `Atlas`.
- `Atlas` — attributes `description`, `date`, `atlas_param_type`, `map_param_type`, `weight_type`,
  `format_version` (`"1"` or `"2"`), `header` (dict), `params` (line 3). Iterate over it, or call `next_map()`
  (returns `None` at the end); `close()`; usable in a `with` block.
- `Map` — `name`, `weight`, `data`, `districting` (dict from key tuples to districts). `raw_districting()`
  returns the districting with v1-style string keys, as AtlasIO.jl writes them.
- `parse_map(line)` — parse one map line of either version.
- `parse_district_key(s)` / `district_key_string(key)` — convert between a v1 key string and a key tuple.
- `convert(src, dst, to)` — copy an atlas file converting every map to format version `to` (1 or 2); the same
  rules and the same output bytes as Julia's `convertAtlas`. Returns the number of maps. *(New in 0.2.2.)*
  Command line: `python -m atlasio convert SRC DST --to 2` (or `atlasio convert ...` once installed).
- `new_atlas(dest, description="", params={}, *, date=None, atlas_param_type=None, map_param_type=None,
  weight_type=None, format_version=None, like=None)` — create an atlas file (path, compression chosen by
  extension, or an open text or binary file object, left open on `close`) and write its header. Defaults: the
  current date, `"Dict{String, Any}"` for both parameter types, weight type `"Int64"`, format version 1.
  `like=atlas` copies an open `Atlas`'s header, parameters and format version; explicit arguments override it.
  Returns an `AtlasWriter`. *(New in 0.2.3.)*
- `AtlasWriter` — `add_map(name, districting, weight=1, data=None)` or `add_map(m)` for a `Map`;
  `add_maps(maps)`; `close()`; usable in a `with` block. Attributes `format_version`, `weight_type`, `header`,
  `params`, `count` (maps written). The layout is AtlasIO.jl's: name, weight, data, then the assignment; v2 trees
  sorted at every level, v1 entries in sorted key order. Bad input raises `TypeError`/`ValueError` before
  anything is written (numpy numbers and arrays are converted; NaN and infinity are refused); in v2, a
  districting v2 cannot hold raises `AtlasFormatError`. *(New in 0.2.3.)*
- `map_json(m, format_version=1, weight_type=None)` — one map's line, without the newline, as `add_map` writes
  it. *(New in 0.2.3.)*
- `AtlasFormatError` (a `ValueError`) — raised for invalid files and lines, for a `formatVersion` it does not
  know, and for a map line whose version differs from the header's.

## Python Reader Library (`PythonReader/`)

Read-only. Import by adding `../PythonReader/` to `sys.path`, or with httpimport pinned to a release tag
(`.../AtlasIO.jl/refs/tags/v0.2.4/PythonReader/`). It is one self-contained file, kept so existing code keeps
working; new code can use the `atlasio` package above.

### `AtlasIO.py`

#### Classes

##### `Atlas`
Holds an open file pointer plus header info: `description`, `date`,
`atlasParamType`, `mapParamType`, `weightType` (defaults to `"Int64"`),
`formatVersion` (defaults to `"1"`), `atlasParam`, and `fp`. Provides `__repr__` / `__str__`.

##### `Map`
A single map: `name`, `weight`, `data`, `districting`. Provides `__repr__` /
`__str__`.

#### Functions

##### `openAtlas(fileName)`
Opens an atlas file (`.gz` and `.bz2` by extension), reads the 3-line
header, and returns an `Atlas`. Missing `weightType` defaults to `"Int64"`. A
`formatVersion` other than `"1"` or `"2"` raises `AtlasFormatError`.

##### `nextMap(atlas)`
Reads and parses the next map line, returning a `Map` (or `None` at EOF). The
`districting` dict has raw string keys such as `'["MECKLENBURG", "052"]'`: in a
v1 file, the key strings exactly as written; in a v2 file, built in the form
AtlasIO.jl writes (`", "` between names, only `"` and `\` escaped).

##### `closeAtlas(atlas)`
Closes the atlas's underlying file pointer.

### `helper_functions.py`

Election-analysis utilities operating on the parsed map/election data.

#### Districting / vote summation

##### `get_node_to_district(districting, nodes)`
Reconstructs the precinct-ID → district mapping from a multiscale districting
description and a list of `nodes`. Accepts either kind of district key: strings
(`AtlasIO.py`) or tuples (`atlasio`).

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
