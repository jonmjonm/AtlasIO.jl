# Changelog

## Unreleased

- **`eachMap(path)` and `eachMapData(path)`**: iterators over an atlas's maps (or an open `Atlas`), in file
  order, with `skip` (a burn-in) and `max`. With several threads each batch is parsed in parallel: about 2.5
  times faster than the `nextMap` loop on 8 threads, as fast as it on one, holding one batch in memory.
  `eachMapData` skips the district assignment: about 6 to 7 times faster. An error is raised at its map, after the
  maps before it. From a path the file is closed at the end or on an error.
- **`eachMap(f, path)` and `eachMapData(f, path)`** (and on an open `Atlas`): `f` of each map, in file order,
  with `f` run in the parallel parse tasks, keeping only its results. With real work per map it is 3 to 4 times
  faster on 8 threads than calling `f` in the loop body, and as fast as AtlasUtilities' batch pattern. Tasks
  take the next map as they finish one, so uneven work per map doesn't leave them idle.
- **`ntasks` and `onerror` keywords** for all four forms. `ntasks` (default `Threads.nthreads()`) sets the number
  of tasks. `onerror = :raise` (the default) raises an error at its map; an error from `f` is raised unchanged
  after an `@error` log naming the map with the backtrace from inside `f`. `onerror = :skip` leaves out maps
  that can't be parsed or for which `f` raises, logging the first 10 and the number left out; a failure
  reading the stream is still raised.
- **`openAtlas(f, path)`**: the do-block form, closing the atlas afterwards even after a `break` or an error.
- Docstrings for `openAtlas`, `nextMap`, `parseBufferToMap`, `skipMap`, `copyAtlasHeader` and `AtlasHeader`;
  every exported name now has one.

## [0.2.4]

The Python package is **published on PyPI**: `pip install atlasio`. No code changes in either language.

### Added

- `.github/workflows/pypi.yml`: pushing a release tag builds the Python package and publishes it to PyPI with
  Trusted Publishing (no stored tokens). It first checks that the tag, `atlasio.__version__` and `Project.toml`
  agree and tests the built wheel. Running it by hand publishes to TestPyPI, as a dry run.
- `RELEASING.md`: the release steps, for both languages.
- A test that the Python and Julia versions match.

### Changed

- `python/pyproject.toml`: the version is read from `atlasio.__version__` (one place to edit); SPDX license
  `MIT` with the license file bundled (`python/LICENSE`, a copy CI checks); authors, keywords, classifiers and a
  changelog link for the PyPI page.
- Docs: install with `pip install atlasio`; the git and httpimport pins move to `v0.2.4`.

## [0.2.3]

The Python `atlasio` package **writes Atlas files**. AtlasIO.jl is unchanged.

### Added

- **Python:** `atlasio.new_atlas(dest, ...)` creates an atlas and returns an `AtlasWriter`. It has
  `add_map(name, districting, weight, data)` (or `add_map(m)` for a `Map`), `add_maps` and `close`, and works in
  a `with` block. It writes format v1 by default, as AtlasIO.jl does, or v2 with `format_version=2`. Plain,
  `.gz` or `.bz2` is chosen by extension; an open file object also works. `like=atlas` copies an existing
  atlas's header and parameters. `atlasio.map_json(m, format_version)` gives one map's line.
- The files are laid out as AtlasIO.jl writes them: the same banner, header fields and order, and map field
  order. v2 assignments are byte-identical to Julia's; floats may be spelled differently (`1e-07` for
  `1.0e-7`). AtlasIO.jl reads them back with the same districtings and data.
- Input is checked before anything is written, so a bad map never leaves a partial line. District keys must be
  tuples of strings and districts integers. NaN and infinity are refused. numpy numbers and arrays are
  converted. In v2, a region both whole and split raises `AtlasFormatError`.
- Tests: rewriting every fixture in both versions keeps every map, header field and parameter; header lines and
  v2 assignments match AtlasIO.jl's byte for byte; error cases.

### Changed

- `convert` now uses the writer's encoders (same output).
- Docs pin httpimport and pip installs to the `v0.2.3` tag.

## [0.2.2]

AtlasIO can **write format v2** when asked, and **convert** files between v1 and v2, in Julia and in Python.
**v1 stays the default**: code that does not ask for v2 writes exactly what it wrote before.

### Added

- **Julia:** a `formatVersion` keyword (`1` by default, or `2`) on `newAtlas`, `addMap`, `addMaps`, `mapBytes`
  and `mapJSON`. Use the same version for the header and every map. The v2 writer sorts names at every level
  (the same map always gives the same bytes) and raises `AtlasFormatError` for a districting v2 cannot hold: a
  key that is a prefix of another (a region both whole and split) or the empty key.
- **Julia:** `convertAtlas(src, dst; formatVersion)` converts a file to either version. It rewrites only the
  header's `formatVersion` and each map's assignment; the banner, the atlas parameters and each map's name,
  weight and data are copied byte for byte. Errors name the line and map, and remove `dst`. Parallel, and
  writes `.gz` output as parallel gzip members.
- **Python:** `atlasio.convert(src, dst, to)` and the command `python -m atlasio convert SRC DST --to 2`
  (`atlasio convert ...` once installed): the same rules, and byte-identical output to `convertAtlas`.
- Tests: the writer reproduces the spec's examples byte for byte; converting each v1 fixture gives exactly
  its v2 twin, and converting back is lossless; a randomized write/read round trip; error cases.

### Changed

- Docs pin httpimport and pip installs to the `v0.2.2` tag.

## [0.2.1]

AtlasIO reads **format v2** (see `atlas_format.md`), in Julia and in Python. It still **writes v1 only**, so
nothing changes for files it writes; this release lets readers get ahead of a future v2 writer. Everything
that worked with 0.2.0 works unchanged.

### Added

- **Julia:** `openAtlas`, `nextMap`, `nextMaps`, `parseMap` and `parseBufferToMap` read v2 files, whose maps
  store the district assignment as a tree (`"assignment"`) instead of v1's list of key strings
  (`"districting"`). A map reads to the same `Districting` (tuple keys) from either version.
  `nextMapData`, `parseMapData` and `skipMap` read v2 files too.
- `Atlas` has a new field, `formatVersion` (`"1"` or `"2"`, from the header). Constructing an `Atlas` without
  it, as before, gives `"1"`.
- Readers reject what the v2 spec forbids, with an `AtlasFormatError` naming the map: an empty branch, a
  district that is not an integer, a map line with both or neither of `districting` and `assignment`, and a
  map line whose version differs from the header's (a file holds maps of one version only).
- A header `formatVersion` this AtlasIO does not know raises `AtlasFormatError` asking to upgrade, and a
  non-string header value now gets a clear message.
- **Python: the `atlasio` package** (`python/`), installable with
  `pip install "atlasio @ git+https://github.com/jonmjonm/AtlasIO.jl@v0.2.1#subdirectory=python"`. Reads v1
  and v2, plain, `.gz` and `.bz2`; district keys are tuples, as in Julia. Standard library only (uses
  `orjson` if installed).
- **Python: `PythonReader/AtlasIO.py`** keeps its interface and its string district keys, and now reads v2
  files (keys built in the form AtlasIO.jl writes in v1), `.bz2` files, and `formatVersion`. It reads files as
  UTF-8 on every platform. `helper_functions.get_node_to_district` accepts string or tuple keys, and now
  matches keys written with other spacing or escapes.
- v2 test files (`test/fixtures/v2/`): twins of the frozen v1 files and the spec's examples, made with
  Python's `json`; each twin must read exactly like its v1 source. CI also checks that AtlasIO.jl 0.1.5 and
  0.2.0 and the 0.2.0 Python reader fail safely on v2 files (an error, never wrong districts).

### Changed

- `nextMaps` raises a bad line's own error (e.g. `AtlasFormatError`), as `nextMap` does, instead of the
  threads' `CompositeException`.
- Docs pin httpimport to a release tag (`refs/tags/v0.2.1`) instead of `main`.

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

- District keys containing JSON escapes other than `\"` and `\\` (e.g. `\u00d1`, as Python's `json.dumps`
  writes non-ASCII characters by default) are decoded correctly; 0.1.x dropped the backslash.
- The documented `writeMaps!` example produced a corrupt atlas (no newlines between maps); it now uses
  `mapBytes`.

### Performance

Writing districtings now applies both levels of key escaping in a single pass. Measured on the full NC
example atlas (first 5,000 maps of `atlas_nc_multiscale.jsonl.gz`, 142 MB of JSON; Apple M-series, Julia
1.13; `benchmark/bench_full.jl`), MB/s of map JSON:

| | 0.1.5 | 0.2.0 |
|---|---|---|
| `addMap`, 1 thread | 58 | 105 (1.8×) |
| `addMaps`, 8 threads | 274 | 385 (1.4×) |
| `nextMapData`, 1 thread | 107 | 195 (1.8×; gunzip alone is ~213) |
| `nextMaps`, 8 threads | 64 | 71 |
| `nextMap`, 1 thread | 19 | 19 (unchanged; rebuilding `districting` dominates) |

### Added

- `parseMap`, `mapJSON`, `mapBytes` (see above).
- `nextMapData`/`parseMapData` no longer scan `districting` at all (JSON.jl's lazy parser stops before it).
- `benchmark/bench_nc.jl` and `benchmark/bench_full.jl`, which run unchanged against older AtlasIO versions
  for comparison.
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
