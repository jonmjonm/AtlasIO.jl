# Atlas File Format

The Atlas format is a JSONL (JSON Lines) format adapted to hold district maps from redistricting efforts. The Atlas format is a simple extension of the JSONL format that allows for the storage of maps and their associated data in a single file. The [AtlasIO.jl Julia library](https://github.com/jonmjonm/AtlasIO.jl/) provides the ability to read and write Atlas files. The [AtlasIO.py Python library](https://github.com/jonmjonm/AtlasIO.jl/tree/main/PythonReader), from the same git repository, provides the ability to read but not the ability to write files. This format was developed by the [Duke Quantifying Gerrymandering Group](https://duke.is/QGBlog). More information about the project can be found on the [Quantifying Gerrymandering blog](https://duke.is/QGBlog) and in the [Quantifying Gerrymandering Documentation](https://duke.is/QGDoc).

The Atlas format is the format used by the Quantifying Gerrymandering Project's redistricting sampling software to save its data. Both [**Cycle Walk**](https://duke.is/CycleWalk) and [**Metropolized Forest Recom**](https://duke.is/MFRecom) write their ensembles of map assignments in the Atlas format described here.

## Format versions

| Version | Status | How a file says which version it is |
|---|---|---|
| **v1** | Every Atlas file written so far. Written by all versions of AtlasIO.jl. | No `formatVersion` in the header (or `"formatVersion":"1"`). |
| **v2** | **Proposal under review** (decisions of 2026-11-23). No tool writes it yet. | `"formatVersion":"2"` in the header. |

v1 and v2 differ only in how a map's district assignment is stored (see [District assignment](#district-assignment)). Everything else in this document applies to both.

## Structure of an Atlas File

An Atlas file is UTF-8 text in which every line is one JSON value, so it can be read one line at a time, unlike a single large JSON document.

* **Line 1** is a JSON string: a human-readable banner identifying the file as an Atlas. Readers ignore it.
* **Line 2** is the **header**, a JSON object describing the collection of maps (see [Header](#header-line-2)).
* **Line 3** holds the **atlas parameters**, a JSON object of information about the whole run (see [Atlas parameters](#atlas-parameters-line-3)).
* **Each line from line 4 on** is one **map**, a JSON object (see [Map lines](#map-lines-line-4-on)).

Lines are separated by `\n`. The last line may or may not end with `\n`; readers must accept both. Blank lines are not allowed.

### Header (line 2)

| Field | Required | Value |
|---|---|---|
| `description` | yes | Free text describing the atlas. |
| `date` | yes | When the atlas was made, e.g. `"2026-11-23T14:05:00.123"`. |
| `atlasParamType` | yes | Name of the type of the atlas parameters, e.g. `"Dict{String, Any}"`. Documentation only. |
| `mapParamType` | yes | Name of the type of each map's `data`, e.g. `"Dict{String, Any}"`. Documentation only. |
| `weightType` | no | `"Int64"` (the default when absent) or `"Float64"`: the type of every map's `weight`. |
| `formatVersion` | v2: yes | `"2"` for v2. Absent (or `"1"`) means v1. |

**Every header value must be a JSON string.** AtlasIO.jl 0.1.x reads the header as text values only, and a number there, such as `"formatVersion":2`, makes it reject the whole file. That is why the version is the string `"2"`.

Example (v2):

```json
{"description":"NC congressional ensemble","date":"2026-11-23T14:05:00.123","atlasParamType":"Dict{String, Any}","mapParamType":"Dict{String, Any}","weightType":"Int64","formatVersion":"2"}
```

### Atlas parameters (line 3)

Any JSON object, chosen by the program that wrote the atlas (its structure is described by `atlasParamType`), for example the energies, population bounds and number of districts of a sampling run.

**Standard parameter: `"levels in graph"`** (optional, both versions). A list of strings naming what each level of a district key refers to: the node attributes of the dual graph, from the coarsest level to the finest. For example, with

```json
"levels in graph": ["county", "prec_id"]
```

the key `("MECKLENBURG", "052")` means *county* `MECKLENBURG`, *precinct* `052`, and `("WAKE",)` means all of *county* `WAKE`. Writers should include it whenever they know it. Readers must not require it, but tools that match keys to a dual graph need it (AtlasUtilities' `relabel` does). No key should have more levels than the list has names.

### Map lines (line 4 on)

Each map line is a JSON object with exactly these fields, **in this order**:

| Field | Value |
|---|---|
| `name` | A string naming the map, e.g. `"step1200"`. |
| `weight` | A number: the map's weight in the ensemble (an integer unless `weightType` is `"Float64"`). |
| `data` | Any JSON value, usually an object of per-map statistics. Its structure is described by `mapParamType`. |
| `districting` (v1) or `assignment` (v2) | The district assignment (see below). |

The assignment comes **last** on purpose: a reader that only needs `name`, `weight` and `data` can stop reading the line before it. For a large map the assignment is most of the line.

## District assignment

A map assigns every region of the state to a district. Regions are hierarchical in a **multiscale** atlas: a county that is kept whole is assigned as a single region, and a county that is split is assigned precinct by precinct. A region is identified by a **key**, its path down the hierarchy, e.g. `("WAKE",)` or `("MECKLENBURG", "052")`. District numbers are integers.

### v1: `districting`

An array with one single-key object per region. Each object's key is the region's key written as a JSON-style list of strings, and its value is the district:

```json
"districting":[{"[\"WAKE\"]":3},{"[\"MECKLENBURG\", \"052\"]":13},{"[\"MECKLENBURG\", \"074\"]":14}]
```

* The key string is a JSON array of strings. AtlasIO.jl writes it with `", "` between items and escapes only `"` and `\` inside names; other characters, including non-ASCII ones, are written as they are. Readers must decode the key string as a JSON array of strings, so other spacing and other JSON escapes (such as `Ñ`) are read correctly too.
* Names should not contain control characters (tab, newline, ...). A v1 key string holding one is not strictly valid JSON, and strict JSON parsers reject it.
* The order of the entries carries no meaning.

### v2: `assignment`

A nested JSON object (a tree). At each level, each key is a region's name at that level. Its value is either:

* an **integer**: the district of that whole region (a *leaf*), or
* an **object**: the region is split, and the object assigns its sub-regions at the next level (a *branch*).

```json
"assignment":{"MECKLENBURG":{"052":13,"074":14},"WAKE":3}
```

This is the same assignment as the v1 example above: the path from the top of the tree to each leaf is that region's key.

Rules:

1. **A region is either assigned whole or split, never both.** In terms of keys: no key may be a prefix of another key, so `("MECKLENBURG",)` and `("MECKLENBURG", "052")` cannot both appear. v1 cannot prevent that combination; v2 cannot represent it. Writers must refuse such an assignment with an error rather than write it (AtlasIO.jl raises `AtlasFormatError`). In all 79,997 maps of the NC example atlas no key is a prefix of another.
2. **Keys are sorted at every level** in ascending Unicode code point order (the same as UTF-8 byte order). Writing the same map always produces the same bytes, so files can be compared and diffed. Readers must not depend on the order.
3. **Values are integers or objects only, and a branch object must not be empty.** `"MECKLENBURG":{}` would mean a region split into nothing; it has no v1 equivalent, so it would be lost on conversion. Writers must not produce one, and readers must reject a file containing one with an error. This applies only inside the tree: a map with no assignment at all is written `"assignment":{}`.
4. **Names may be any JSON string,** including the empty string and control characters (written with the usual JSON escapes). A name appears at most once in each object.

Compared with v1 on the NC example atlas, the v2 assignment is about a third of the size uncompressed, whole files are about 40% smaller gzipped, and Python reads them about 3.5 times faster.

### The same map in both versions

v1:

```json
{"name":"step1200","weight":1,"data":{"gamma":0.0},"districting":[{"[\"WAKE\"]":3},{"[\"MECKLENBURG\", \"052\"]":13},{"[\"MECKLENBURG\", \"074\"]":14}]}
```

v2:

```json
{"name":"step1200","weight":1,"data":{"gamma":0.0},"assignment":{"MECKLENBURG":{"052":13,"074":14},"WAKE":3}}
```

## Compatibility between versions

* **One version per file.** A file's header says which version every one of its maps uses.
* **Readers should read both v1 and v2.** A missing `formatVersion` means v1. A reader that meets a `formatVersion` it does not know must stop with a clear error (e.g. "upgrade AtlasIO"), never guess.
* **Converting is lossless** in both directions: every v2 file converts to v1, and every v1 file whose keys follow rule 1 converts to v2.
* **Old readers on v2 files** fail safely instead of returning wrong data. In AtlasIO.jl 0.1.x and 0.2.x the header opens, `nextMap` raises `AtlasFormatError` (there is no `districting` field), and `nextMapData` and `skipMap`, which never look at the assignment, keep working. The current Python reader stops with `KeyError: 'districting'`.

## File Extension and Compression

Atlas files use the file extension `.jsonl` if the file in Atlas is plain, uncompressed text. If the Atlas is compressed it will either use the file extension `.jsonl.gz` or `.jsonl.bz2`. The same extensions and compression are used for v1 and v2.

The `.gz` extension signifies the use of the standard [**Gnu Zip tools**](https://en.m.wikipedia.org/wiki/Gzip) (`gzip`, `gunzip`, `zcat`) and can be read by a number of libraries and command line tools. These tools use the standard Deflate algorithm to compress data. A `.gz` file may consist of several concatenated gzip members (AtlasIO.jl's parallel writer produces such files); standard tools read them as one stream.

The `.bz2`  extension signifies the use of the standard
[**BZip2 tools**](https://en.m.wikipedia.org/wiki/Bzip2) (`bzip2`, `bzcat`) and also can be read by a number of libraries and command line tools. These tools use the standard Burrows–Wheeler algorithm to compress data.

The Bzip2 compression format typically results in a smaller file than the Gzip compression format. However, the Bzip2 compression is slower to compress and uncompress. We also explored saving files by saving the incremental changes in the maps. However, it was decided that the advantage of using standard compression tools was significant in light of the very high compression ratios they delivered out of the box.

## Work Directly with Compressed Files

One nice feature of the AtlasIO libraries is that they can read compressed files directly, and the Julia library can also write them. This both increases the speed of writing and decreases the size of the Atlas files significantly. (The Python reader currently reads `.jsonl` and `.jsonl.gz` files, but not `.jsonl.bz2`.)

### Corrupted Compressed Files

One downside of directly writing compressed files is that the files can not be directly examined during the run and might be left in a corrupted state if the run is interrupted. A corrupted file can typically easily be largely recovered using

`` zcat atlas-corrupted.jsonl.gz >  atlas-fixed.jsonl ``

You can also use the `zcat` command to examine a file during a run.
