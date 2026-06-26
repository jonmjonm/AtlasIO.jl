import sys
import os
import pytest

sys.path.insert(0, os.path.dirname(__file__))
import AtlasIO

TEST_DIR   = os.path.join(os.path.dirname(__file__), '..', 'test')
ATLAS_PLAIN = os.path.join(TEST_DIR, 'test.jsonl')
ATLAS_GZ    = os.path.join(TEST_DIR, 'test.jsonl.gz')

TOTAL_MAPS = 14

# Keys are raw JSON-array strings (not parsed tuples) — space after each comma matches
# how Julia serialises the keys when writing the test file.
FIRST_MAP_DISTRICTING = {
    '["p2", "c2"]':         1,
    '["p1", "c2"]':         1,
    '["p3", "c7", "b100"]': 2,
}


@pytest.fixture
def atlas():
    a = AtlasIO.openAtlas(ATLAS_PLAIN)
    yield a
    AtlasIO.closeAtlas(a)


@pytest.fixture
def atlas_gz():
    a = AtlasIO.openAtlas(ATLAS_GZ)
    yield a
    AtlasIO.closeAtlas(a)


# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

def test_header_description(atlas):
    assert atlas.description == "Test Atlas"

def test_header_date(atlas):
    assert atlas.date == "2021-08-04T08:58:22.216"

def test_header_atlas_param_type(atlas):
    assert atlas.atlasParamType == "Dict{String, Int64}"

def test_header_map_param_type(atlas):
    assert atlas.mapParamType == "Dict{String, Int64}"

def test_header_atlas_param_county(atlas):
    assert atlas.atlasParam["county"] == 2

def test_header_atlas_param_gamama(atlas):
    assert atlas.atlasParam["gamama"] == 4


# ---------------------------------------------------------------------------
# Map fields
# ---------------------------------------------------------------------------

def test_map1_name(atlas):
    m = AtlasIO.nextMap(atlas)
    assert m.name == "map1"

def test_map1_weight(atlas):
    m = AtlasIO.nextMap(atlas)
    assert m.weight == 1

def test_map1_data(atlas):
    m = AtlasIO.nextMap(atlas)
    assert m.data["param"] == 2
    assert m.data["trees"] == 4

def test_map1_districting_size(atlas):
    m = AtlasIO.nextMap(atlas)
    assert len(m.districting) == 3

def test_map1_districting_values(atlas):
    m = AtlasIO.nextMap(atlas)
    assert m.districting == FIRST_MAP_DISTRICTING

def test_map1_districting_key_format(atlas):
    # Keys are raw JSON-array strings — a 3-level hierarchical key must be preserved as-is
    m = AtlasIO.nextMap(atlas)
    assert '["p3", "c7", "b100"]' in m.districting

def test_map2_name(atlas):
    AtlasIO.nextMap(atlas)          # skip map1
    m = AtlasIO.nextMap(atlas)
    assert m.name == "map2"

def test_map2_districting_differs(atlas):
    AtlasIO.nextMap(atlas)
    m = AtlasIO.nextMap(atlas)
    assert m.districting['["p2", "c2"]'] == 2  # map2 differs from map1 here

def test_weighted_map(atlas):
    # map-10 is the 4th map and carries weight 10
    for _ in range(3):
        AtlasIO.nextMap(atlas)
    m = AtlasIO.nextMap(atlas)
    assert m.name == "map-10"
    assert m.weight == 10


# ---------------------------------------------------------------------------
# EOF
# ---------------------------------------------------------------------------

def test_eof_returns_none(atlas):
    count = 0
    while True:
        m = AtlasIO.nextMap(atlas)
        if m is None:
            break
        count += 1
    assert count == TOTAL_MAPS


# ---------------------------------------------------------------------------
# Gzip
# ---------------------------------------------------------------------------

def test_gz_header_description(atlas_gz):
    assert atlas_gz.description == "Test Atlas"

def test_gz_first_map_name(atlas_gz):
    m = AtlasIO.nextMap(atlas_gz)
    assert m.name == "map1"

def test_gz_first_map_districting(atlas_gz):
    m = AtlasIO.nextMap(atlas_gz)
    assert m.districting == FIRST_MAP_DISTRICTING

def test_gz_eof(atlas_gz):
    count = 0
    while True:
        m = AtlasIO.nextMap(atlas_gz)
        if m is None:
            break
        count += 1
    assert count == TOTAL_MAPS


# ---------------------------------------------------------------------------
# Close
# ---------------------------------------------------------------------------

def test_close_atlas():
    a = AtlasIO.openAtlas(ATLAS_PLAIN)
    AtlasIO.closeAtlas(a)
    assert a.fp.closed
