"""Write test/fixtures/v2/: v2 twins of the frozen v1 fixtures, the spec's examples, and their expected values.

Everything here is made with Python's json module, independently of AtlasIO, so the tests do not check
AtlasIO against itself. Each twin is its v1 file with exactly two changes:
  * line 2 (the header) gains "formatVersion":"2" as its last field;
  * each map line's last field, "districting":[...], is replaced by "assignment":{...}, the same keys as a
    tree, written compactly with sorted keys and non-ASCII characters as they are (atlas_format.md, v2).
The banner, the atlas parameters and every map's name, weight and data keep their exact v1 bytes. A twin
must therefore read back to exactly the values its v1 file reads to (test/fixtures/v1/expected.json).

Run from the repository root (after make_expected.py, whose output this reuses):
    python3 test/fixtures/make_v2_fixtures.py
"""
import bz2
import gzip
import hashlib
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
V1 = os.path.join(HERE, "v1")
V2 = os.path.join(HERE, "v2")
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
NC_REL = "ExampleAtlas/atlas_truncated_nc_multiscale.jsonl"


def read_text(path):
    opener = {".gz": gzip.open, ".bz2": bz2.open}.get(os.path.splitext(path)[1], open)
    with opener(path, "rt", encoding="utf-8") as f:
        return f.read()


def tree_of(pairs):
    """Build the v2 assignment tree from (key-parts, district) pairs, enforcing rules 1 and 3."""
    tree = {}
    for parts, district in pairs:
        assert parts, "a district key has at least one level"
        node = tree
        for p in parts[:-1]:
            child = node.setdefault(p, {})
            assert isinstance(child, dict), ("key is a prefix of another key", parts)
            node = child
        assert parts[-1] not in node, ("duplicate key, or a key that is a prefix of another", parts)
        node[parts[-1]] = district
    return tree


def flatten(tree, prefix=()):
    for name, v in tree.items():
        if isinstance(v, dict):
            assert v, "empty branch"
            yield from flatten(v, prefix + (name,))
        else:
            yield prefix + (name,), v


def dumps_tree(tree):
    # sort_keys sorts by code point, which is the UTF-8 byte order the spec asks for.
    return json.dumps(tree, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def v2_header(line):
    assert line.endswith("}") and "formatVersion" not in json.loads(line), line
    return line[:-1] + ',"formatVersion":"2"}'


def v2_map_line(line):
    m = json.loads(line)
    assert list(m) == ["name", "weight", "data", "districting"], list(m)
    # "districting" is the last field and a v1 key string's quotes are escaped inside it, so the last
    # occurrence of this text is the start of the field.
    cut = line.rfind('"districting":')
    assert cut > 0 and line[cut - 1] in ", ", line[:80]
    pairs = [(tuple(json.loads(k)), v) for entry in m["districting"] for k, v in entry.items()]
    tree = tree_of(pairs)
    assert sorted(flatten(tree)) == sorted(pairs)
    return line[:cut] + '"assignment":' + dumps_tree(tree) + "}"


def v2_text(v1_text):
    lines = v1_text.split("\n")
    final_newline = lines[-1] == ""
    if final_newline:
        lines = lines[:-1]
    out = [lines[0], v2_header(lines[1]), lines[2]] + [v2_map_line(l) for l in lines[3:]]
    return "\n".join(out) + ("\n" if final_newline else "")


def write(name, text, members=False):
    data = text.encode("utf-8")
    path = os.path.join(V2, name)
    if name.endswith(".bz2"):
        data = bz2.compress(data)
    elif name.endswith(".gz") and members:
        # One gzip member per line, as AtlasIO's parallel AtlasOutput writer produces (header: 3 lines).
        lines = text.split("\n")
        chunks = ["\n".join(lines[:3]) + "\n"] + [l + "\n" for l in lines[3:] if l]
        data = b"".join(gzip.compress(c.encode("utf-8"), mtime=0) for c in chunks)
    elif name.endswith(".gz"):
        data = gzip.compress(data, mtime=0)
    with open(path, "wb") as f:
        f.write(data)
    assert read_text(path) == text
    return hashlib.sha256(data).hexdigest()


# The spec's own examples (atlas_format.md, "v2: assignment"), with their keys written out by hand here
# rather than derived, so the reader is checked against the document.
SPEC_HEADER = {"description": "v2 examples from atlas_format.md", "date": "2026-11-23T14:05:00.123",
               "atlasParamType": "Dict{String, Any}", "mapParamType": "Dict{String, Any}", "weightType": "Int64",
               "formatVersion": "2"}
SPEC_PARAMS = {"levels in graph": ["county", "mcd", "prec_id"]}
SPEC_MAPS = [
    ('{"name":"step1200","weight":1,"data":{"gamma":0.0},'
     '"assignment":{"MECKLENBURG":{"052":13,"074":14},"WAKE":3}}',
     [[["MECKLENBURG", "052"], 13], [["MECKLENBURG", "074"], 14], [["WAKE"], 3]]),
    ('{"name":"three levels","weight":2,"data":{},'
     '"assignment":{"MECKLENBURG":{"CHARLOTTE":{"052":13,"074":14},"DAVIDSON":12},"WAKE":3}}',
     [[["MECKLENBURG", "CHARLOTTE", "052"], 13], [["MECKLENBURG", "CHARLOTTE", "074"], 14],
      [["MECKLENBURG", "DAVIDSON"], 12], [["WAKE"], 3]]),
    ('{"name":"empty assignment","weight":1,"data":{},"assignment":{}}', []),
    # Rule 4: any JSON string is a name, including "" and escaped control characters.
    ('{"name":"odd names","weight":1,"data":{},'
     '"assignment":{"":{"":1},"a\\tb":{"c\\nd":2},"q\\"\\\\":3}}',
     [[["", ""], 1], [["a\tb", "c\nd"], 2], [['q"\\'], 3]]),
]

os.makedirs(V2, exist_ok=True)
expected_v1 = json.load(open(os.path.join(V1, "expected.json"), encoding="utf-8"))
sha = {}

twins = {"edge.jsonl": "edge.jsonl", "edge.jsonl.gz": "edge.jsonl", "edge.jsonl.bz2": "edge.jsonl",
         "edge_multimember.jsonl.gz": "edge.jsonl", "edge_float.jsonl": "edge_float.jsonl",
         "python_written.jsonl": "python_written.jsonl"}
for name, source in twins.items():
    assert read_text(os.path.join(V1, name)) == read_text(os.path.join(V1, source))
    sha[name] = write(name, v2_text(read_text(os.path.join(V1, source))), members="multimember" in name)

nc_v1 = read_text(os.path.join(REPO, NC_REL))
assert hashlib.sha256(nc_v1.encode("utf-8")).hexdigest() == expected_v1["nc_truncated"]["sha256"]
sha["nc_truncated.jsonl.gz"] = write("nc_truncated.jsonl.gz", v2_text(nc_v1))

spec_text = "\n".join([json.dumps("This is an Atlas for Redistricting Maps (v2 spec examples)"),
                       json.dumps(SPEC_HEADER, separators=(",", ":")),
                       json.dumps(SPEC_PARAMS, separators=(",", ":"))] + [l for l, _ in SPEC_MAPS]) + "\n"
for line, pairs in SPEC_MAPS:   # the hand-written keys and the tree agree
    assert sorted(flatten(json.loads(line)["assignment"])) == sorted((tuple(k), v) for k, v in pairs)
sha["spec_examples.jsonl"] = write("spec_examples.jsonl", spec_text)

expected = {
    "_about": "Generated by test/fixtures/make_v2_fixtures.py. Do not edit by hand. A twin's expected values "
              "are those of its v1 source in v1/expected.json (fixtures, or nc_truncated for the NC twin).",
    "twins": dict(twins, **{"nc_truncated.jsonl.gz": "nc_truncated"}),
    "sha256": sha,
    "spec_examples": {"header": SPEC_HEADER, "atlasParam": SPEC_PARAMS,
                      "maps": [dict(json.loads(l), assignment=None, districting=sorted(p))
                               for l, p in SPEC_MAPS]},
}
for m in expected["spec_examples"]["maps"]:
    del m["assignment"]
with open(os.path.join(V2, "expected.json"), "w", encoding="utf-8", newline="\n") as f:
    json.dump(expected, f, ensure_ascii=False, indent=1, sort_keys=True)
    f.write("\n")

v1_size = sum(len(l) for l in nc_v1.split("\n")[3:])
v2_size = sum(len(l) for l in v2_text(nc_v1).split("\n")[3:])
print("wrote", V2, "| files:", sorted(sha), "| NC map lines v2/v1 size: %.2f" % (v2_size / v1_size))
