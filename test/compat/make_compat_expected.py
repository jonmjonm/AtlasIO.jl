"""Test F, step 2 of 3: compute OUTDIR/expected.json from the files step 1 wrote, with Python's json.

    python3 test/compat/make_compat_expected.py OUTDIR

The expected values come from an independent reader (Python's json), not from either AtlasIO version.
District keys are decoded with json.loads.
"""
import bz2
import gzip
import json
import os
import sys

if len(sys.argv) != 2:
    sys.exit("usage: python3 test/compat/make_compat_expected.py OUTDIR")
OUT = sys.argv[1]


def read_text(path):
    opener = {".gz": gzip.open, ".bz2": bz2.open}.get(os.path.splitext(path)[1], open)
    with opener(path, "rt", encoding="utf-8") as f:
        return f.read()


expected = {}
for name in sorted(os.listdir(OUT)):
    if not name.endswith((".jsonl", ".jsonl.gz", ".jsonl.bz2")):
        continue
    lines = read_text(os.path.join(OUT, name)).split("\n")
    if lines[-1] == "":
        lines = lines[:-1]
    maps = []
    for line in lines[3:]:
        m = json.loads(line)
        assert list(m) == ["name", "weight", "data", "districting"], (name, list(m))
        maps.append({"name": m["name"], "weight": m["weight"], "data": m["data"],
                     "districting": sorted([json.loads(k), v] for e in m["districting"] for k, v in e.items())})
    expected[name] = {"header": json.loads(lines[1]), "atlasParam": json.loads(lines[2]), "maps": maps}

with open(os.path.join(OUT, "expected.json"), "w", encoding="utf-8") as f:
    json.dump(expected, f, ensure_ascii=False)
print("test F step 2: expected values for", len(expected), "files")
