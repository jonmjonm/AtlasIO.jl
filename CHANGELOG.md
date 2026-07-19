# Changelog

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
