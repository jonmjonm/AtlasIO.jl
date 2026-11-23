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

## Known v1 bugs recorded as expected failures

* **Integers beyond 2^53 and `-0.0` (Julia).** AtlasIO 0.1.5's `Map` and atlas-parameter read paths parse
  every number as a `Float64`, so `typemax(Int64)` reads as `9.223372036854776e18`, `-7375463094308724563`
  as `-7375463094308724736`, and `-0.0` as `0`. `nextMapData` reads them exactly. These checks are
  `@test_broken`; flip them to `@test` when the bug is fixed (the JSON.jl migration fixes it).
* **`\uXXXX` escapes inside district keys (Julia).** `parseDistrictKey` drops the backslash, so keys
  written by Python's `json` with non-ASCII names decode wrongly (`python_written.jsonl`, map "Doña Ana").
* **`.bz2` (Python).** PythonReader cannot open `.bz2` files yet. Those tests are `xfail(strict=True)`, so
  they fail loudly once support lands, as a reminder to remove the marker.

## How the files were made

From the repository root, with AtlasIO 0.1.5:

    julia --project=. test/fixtures/generate_v1_fixtures.jl
    python3 test/fixtures/make_python_fixture.py
    python3 test/fixtures/make_expected.py

`/.gitattributes` keeps `test/fixtures/**` out of Git LFS and stops git from changing line endings, so the
files stay byte-exact.
