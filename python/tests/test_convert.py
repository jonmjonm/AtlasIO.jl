"""Tests for atlasio.convert and ``python -m atlasio convert`` against the shared fixtures (test/fixtures/)."""
import bz2
import gzip
import json
import os

import pytest

import atlasio
from atlasio.__main__ import main
from atlasio._convert import _last_top_level_key_start

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
V1DIR = os.path.join(REPO, "test", "fixtures", "v1")
V2DIR = os.path.join(REPO, "test", "fixtures", "v2")
NC = os.path.join(REPO, "ExampleAtlas", "atlas_truncated_nc_multiscale.jsonl")
with open(os.path.join(V1DIR, "expected.json"), encoding="utf-8") as f:
    V1EXP = json.load(f)
FIXTURES = sorted(V1EXP["fixtures"])


def text(path):
    opener = {".gz": gzip.open, ".bz2": bz2.open}.get(os.path.splitext(path)[1], open)
    with opener(path, "rt", encoding="utf-8", newline="\n") as f:
        return f.read()


def maps(path):
    with atlasio.open_atlas(path) as a:
        return list(a)


@pytest.mark.parametrize("name", FIXTURES)
def test_v1_to_v2_gives_exactly_the_v2_twin(name, tmp_path):
    out = str(tmp_path / ("to2_" + name))
    assert atlasio.convert(os.path.join(V1DIR, name), out, 2) == len(V1EXP["fixtures"][name]["maps"])
    assert text(out) == text(os.path.join(V2DIR, name))


@pytest.mark.parametrize("name", FIXTURES + ["spec_examples.jsonl"])
def test_v2_to_v1_to_v2_is_lossless(name, tmp_path):
    v1, again = str(tmp_path / ("to1_" + name)), str(tmp_path / ("again2_" + name))
    atlasio.convert(os.path.join(V2DIR, name), v1, 1)
    atlasio.convert(v1, again, "2")
    assert text(again) == text(os.path.join(V2DIR, name))
    assert [m.districting for m in maps(v1)] == [m.districting for m in maps(os.path.join(V2DIR, name))]
    if name in V1EXP["fixtures"]:
        assert text(v1).split("\n")[:3] == text(os.path.join(V1DIR, name)).split("\n")[:3]
        assert [m.data for m in maps(v1)] == [m.data for m in maps(os.path.join(V1DIR, name))]


def test_v1_output_uses_atlasio_jl_key_strings_in_sorted_order(tmp_path):
    out = str(tmp_path / "spec_v1.jsonl")
    atlasio.convert(os.path.join(V2DIR, "spec_examples.jsonl"), out, 1)
    line = text(out).split("\n")[4]                                    # the "three levels" map
    assert line.endswith('"districting":[{"[\\"MECKLENBURG\\", \\"CHARLOTTE\\", \\"052\\"]":13},'
                         '{"[\\"MECKLENBURG\\", \\"CHARLOTTE\\", \\"074\\"]":14},'
                         '{"[\\"MECKLENBURG\\", \\"DAVIDSON\\"]":12},{"[\\"WAKE\\"]":3}]}')
    assert '"formatVersion"' not in text(out).split("\n")[1]


def test_nc_both_ways_across_compressions(tmp_path):
    v2gz, v1bz = str(tmp_path / "nc.jsonl.gz"), str(tmp_path / "nc.jsonl.bz2")
    assert atlasio.convert(NC, v2gz, 2) == 20
    # The NC file has no final newline; convert ends every line, the last included, with one.
    assert text(v2gz) == text(os.path.join(V2DIR, "nc_truncated.jsonl.gz")) + "\n"
    assert atlasio.convert(v2gz, v1bz, 1) == 20
    assert [m.districting for m in maps(v1bz)] == [m.districting for m in maps(NC)]


def test_same_version_is_a_plain_copy(tmp_path):
    out = str(tmp_path / "same.jsonl")
    atlasio.convert(os.path.join(V2DIR, "spec_examples.jsonl"), out, 2)
    assert text(out) == text(os.path.join(V2DIR, "spec_examples.jsonl"))


V1_HEADER = '{"description":"d","date":"t","atlasParamType":"A","mapParamType":"M"}'


def write_v1(tmp_path, *lines):
    p = tmp_path / "in.jsonl"
    p.write_text("\n".join(['"banner"', V1_HEADER, "{}"] + list(lines)) + "\n", encoding="utf-8")
    return str(p)


@pytest.mark.parametrize("lines, match", [
    (['{"name":"ok","weight":1,"data":{},"districting":[{"[\\"A\\"]":1}]}',
      '{"name":"both","weight":1,"data":{},"districting":[{"[\\"A\\"]":1},{"[\\"A\\", \\"b\\"]":2}]}'],
     r'line 5 \(map "both"\).*prefix'),
    (['{"name":"x","weight":1,"data":{},"assignment":{"A":1}}'], r'line 4.*has no "districting"'),
    (['{"name":"x","districting":[],"weight":1,"data":{}}'], "last field"),
    (['{oops'], "line 4.*JSON"),
])
def test_errors_name_the_line_and_remove_dst(tmp_path, lines, match):
    out = str(tmp_path / "out.jsonl")
    with pytest.raises(atlasio.AtlasFormatError, match=match):
        atlasio.convert(write_v1(tmp_path, *lines), out, 2)
    assert not os.path.exists(out)


def test_bad_arguments(tmp_path):
    src = os.path.join(V2DIR, "spec_examples.jsonl")
    with pytest.raises(ValueError):
        atlasio.convert(src, src, 1)
    for v in (3, "3", 0, True, None, 2.0):
        with pytest.raises(ValueError):
            atlasio.convert(src, str(tmp_path / "x.jsonl"), v)


def test_header_edit_keeps_other_bytes(tmp_path):
    from atlasio._convert import _convert_header
    assert _convert_header('{"formatVersion":"2","description":"d"}', "1") == ("2", '{"description":"d"}')
    assert _convert_header('{"a":"1", "formatVersion": "1", "b":"x"}', "2") == \
        ("1", '{"a":"1", "formatVersion":"2", "b":"x"}')
    assert _convert_header('{"a": "1", "b": "x"}', "2") == ("1", '{"a": "1", "b": "x","formatVersion":"2"}')


def test_last_top_level_key_start():
    for s, key in [('{"a":1,"b":{"c":2}}', '"b"'), ('{"a":"x\\",\\"y\\":1","z":[{"q":1}]}', '"z"'),
                   ('{ "a" : 1 , "last" : {} }', '"last"'), ('{"only":[1,2,{"k":"v"}]}', '"only"')]:
        i = _last_top_level_key_start(s)
        assert s[i:i + len(key)] == key


def test_command_line(tmp_path, capsys):
    out = str(tmp_path / "cli.jsonl.gz")
    assert main(["convert", os.path.join(V1DIR, "edge.jsonl"), out, "--to", "2"]) == 0
    assert "converted 4 maps to format v2" in capsys.readouterr().out
    assert text(out) == text(os.path.join(V2DIR, "edge.jsonl"))
    bad = write_v1(tmp_path, '{"name":"x","weight":1,"data":{},"assignment":{"A":1}}')
    assert main(["convert", bad, str(tmp_path / "o.jsonl"), "--to", "2"]) == 1
    assert "has no" in capsys.readouterr().err
