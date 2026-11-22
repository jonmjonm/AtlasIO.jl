"""Write test/fixtures/v1/python_written.jsonl: a v1 atlas produced by a tool other than AtlasIO.

It uses Python's json defaults the way a third-party writer would:
  * ensure_ascii=True, so non-ASCII characters are written as \\uXXXX escapes, both in the outer JSON and
    INSIDE the district-key strings (the key string itself is json.dumps of the key list);
  * ", " / ": " separators in the outer JSON;
  * one key written without the space after the comma (["B","p1"]).

AtlasIO.jl 0.1.5's parseDistrictKey mis-decodes the \\uXXXX escapes inside keys (it drops the backslash),
so the Julia tests mark those maps @test_broken until that bug is fixed. Run from the repository root:
    python3 test/fixtures/make_python_fixture.py
"""
import json
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "v1", "python_written.jsonl")


def key(*parts, compact=False):
    return json.dumps(list(parts), separators=(",", ":")) if compact else json.dumps(list(parts))


header = {"description": "v1 fixture written by Python json (not AtlasIO)", "date": "2026-11-22T00:00:00",
          "atlasParamType": "Dict{String, Any}", "mapParamType": "Dict{String, Any}", "weightType": "Int64"}
params = {"levels in graph": ["county", "prec_id"], "note": "Doña Ana", "gamma": 0.0}
maps = [
    {"name": "Doña Ana", "weight": 1, "data": {"gamma": 0.0, "label": "año"},
     "districting": [{key("DOÑA ANA"): 2}, {key("37011"): 1}, {key("SANTA FÉ", "p1"): 3}]},
    {"name": "ascii only", "weight": 2, "data": {"x": [1.0, 2.5], "y": None},
     "districting": [{key("A"): 1}, {key("B", "p1", compact=True): 2}, {key("B", "p2"): 1}]},
]

with open(OUT, "w", encoding="utf-8", newline="\n") as f:
    f.write(json.dumps("This is an Atlas for Redistricting Maps (written by Python)") + "\n")
    f.write(json.dumps(header) + "\n")
    f.write(json.dumps(params) + "\n")
    for m in maps:
        f.write(json.dumps(m) + "\n")
print("wrote", OUT)
