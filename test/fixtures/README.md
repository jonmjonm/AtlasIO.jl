# v1 test fixtures (frozen)

`v1/` holds Atlas files in the **v1 format exactly as AtlasIO 0.1.5 (JSON3) wrote them**, plus one file
written by another tool. Later versions of AtlasIO, including the JSON.jl migration and a future format
v2, must keep reading these files to the same values. The Julia tests are in `test/v1_fixtures.jl`; the
Python reader's tests are in `PythonReader/test_v1_fixtures.py`.

**Do not regenerate these files with a newer AtlasIO.** `generate_v1_fixtures.jl` refuses to run unless
AtlasIO is 0.1.5 with JSON3.

| File | What it pins |
|---|---|
| `edge.jsonl` | Awkward names and keys (quotes, backslashes, commas, brackets, apostrophes, é, 中文, 😀, 3-level keys), number formatting, Int64 extremes, nested and empty data, empty districting |
| `edge.jsonl.gz`, `edge.jsonl.bz2` | The same content through AtlasIO's gzip and bzip2 writers |
| `edge_multimember.jsonl.gz` | The same content as a multi-member gzip (one member per map), as `AtlasOutput` writes |
| `edge_float.jsonl` | A file with `weightType` `Float64` |
| `python_written.jsonl` | A v1 file written by Python's `json` (`\uXXXX` escapes, including inside key strings; `", "`/`": "` separators; one key without the space after the comma) |
| `expected.json` | Expected values, computed by **Python's `json`** (not AtlasIO) from the files above and from `ExampleAtlas/atlas_truncated_nc_multiscale.jsonl` (checked by its SHA-256, and per-map districting fingerprints) |

Names contain no control characters. v1 keys holding them are not strictly valid JSON (Python's
`json.loads` rejects them unless `strict=False`), so they are deliberately left out of the frozen format.

## v1 bugs these fixtures exposed

Fixed in AtlasIO.jl 0.2 (the tests were `@test_broken` under 0.1.5 and are now plain `@test`s):

* **Integers beyond 2^53 and `-0.0`.** AtlasIO 0.1.5's `Map` and atlas-parameter read paths parsed every
  number as a `Float64`, so `typemax(Int64)` read as `9.223372036854776e18`, `-7375463094308724563` as
  `-7375463094308724736`, and `-0.0` as `0`.
* **`\uXXXX` escapes inside district keys.** 0.1.5's `parseDistrictKey` dropped the backslash, so keys
  written by Python's `json` with non-ASCII names decoded wrongly (`python_written.jsonl`, map "Doña Ana").

Fixed in AtlasIO 0.2.1: **`.bz2` (Python).** PythonReader now opens `.bz2` files (those tests were
`xfail(strict=True)`).

# v2 test fixtures

`v2/` holds format v2 files made by `make_v2_fixtures.py` with **Python's `json`** (not AtlasIO):

* **Twins** of the v1 files above (and of `ExampleAtlas/atlas_truncated_nc_multiscale.jsonl`, as
  `nc_truncated.jsonl.gz`). Each is its v1 file with `"formatVersion":"2"` added to the header and each
  `districting` rewritten as the `assignment` tree; every other byte is unchanged. A twin must read back to
  exactly the values of its v1 source, so the tests check twins against `v1/expected.json`.
* `spec_examples.jsonl`: the examples in `atlas_format.md`, including three levels, an empty assignment and
  names that are empty or hold control characters (spec rule 4), with keys written out by hand.
* `expected.json`: which v1 file each twin comes from, the SHA-256 of every file, and the expected values
  of the spec examples.

Tests: `test/v2_fixtures.jl` (Julia), `python/tests/test_atlasio.py` (the `atlasio` package),
`PythonReader/test_v2_fixtures.py` (the original reader). `test/compat/run_v2_old_readers.sh` checks that
AtlasIO.jl 0.1.5 and 0.2.0, which predate v2, fail safely on these files; `PythonReader/test_v2_fixtures.py`
checks the same for the 0.2.0 Python reader (kept in `test/compat/python_reader_0_2_0/`).

The v2 files may be regenerated (they are derived, not frozen): `python3 test/fixtures/make_v2_fixtures.py`.

## How the files were made

From the repository root, with AtlasIO 0.1.5:

    julia --project=. test/fixtures/generate_v1_fixtures.jl
    python3 test/fixtures/make_python_fixture.py
    python3 test/fixtures/make_expected.py

`/.gitattributes` keeps `test/fixtures/v1/**` out of Git LFS and stops git from changing line endings, so the
files stay byte-exact.
