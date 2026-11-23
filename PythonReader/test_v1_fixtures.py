"""Pin how the Python reader reads the frozen v1 fixtures in test/fixtures/v1/ (see test/fixtures/README.md).

Expected values come from test/fixtures/v1/expected.json, made by an independent reader (Python's json).
District keys are compared as tuples (json.loads of the raw key), because PythonReader keeps the raw key
strings such as '["p2", "c2"]'.
"""
import hashlib
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import AtlasIO  # noqa: E402

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
FIXDIR = os.path.join(REPO, "test", "fixtures", "v1")
with open(os.path.join(FIXDIR, "expected.json"), encoding="utf-8") as f:
    EXPECTED = json.load(f)

ATLASIO_WRITTEN = [n for n in sorted(EXPECTED["fixtures"]) if n != "python_written.jsonl"]


def read_all(path):
    atlas = AtlasIO.openAtlas(path)
    maps = []
    while True:
        m = AtlasIO.nextMap(atlas)
        if m is None:
            break
        maps.append(m)
    AtlasIO.closeAtlas(atlas)
    return atlas, maps


def tuple_keys(districting):
    return {tuple(json.loads(k)): v for k, v in districting.items()}


def districting_digest(districting):
    """Must match make_expected.py's districting_digest (order-independent fingerprint)."""
    lines = sorted("\x1f".join(k) + "\x1e" + str(v) for k, v in tuple_keys(districting).items())
    return hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()


def fixture_params(names):
    for name in names:
        yield pytest.param(name, id=name)


@pytest.mark.parametrize("name", list(fixture_params(sorted(EXPECTED["fixtures"]))))
def test_v1_fixture_reads_expected_values(name):
    exp = EXPECTED["fixtures"][name]
    atlas, maps = read_all(os.path.join(FIXDIR, name))
    h = exp["header"]
    assert atlas.description == h["description"]
    assert atlas.date == h["date"]
    assert atlas.atlasParamType == h["atlasParamType"]
    assert atlas.mapParamType == h["mapParamType"]
    assert atlas.weightType == h.get("weightType", "Int64")
    assert atlas.atlasParam == exp["atlasParam"]
    assert len(maps) == len(exp["maps"])
    for m, em in zip(maps, exp["maps"]):
        assert m.name == em["name"]
        assert m.weight == em["weight"]
        assert m.data == em["data"]
        assert tuple_keys(m.districting) == {tuple(k): v for k, v in em["districting"]}


@pytest.mark.parametrize("name", list(fixture_params(ATLASIO_WRITTEN)))
def test_v1_raw_key_strings_match_json_dumps(name):
    """AtlasIO-written keys are exactly json.dumps(list, ensure_ascii=False): ", " separator, only " and \\
    escaped, non-ASCII written as-is. A future compatibility layer can rebuild raw keys from tuples this way."""
    _, maps = read_all(os.path.join(FIXDIR, name))
    for m in maps:
        for raw in m.districting:
            assert raw == json.dumps(json.loads(raw), ensure_ascii=False)


def test_v1_python_written_keys_decode_correctly():
    """Keys written by Python's json with \\uXXXX escapes inside the key string decode correctly here
    (AtlasIO.jl 0.1.5 mis-decodes them; see test/v1_fixtures.jl)."""
    _, maps = read_all(os.path.join(FIXDIR, "python_written.jsonl"))
    assert ("DOÑA ANA",) in tuple_keys(maps[0].districting)
    assert ("SANTA FÉ", "p1") in tuple_keys(maps[0].districting)
    assert ("B", "p1") in tuple_keys(maps[1].districting)   # written without the space after the comma


def test_v1_big_integers_and_negative_zero_read_exactly():
    """Python's json reads integers beyond 2**53 and -0.0 exactly (AtlasIO.jl 0.1.5's Map path does not)."""
    _, maps = read_all(os.path.join(FIXDIR, "edge.jsonl"))
    data = maps[0].data
    assert data["ints"][0] == 2**63 - 1 and isinstance(data["ints"][0], int)
    assert str(data["floats"][5]) == "-0.0"


def test_v1_real_data_nc_truncated():
    exp = EXPECTED["nc_truncated"]
    path = os.path.join(REPO, exp["path"])
    with open(path, "rb") as f:
        assert hashlib.sha256(f.read()).hexdigest() == exp["sha256"], \
            "the example file changed; regenerate expected.json only if that was intended"
    atlas, maps = read_all(path)
    assert atlas.description == exp["header"]["description"]
    assert atlas.date == exp["header"]["date"]
    assert atlas.atlasParam == exp["atlasParam"]
    assert len(maps) == len(exp["maps"])
    for m, em in zip(maps, exp["maps"]):
        assert m.name == em["name"]
        assert m.weight == em["weight"]
        assert m.data == em["data"]
        assert len(m.districting) == em["n_districting"]
        assert districting_digest(m.districting) == em["districting_digest"]
