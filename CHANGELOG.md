# Changelog

## [0.2.0]

AtlasIO now uses **JSON.jl** (1.6 or later) instead of JSON3 and StructTypes; JSON3 is deprecated in the
General registry. **The file format is unchanged**: files written by 0.2.0 are byte-identical to what 0.1.x
wrote, every 0.1.x file reads to the same values, and AtlasIO 0.1.5 reads files written by 0.2.0 (checked in
CI by the `compat-0-1-5` job).

### Breaking

- `JSON3.read(line, Map{T,W})` and `JSON3.write(m)` no longer work on AtlasIO types (AtlasIO no longer
  defines `StructTypes` methods). Use the new functions instead, which need no JSON library:
  - `parseMap(line, T, W=Int64)` parses one map line into a `Map{T,W}`;
  - `mapJSON(m)` returns a map's JSON text, without the newline;
  - `mapBytes(m)` returns a complete map line, newline included, ready for `writeMaps!`.
- Numbers read from `Map` data and atlas parameters now keep their exact JSON type:
  - `0.0` and `1.0` read as `Float64` (0.1.x read them as `Int`);
  - `-0.0` keeps its sign (0.1.x read `0`);
  - integers beyond 2^53 read exactly (0.1.x silently changed their value, e.g. `-7375463094308724563`
    became `-7375463094308724736`), and beyond the `Int64` range they read as `BigInt`.

  Values still compare equal (`0 == 0.0`), but code that checks for `Int` may behave differently.
- `parseMapData`/`nextMapData` return `data` as plain `Dict{String,Any}`/`Vector{Any}` at every level
  (0.1.x returned JSON3 lazy objects for nested values), matching `nextMap`.
- Writing `NaN`/`Inf` still fails, with a different exception type.

### Fixed

- District keys containing JSON escapes other than `\"` and `\\` (e.g. `Ñ`, as Python's `json.dumps`
  writes non-ASCII characters by default) are decoded correctly; 0.1.x dropped the backslash.
- The documented `writeMaps!` example produced a corrupt atlas (no newlines between maps); it now uses
  `mapBytes`.

### Added

- `parseMap`, `mapJSON`, `mapBytes` (see above).
- `nextMapData`/`parseMapData` no longer scan `districting` at all (JSON.jl's lazy parser stops before it).
- Frozen v1-format fixtures and tests (`test/fixtures/`, `test/v1_fixtures.jl`), value-type tests
  (`test/types_and_api.jl`), and the `compat-0-1-5` CI job (`test/compat/`).

## [0.1.6]

- Add `MapData`/`parseMapData`/`nextMapData`/`parseBufferToMapData`: a lighter
  read path for callers that only need a map's `name`/`weight`/`data`, not
  `districting`. Parsing a full `Map` reconstructs `districting` unconditionally
  (one key-tuple per graph node), which dominates the cost of the parse even
  when the caller never looks at it; the new functions skip that work entirely
  by reading a plain lazy JSON3 object instead of going through `Map`'s
  `StructTypes.CustomStruct` path (which eagerly materializes the whole JSON
  object regardless of what its constructor actually uses). ~7x faster and
  ~28x fewer allocations per map in benchmarks on a several-hundred-node graph.
  Places the same constraint on `T`/`data` that `Map{T,W}` does -- none: a
  `Dict`-like `T` gets the fast key-remapping conversion, anything else is
  built directly from the raw value, matching a non-object `data`/non-`Dict`
  `mapParamType` the way a full `Map` parse already handles it.
- Fix `smartOpen` over `http(s)://` crashing with `type RequestError has no
  field status` instead of surfacing a real connection error, when a `HEAD`
  existence-check fails below the HTTP level (e.g. connection refused/aborted
  before any status was received). `Downloads.request(...; throw=false)`
  returns (rather than throws) a `RequestError` in that case; `_isMissingResponse`
  now checks `resp isa Downloads.Response` before reading `.status`, instead of
  assuming any non-`nothing` result has one.

## [0.1.5]

- `smartOpen` can now read directly from `http://`/`https://` URLs, not just
  local file paths. Compression is sniffed from the URL's path (`.gz`,
  `.bz2`, or none), and the same alternate-extension fallback used for local
  files (compressed ↔ uncompressed) applies when a URL 404s. Only reading
  (`io_mode="r"`) is supported for URLs; writing raises `ArgumentError`.
  - By default the URL is **streamed**: a background task feeds a
    `Base.BufferStream` as bytes arrive, so reading/decompression can start
    immediately without writing the whole file to disk. A cheap `HEAD`
    request checks existence first, which drives the alternate-extension
    fallback.
  - Pass `download=true` to instead download the whole resource to a
    temporary file first (the original behavior), with the fallback driven
    by catching a real 404 from the transfer.

## [0.1.4]

- Improve IO error handling throughout the read path:
  - `smartOpen` now only retries with an alternate compression extension
    (`.gz` ↔ uncompressed) when the original `open` fails because the file
    genuinely doesn't exist (`ENOENT`). Other failures -- permission denied,
    a missing directory, disk full, etc. -- now propagate immediately instead
    of being masked by a second, unrelated open attempt. The write-mode
    fallback also now picks the alternate extension based on the file's
    actual extension (matching read-mode behavior) rather than always
    assuming a compressed target.
  - `getFileExtension` no longer crashes on a filename with no `.`.
  - `openAtlas` wraps its three header-line reads so a truncated or
    CRC-corrupt `.gz`/`.bz2` file raises a clear `AtlasFormatError` instead
    of a raw decompressor exception.
  - `nextMap`, `parseBufferToMap`, and `skipMap` now raise `EOFError` when
    called past the end of the stream (instead of silently parsing an empty
    line), and raise `AtlasFormatError` -- consistent with `openAtlas` --
    on a malformed map line or a stream error mid-read.
- `openAtlas` raises a clear `AtlasFormatError` instead of a raw JSON3 stack
  trace on malformed or non-Atlas input (e.g. a dual-graph file, a truncated
  file, or a header missing required keys / naming an unsupported
  `weightType`).

## [0.1.3]

- Add parallel byte-targeted gzip atlas output (`AtlasOutput`,
  `openAtlasOutput`, `writeMaps!`, `writeGzipMembers!`, `groupByBytes`,
  `gzipMember`, `isGzipOutput`, `atlasHeaderBytes`): writes `.gz` atlases as
  a series of byte-targeted gzip members compressed in parallel across
  threads, concatenating into one valid multi-member `.gz` readable by
  `gunzip`/`zcat`/`openAtlas`.

## [0.1.2]

- Add a 5-argument `Atlas` back-compat constructor (no `weightType`),
  defaulting to `Int64`, for callers written before float weights were
  supported.

## [0.1.1]

- Early fixes and packaging cleanup following the initial release.

## [0.1.0]

- Initial release: JSONL-based Atlas file format (`AtlasHeader`, `Atlas`,
  `Map`, `Districting`), `smartOpen`/`openAtlas`/`newAtlas` read and write
  workflows, transparent `.gz`/`.bz2` compression, and `nextMap`/`addMap`
  map-level IO.
