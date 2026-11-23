"""How the original reader, PythonReader/AtlasIO.py, reads format v2 (test/fixtures/v2/, see make_v2_fixtures.py).

AtlasIO.py keeps raw string district keys. On a v2 file it builds them in the form AtlasIO.jl writes in v1, so
code written for it (helper_functions.get_node_to_district) works unchanged on v2 files. Also checks that the
reader as released in AtlasIO v0.2.0, which predates v2, fails loudly (KeyError) instead of misreading.
"""
import importlib.util
import json
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import AtlasIO  # noqa: E402

REPO = os.path.normpath(os.path.join(HERE, ".."))
V1DIR = os.path.join(REPO, "test", "fixtures", "v1")
V2DIR = os.path.join(REPO, "test", "fixtures", "v2")
with open(os.path.join(V1DIR, "expected.json"), encoding="utf-8") as f:
    V1EXP = json.load(f)
with open(os.path.join(V2DIR, "expected.json"), encoding="utf-8") as f:
    V2EXP = json.load(f)


def read_all(path, module=AtlasIO):
    atlas = module.openAtlas(path)
    maps = []
    while True:
        m = module.nextMap(atlas)
        if m is None:
            break
        maps.append(m)
    module.closeAtlas(atlas)
    return atlas, maps


def tuple_keys(districting):
    # strict=False: a name with a control character (spec rule 4) is raw inside a v1-style key string.
    return {tuple(json.loads(k, strict=False)): v for k, v in districting.items()}


def v1_source(name):
    source = V2EXP["twins"][name]
    if source == "nc_truncated":
        return os.path.join(REPO, V1EXP["nc_truncated"]["path"]), V1EXP["nc_truncated"]
    return os.path.join(V1DIR, name), V1EXP["fixtures"][source]


@pytest.mark.parametrize("name", sorted(V2EXP["twins"]))
def test_v2_twin_reads_like_its_v1_source(name):
    v1path, exp = v1_source(name)
    atlas, maps = read_all(os.path.join(V2DIR, name))
    _, v1maps = read_all(v1path)
    assert atlas.formatVersion == "2"
    assert atlas.description == exp["header"]["description"]
    assert atlas.atlasParam == exp["atlasParam"]
    assert [(m.name, m.weight, m.data) for m in maps] == [(m.name, m.weight, m.data) for m in v1maps]
    if name.startswith("python_written"):
        # Written by Python's json with \\u escapes: same keys, but not AtlasIO.jl's key strings.
        assert [tuple_keys(m.districting) for m in maps] == [tuple_keys(m.districting) for m in v1maps]
    else:
        # Written by AtlasIO.jl: the raw key strings are exactly the ones in the v1 file.
        assert [m.districting for m in maps] == [m.districting for m in v1maps]


def test_v2_spec_examples():
    _, maps = read_all(os.path.join(V2DIR, "spec_examples.jsonl"))
    for m, em in zip(maps, V2EXP["spec_examples"]["maps"]):
        assert tuple_keys(m.districting) == {tuple(k): v for k, v in em["districting"]}
    assert maps[1].districting == {'["WAKE"]': 3, '["MECKLENBURG", "DAVIDSON"]': 12,
                                   '["MECKLENBURG", "CHARLOTTE", "052"]': 13, '["MECKLENBURG", "CHARLOTTE", "074"]': 14}


V2_HEADER = '{"description":"d","date":"t","atlasParamType":"A","mapParamType":"M","formatVersion":"2"}'


def write_atlas(tmp_path, *lines, header=V2_HEADER):
    p = tmp_path / "a.jsonl"
    p.write_text("\n".join(['"banner"', header, "{}"] + list(lines)) + "\n", encoding="utf-8")
    return str(p)


def map_line(assignment):
    return '{"name":"x","weight":1,"data":{},"assignment":%s}' % assignment


@pytest.mark.parametrize("assignment", ['{"A":{}}', '{"A":{"t":{}}}', '{"A":true}', '{"A":2.0}', '{"A":"2"}',
                                        '{"A":null}', '{"A":[2]}', "[]"])
def test_v2_rejects_what_the_spec_forbids(tmp_path, assignment):
    atlas = AtlasIO.openAtlas(write_atlas(tmp_path, map_line(assignment)))
    with pytest.raises(AtlasIO.AtlasFormatError):
        AtlasIO.nextMap(atlas)
    AtlasIO.closeAtlas(atlas)


def test_one_version_per_file(tmp_path):
    v1line = '{"name":"old","weight":1,"data":{},"districting":[{"[\\"A\\"]":1}]}'
    atlas = AtlasIO.openAtlas(write_atlas(tmp_path, v1line))
    with pytest.raises(AtlasIO.AtlasFormatError, match="one version only"):
        AtlasIO.nextMap(atlas)
    AtlasIO.closeAtlas(atlas)


def test_unknown_format_version(tmp_path):
    with pytest.raises(AtlasIO.AtlasFormatError, match='formatVersion "3"'):
        AtlasIO.openAtlas(write_atlas(tmp_path, header=V2_HEADER.replace('"2"', '"3"')))


def test_helper_accepts_raw_and_tuple_keys():
    pytest.importorskip("numpy")                                        # helper_functions imports numpy
    import helper_functions as hf
    nodes = [{"id": 1, "county": "WAKE", "prec_id": "01"},
             {"id": 2, "county": "MECKLENBURG", "prec_id": "052"},
             {"id": 3, "county": "MECKLENBURG", "prec_id": "074"}]
    _, maps = read_all(os.path.join(V2DIR, "spec_examples.jsonl"))
    raw = maps[0].districting                                           # AtlasIO.py: raw key strings
    want = {1: 3, 2: 13, 3: 14}
    assert hf.get_node_to_district(raw, nodes) == want
    assert hf.get_node_to_district(tuple_keys(raw), nodes) == want     # atlasio package: tuple keys
    compact = {k.replace('", "', '","'): v for k, v in raw.items()}    # other spacing now matches too
    assert hf.get_node_to_district(compact, nodes) == want


def test_reader_from_v0_2_0_fails_loudly_on_v2():
    """The spec's promise: the reader released before v2 stops with KeyError('districting'), never misreads."""
    path = os.path.join(REPO, "test", "compat", "python_reader_0_2_0", "AtlasIO.py")
    spec = importlib.util.spec_from_file_location("AtlasIO_v0_2_0", path)
    old = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(old)
    for name in ["edge.jsonl", "edge.jsonl.gz", "spec_examples.jsonl", "nc_truncated.jsonl.gz"]:
        atlas = old.openAtlas(os.path.join(V2DIR, name))         # the header opens
        with pytest.raises(KeyError, match="districting"):
            old.nextMap(atlas)
        old.closeAtlas(atlas)
