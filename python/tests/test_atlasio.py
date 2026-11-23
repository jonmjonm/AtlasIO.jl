"""Tests for the atlasio package, against the shared fixtures in test/fixtures/ (see test/fixtures/README.md).

Expected values come from an independent reader (Python's json, in make_expected.py and make_v2_fixtures.py).
A v2 twin must read to exactly the values of its v1 source.
"""
import gzip
import hashlib
import io
import json
import os

import pytest

import atlasio

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
V1DIR = os.path.join(REPO, "test", "fixtures", "v1")
V2DIR = os.path.join(REPO, "test", "fixtures", "v2")
with open(os.path.join(V1DIR, "expected.json"), encoding="utf-8") as f:
    V1EXP = json.load(f)
with open(os.path.join(V2DIR, "expected.json"), encoding="utf-8") as f:
    V2EXP = json.load(f)


def read_all(path):
    with atlasio.open_atlas(path) as atlas:
        return atlas, list(atlas)


def digest(districting):
    """Must match make_expected.py's districting_digest (order-independent fingerprint)."""
    lines = sorted("\x1f".join(k) + "\x1e" + str(v) for k, v in districting.items())
    return hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()


def expected_districting(pairs):
    return {tuple(k): v for k, v in pairs}


def check(atlas, maps, exp, version):
    h = exp["header"]
    assert atlas.format_version == version
    assert atlas.description == h["description"]
    assert atlas.date == h["date"]
    assert atlas.atlas_param_type == h["atlasParamType"]
    assert atlas.map_param_type == h["mapParamType"]
    assert atlas.weight_type == h.get("weightType", "Int64")
    assert atlas.params == exp["atlasParam"]
    assert len(maps) == len(exp["maps"])
    for m, em in zip(maps, exp["maps"]):
        assert m.name == em["name"]
        assert m.weight == em["weight"] and type(m.weight) is type(em["weight"])
        assert m.data == em["data"]
        if "districting" in em:
            assert m.districting == expected_districting(em["districting"])
        else:
            assert len(m.districting) == em["n_districting"]
            assert digest(m.districting) == em["districting_digest"]


# --- v1 -----------------------------------------------------------------------------------------------

@pytest.mark.parametrize("name", sorted(V1EXP["fixtures"]))
def test_v1_fixture(name):
    atlas, maps = read_all(os.path.join(V1DIR, name))
    check(atlas, maps, V1EXP["fixtures"][name], "1")


def test_v1_real_data_nc_truncated():
    exp = V1EXP["nc_truncated"]
    atlas, maps = read_all(os.path.join(REPO, exp["path"]))
    check(atlas, maps, exp, "1")


def test_v1_python_written_keys_decode_correctly():
    _, maps = read_all(os.path.join(V1DIR, "python_written.jsonl"))
    assert ("DOÑA ANA",) in maps[0].districting          # \u escapes inside the key string
    assert ("B", "p1") in maps[1].districting            # written without the space after the comma


# --- v2 -----------------------------------------------------------------------------------------------

def test_v2_files_are_the_ones_expected_json_describes():
    for name, h in V2EXP["sha256"].items():
        with open(os.path.join(V2DIR, name), "rb") as f:
            assert hashlib.sha256(f.read()).hexdigest() == h, name


@pytest.mark.parametrize("name", sorted(V2EXP["twins"]))
def test_v2_twin_reads_like_its_v1_source(name):
    source = V2EXP["twins"][name]
    exp = V1EXP["nc_truncated"] if source == "nc_truncated" else V1EXP["fixtures"][source]
    atlas, maps = read_all(os.path.join(V2DIR, name))
    check(atlas, maps, exp, "2")
    v1path = os.path.join(REPO, exp["path"]) if source == "nc_truncated" else os.path.join(V1DIR, name)
    _, v1maps = read_all(v1path)
    assert [m.districting for m in maps] == [m.districting for m in v1maps]


def test_v2_spec_examples():
    exp = V2EXP["spec_examples"]
    atlas, maps = read_all(os.path.join(V2DIR, "spec_examples.jsonl"))
    check(atlas, maps, exp, "2")
    assert atlas.params["levels in graph"] == ["county", "mcd", "prec_id"]
    assert maps[1].districting == {("WAKE",): 3, ("MECKLENBURG", "DAVIDSON"): 12,
                                   ("MECKLENBURG", "CHARLOTTE", "052"): 13, ("MECKLENBURG", "CHARLOTTE", "074"): 14}
    assert maps[2].districting == {}
    assert maps[3].districting[("a\tb", "c\nd")] == 2 and maps[3].districting[("", "")] == 1


V1_HEADER = '{"description":"d","date":"t","atlasParamType":"A","mapParamType":"M"}'
V2_HEADER = '{"description":"d","date":"t","atlasParamType":"A","mapParamType":"M","formatVersion":"2"}'


def atlas_text(*lines, header=V2_HEADER):
    return "\n".join(['"banner"', header, "{}"] + list(lines)) + "\n"


def map_line(assignment):
    return '{"name":"x","weight":1,"data":{},"assignment":%s}' % assignment


BAD_LINES = {
    "empty branch": map_line('{"A":{"p1":1},"B":{}}'),
    "empty branch, deeper": map_line('{"A":{"t":{}}}'),
    "boolean district": map_line('{"A":true}'),
    "float district": map_line('{"A":2.0}'),
    "string district": map_line('{"A":"2"}'),
    "null district": map_line('{"A":null}'),
    "array district": map_line('{"A":[2]}'),
    "assignment not an object": map_line("[]"),
    "both fields": '{"name":"x","weight":1,"data":{},"districting":[],"assignment":{}}',
    "neither field": '{"name":"x","weight":1,"data":{}}',
    "not an object": "[1,2]",
    "not JSON": "{oops",
}


@pytest.mark.parametrize("label", sorted(BAD_LINES))
def test_v2_reader_rejects_what_the_spec_forbids(label):
    with pytest.raises(atlasio.AtlasFormatError):
        atlasio.parse_map(BAD_LINES[label])
    with atlasio.open_atlas(io.StringIO(atlas_text(BAD_LINES[label]))) as atlas:
        with pytest.raises(atlasio.AtlasFormatError):
            atlas.next_map()


def test_error_names_the_map():
    with pytest.raises(atlasio.AtlasFormatError, match=r'empty branch.*\(map "x"\)'):
        atlasio.parse_map(map_line('{"A":{}}'))


def test_one_version_per_file():
    v1line = '{"name":"old","weight":1,"data":{},"districting":[{"[\\"A\\"]":1}]}'
    v2line = map_line('{"A":1}')
    assert atlasio.parse_map(v1line).districting == atlasio.parse_map(v2line).districting == {("A",): 1}
    for header, line in [(V2_HEADER, v1line), (V1_HEADER, v2line)]:
        with atlasio.open_atlas(io.StringIO(atlas_text(line, header=header))) as atlas:
            with pytest.raises(atlasio.AtlasFormatError, match="one version only"):
                atlas.next_map()


def test_format_version_header():
    assert atlasio.open_atlas(io.StringIO(atlas_text(header=V1_HEADER))).format_version == "1"
    with pytest.raises(atlasio.AtlasFormatError, match='formatVersion "3".*Upgrade atlasio'):
        atlasio.open_atlas(io.StringIO(atlas_text(header=V2_HEADER.replace('"2"', '"3"'))))
    with pytest.raises(atlasio.AtlasFormatError, match="must be a JSON string"):
        atlasio.open_atlas(io.StringIO(atlas_text(header=V2_HEADER.replace('"2"', "2"))))
    with pytest.raises(atlasio.AtlasFormatError, match="missing"):
        atlasio.open_atlas(io.StringIO(atlas_text(header='{"description":"d"}')))


# --- API ------------------------------------------------------------------------------------------------

def test_raw_districting_is_atlasio_jl_v1_form():
    """raw_districting() rebuilds the exact key strings AtlasIO.jl wrote in the v1 files, from either version."""
    for name in ["edge.jsonl", "edge_float.jsonl"]:
        with open(os.path.join(V1DIR, name), encoding="utf-8") as f:
            raw_v1 = [{k: v for e in json.loads(l)["districting"] for k, v in e.items()}
                      for l in f.read().split("\n")[3:] if l]
        for path in [os.path.join(V1DIR, name), os.path.join(V2DIR, name)]:
            _, maps = read_all(path)
            assert [m.raw_districting() for m in maps] == raw_v1


def test_district_key_helpers():
    for key in [("A",), ("MECKLENBURG", "052"), ('q"', "b\\s"), ("中文", "😀"), ("x, y",), ()]:
        s = atlasio.district_key_string(key)
        assert atlasio.parse_district_key(s) == key
        assert s == json.dumps(list(key), ensure_ascii=False)
    assert atlasio.parse_district_key('["B","p1"]') == ("B", "p1")
    assert atlasio.parse_district_key('["DO\\u00d1A ANA"]') == ("DOÑA ANA",)


def test_open_atlas_accepts_files_and_paths(tmp_path):
    path = os.path.join(V2DIR, "spec_examples.jsonl")
    _, expected = read_all(path)
    with open(path, "rb") as f:                      # binary file object, left open by close()
        atlas = atlasio.open_atlas(f)
        assert [m.districting for m in atlas] == [m.districting for m in expected]
        atlas.close()
        assert not f.closed
    gz = tmp_path / "x.jsonl.gz"
    with open(path, "rb") as f:
        gz.write_bytes(gzip.compress(f.read()))
    _, maps = read_all(gz)                           # a pathlib.Path
    assert [m.name for m in maps] == [m.name for m in expected]


def test_next_map_returns_none_at_end():
    atlas = atlasio.open_atlas(io.StringIO(atlas_text(map_line('{"A":1}'))))
    assert atlas.next_map().districting == {("A",): 1}
    assert atlas.next_map() is None
    assert atlas.next_map() is None


def test_works_with_the_standard_json_module(monkeypatch):
    monkeypatch.setattr(atlasio, "_loads", json.loads)
    _, maps = read_all(os.path.join(V2DIR, "edge.jsonl"))
    assert maps[0].data["ints"][0] == 2**63 - 1
