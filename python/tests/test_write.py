"""Tests for atlasio.new_atlas / AtlasWriter / map_json, against the shared fixtures (test/fixtures/)."""
import bz2
import gzip
import io
import json
import math
import os
import re

import pytest

import atlasio
from atlasio._convert import _last_top_level_key_start

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
V1DIR = os.path.join(REPO, "test", "fixtures", "v1")
V2DIR = os.path.join(REPO, "test", "fixtures", "v2")
NC = os.path.join(REPO, "ExampleAtlas", "atlas_truncated_nc_multiscale.jsonl")
with open(os.path.join(V1DIR, "expected.json"), encoding="utf-8") as f:
    FIXTURES = sorted(json.load(f)["fixtures"])
# Fixtures AtlasIO.jl wrote (the others come from other writers, with their own banner or JSON spacing).
JULIA_WRITTEN = [n for n in FIXTURES if n.startswith("edge")]


def text(path):
    opener = {".gz": gzip.open, ".bz2": bz2.open}.get(os.path.splitext(path)[1], open)
    with opener(path, "rt", encoding="utf-8", newline="\n") as f:
        return f.read()


def read(path):
    with atlasio.open_atlas(path) as a:
        return a, list(a)


def rewrite(src, dst, **kw):
    with atlasio.open_atlas(src) as a, atlasio.new_atlas(dst, like=a, **kw) as w:
        w.add_maps(a)
    return w


def same_maps(ms1, ms2):
    assert [(m.name, m.weight, m.data, m.districting) for m in ms1] == \
        [(m.name, m.weight, m.data, m.districting) for m in ms2]


# --- round trips and agreement with AtlasIO.jl ----------------------------------------------------------------

@pytest.mark.parametrize("version", [1, 2])
@pytest.mark.parametrize("name", FIXTURES)
def test_rewrite_keeps_every_map_header_and_params(name, version, tmp_path):
    out = str(tmp_path / ("w%d_" % version + name))
    w = rewrite(os.path.join(V1DIR, name), out, format_version=version)
    a1, m1 = read(os.path.join(V1DIR, name))
    a2, m2 = read(out)
    assert w.count == len(m1) > 0
    assert a2.format_version == str(version)
    for attr in ("description", "date", "atlas_param_type", "map_param_type", "weight_type", "params"):
        assert getattr(a2, attr) == getattr(a1, attr)
    same_maps(m2, m1)


@pytest.mark.parametrize("name", JULIA_WRITTEN)
def test_header_lines_are_byte_identical_to_atlasio_jl(name, tmp_path):
    for d in (V1DIR, V2DIR):
        out = str(tmp_path / ("h_" + name))
        rewrite(os.path.join(d, name), out)
        assert text(out).split("\n")[:3] == text(os.path.join(d, name)).split("\n")[:3]


@pytest.mark.parametrize("name", FIXTURES + ["spec_examples.jsonl", "nc_truncated.jsonl.gz"])
def test_v2_map_lines_match_atlasio_jl(name, tmp_path):
    """The assignment tree is byte-identical to AtlasIO.jl's, and so is the name in the files AtlasIO.jl wrote;
    only the spelling of floats may differ (Python writes 1e-07 where Julia writes 1.0e-7), and they parse to the
    same values."""
    out = str(tmp_path / ("m_" + name))
    rewrite(os.path.join(V2DIR, name), out)
    ours, theirs = text(out).rstrip("\n").split("\n")[3:], text(os.path.join(V2DIR, name)).rstrip("\n").split("\n")[3:]
    assert len(ours) == len(theirs) > 0
    for x, y in zip(ours, theirs):
        assert json.loads(x) == json.loads(y)
        assert x[_last_top_level_key_start(x):] == y[_last_top_level_key_start(y):]       # the assignment
        if name in JULIA_WRITTEN or name == "spec_examples.jsonl":
            assert x.split(',"weight":')[0] == y.split(',"weight":')[0]                    # the name


@pytest.mark.parametrize("name", FIXTURES + ["spec_examples.jsonl"])
def test_v1_districting_is_the_one_convert_writes(name, tmp_path):
    ours, conv = str(tmp_path / "w.jsonl"), str(tmp_path / "c.jsonl")
    rewrite(os.path.join(V2DIR, name), ours, format_version=1)
    atlasio.convert(os.path.join(V2DIR, name), conv, 1)
    for x, y in zip(text(ours).split("\n")[3:], text(conv).split("\n")[3:]):
        assert x[_last_top_level_key_start(x):] == y[_last_top_level_key_start(y):]


def test_nc_both_versions_and_compressions(tmp_path):
    _, maps = read(NC)
    for version, ext in ((1, ".jsonl.bz2"), (2, ".jsonl.gz"), (2, ".jsonl")):
        out = str(tmp_path / ("nc" + ext))
        with atlasio.new_atlas(out, description="nc", params={"n": 20}, format_version=version) as w:
            w.add_maps(maps)
        a, back = read(out)
        assert (a.format_version, a.description, a.params) == (str(version), "nc", {"n": 20})
        same_maps(back, maps)


# --- the API -----------------------------------------------------------------------------------------------------

def test_new_atlas_defaults_and_add_map_forms():
    buf = io.StringIO()
    with atlasio.new_atlas(buf, "demo", {"districts": 2}) as w:
        w.add_map("a", {("WAKE",): 1, ("MECKLENBURG", "052"): 2})
        w.add_map("b", {("WAKE",): 2, ("MECKLENBURG", "052"): 1}, weight=3, data={"score": 0.5})
        w.add_map(atlasio.Map("c", 1, {"x": [1, 2]}, {("WAKE",): 1}))
    lines = buf.getvalue().split("\n")
    assert lines[0] == json.dumps(atlasio._write.BANNER)
    header = json.loads(lines[1])
    assert list(header) == ["description", "date", "atlasParamType", "mapParamType", "weightType"]
    assert header["atlasParamType"] == header["mapParamType"] == "Dict{String, Any}"
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}", header["date"])
    assert lines[3] == '{"name":"a","weight":1,"data":{},"districting":[{"[\\"MECKLENBURG\\", \\"052\\"]":2},' \
                       '{"[\\"WAKE\\"]":1}]}'
    assert lines[-1] == "" and w.count == 3 and w.closed
    assert not buf.closed                       # a file object passed in is left open
    a = atlasio.open_atlas(io.StringIO(buf.getvalue()))
    assert [m.name for m in a] == ["a", "b", "c"]


def test_v2_line_and_map_json():
    m = atlasio.Map("x", 2, {"k": "v"}, {("WAKE",): 3, ("MECKLENBURG", "074"): 14, ("MECKLENBURG", "052"): 13})
    want = '{"name":"x","weight":2,"data":{"k":"v"},"assignment":{"MECKLENBURG":{"052":13,"074":14},"WAKE":3}}'
    assert atlasio.map_json(m, 2) == want
    buf = io.StringIO()
    with atlasio.new_atlas(buf, format_version="2") as w:
        w.add_map(m)
    assert json.loads(buf.getvalue().split("\n")[1])["formatVersion"] == "2"
    assert buf.getvalue().split("\n")[3] == want
    assert atlasio.map_json(m).endswith('"districting":[{"[\\"MECKLENBURG\\", \\"052\\"]":13},'
                                        '{"[\\"MECKLENBURG\\", \\"074\\"]":14},{"[\\"WAKE\\"]":3}]}')


def test_binary_file_object_is_left_open():
    raw = io.BytesIO()
    with gzip.GzipFile(fileobj=raw, mode="wb") as gz:
        with atlasio.new_atlas(gz, "bin") as w:
            w.add_map("m", {("A",): 1})
        assert not gz.closed
    raw.seek(0)
    with gzip.open(raw, "rt", encoding="utf-8") as f:
        a = atlasio.open_atlas(f)
        assert a.description == "bin" and [m.districting for m in a] == [{("A",): 1}]


def test_like_copies_and_arguments_override(tmp_path):
    src = os.path.join(V1DIR, "edge_float.jsonl")
    out = str(tmp_path / "o.jsonl")
    with atlasio.open_atlas(src) as a, atlasio.new_atlas(out, like=a, description="new", format_version=2) as w:
        pass
    b, _ = read(out)
    a, _ = read(src)
    assert (b.description, b.format_version, b.date, b.weight_type, b.params) == \
        ("new", "2", a.date, "Float64", a.params)


def test_float_weights():
    buf = io.StringIO()
    with atlasio.new_atlas(buf, weight_type="Float64") as w:
        w.add_map("i", {("A",): 1}, weight=2)          # written as a float, as AtlasIO.jl writes a Float64
        w.add_map("f", {("A",): 1}, weight=0.25)
    lines = buf.getvalue().split("\n")
    assert '"weight":2.0,' in lines[3] and '"weight":0.25,' in lines[4]
    assert atlasio.map_json(atlasio.Map("f", 0.5, {}, {("A",): 1})).startswith('{"name":"f","weight":0.5,')


def test_numpy_values_are_converted():
    np = pytest.importorskip("numpy")
    buf = io.StringIO()
    with atlasio.new_atlas(buf) as w:
        w.add_map("np", {("A",): np.int64(3), ("B",): np.int32(1)}, weight=np.int64(2),
                  data={"v": np.array([1.5, 2.0]), "s": np.float64(0.25), "n": np.int64(7), "b": np.bool_(True)})
    m = next(iter(atlasio.open_atlas(io.StringIO(buf.getvalue()))))
    assert (m.weight, m.districting, m.data) == (2, {("A",): 3, ("B",): 1},
                                                 {"v": [1.5, 2.0], "s": 0.25, "n": 7, "b": True})


@pytest.mark.parametrize("args, exc, match", [
    (("m", {"WAKE": 1}), TypeError, "is a string; keys are tuples"),
    (("m", {("A", 1): 1}), TypeError, "every name must be a string"),
    (("m", {("A",): True}), TypeError, "must be an integer"),
    (("m", {("A",): 1.0}), TypeError, "must be an integer"),
    (("m", {("A",): 2 ** 63}), ValueError, "64-bit"),
    (("m", [("A", 1)]), TypeError, "must be a dict"),
    (("m",), TypeError, "districting is missing"),
    ((5, {("A",): 1}), TypeError, "name must be a string"),
    (("m", {("A",): 1}, 1.5), TypeError, "weight_type is Int64"),
    (("m", {("A",): 1}, True), TypeError, "weight_type is Int64"),
    (("m", {("A",): 1}, 1, {"x": float("nan")}), ValueError, 'map "m": the map data cannot be written'),
    (("m", {("A",): 1}, 1, {"x": object()}), TypeError, "not JSON serializable"),
])
def test_add_map_rejects_bad_input(args, exc, match):
    with atlasio.new_atlas(io.StringIO()) as w:
        with pytest.raises(exc, match=match):
            w.add_map(*args)
        assert w.count == 0


def test_v2_rejects_what_v2_cannot_hold_and_v1_writes_it():
    both = {("A",): 1, ("A", "b"): 2}
    with atlasio.new_atlas(io.StringIO(), format_version=2) as w:
        with pytest.raises(atlasio.AtlasFormatError,
                           match=r"cannot write format v2: map \"m\": the key \('A',\) is a prefix of the key "
                                 r"\('A', 'b'\).*Write format v1"):
            w.add_map("m", both)
        with pytest.raises(atlasio.AtlasFormatError, match=r"the district key \(\) is empty"):
            w.add_map("e", {(): 1})
    buf = io.StringIO()
    with atlasio.new_atlas(buf) as w:
        w.add_map("m", both)
    assert next(iter(atlasio.open_atlas(io.StringIO(buf.getvalue())))).districting == both


def test_bad_header_arguments_and_closed_writer(tmp_path):
    for kw in ({"format_version": 3}, {"format_version": True}, {"weight_type": "Int32"}):
        with pytest.raises(ValueError):
            atlasio.new_atlas(io.StringIO(), **kw)
    with pytest.raises(TypeError, match="must be a string"):
        atlasio.new_atlas(io.StringIO(), date=20261123)
    out = tmp_path / "nan.jsonl.gz"
    with pytest.raises(ValueError, match="atlas parameters"):
        atlasio.new_atlas(str(out), params={"x": math.inf})
    assert not out.exists()                     # no half-written file is left
    w = atlasio.new_atlas(io.StringIO())
    w.close()
    w.close()                                   # closing twice is fine
    with pytest.raises(ValueError, match="closed"):
        w.add_map("m", {("A",): 1})
    with pytest.raises(TypeError, match="takes a Map alone"):
        atlasio.new_atlas(io.StringIO()).add_map(atlasio.Map("m", 1, {}, {("A",): 1}), {("A",): 1})
