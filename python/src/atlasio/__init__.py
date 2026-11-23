"""atlasio: read and write Atlas files (redistricting map ensembles) in Python, and convert between format versions.

An Atlas file holds one header and then one district map per line; the format is described in
https://github.com/jonmjonm/AtlasIO.jl/blob/main/atlas_format.md. This package reads and writes format versions 1
and 2, plain or compressed (.gz, .bz2), and converts files between the two versions (``convert``, or
``python -m atlasio convert SRC DST --to 2`` on the command line).

    import atlasio

    with atlasio.open_atlas("atlas.jsonl.gz") as atlas:
        print(atlas.description, atlas.format_version, atlas.params)
        for m in atlas:
            m.name, m.weight, m.data
            m.districting[("MECKLENBURG", "052")]   # district keys are tuples, as in AtlasIO.jl

    with atlasio.new_atlas("out.jsonl.gz", description="my ensemble", params={"districts": 14}) as out:
        out.add_map("map1", {("WAKE",): 3, ("MECKLENBURG", "052"): 13}, weight=1, data={"score": 0.5})

Only the standard library is needed. If the optional ``orjson`` package is installed it is used to parse
lines faster (any line orjson refuses, such as one with NaN, falls back to the standard json module).
"""
import bz2
import gzip
import json
import os
import re

__version__ = "0.2.3"

__all__ = ["open_atlas", "Atlas", "Map", "AtlasFormatError", "parse_map", "parse_district_key",
           "district_key_string", "new_atlas", "AtlasWriter", "map_json", "convert", "FORMAT_VERSIONS",
           "__version__"]

#: The Atlas format versions this package reads and writes.
FORMAT_VERSIONS = ("1", "2")

_REQUIRED_HEADER = ("description", "date", "atlasParamType", "mapParamType")

try:  # optional speed-up
    import orjson as _orjson

    def _loads(s):
        try:
            return _orjson.loads(s)
        except _orjson.JSONDecodeError:
            return json.loads(s)   # e.g. NaN or integers beyond 64 bits, which the json module accepts
except ImportError:  # pragma: no cover - depends on the environment
    _loads = json.loads


class AtlasFormatError(ValueError):
    """The file or line is not a valid Atlas (or uses a format version this package does not read)."""


class Map:
    """One map: ``name``, ``weight``, ``data`` and ``districting``.

    ``districting`` maps each region's key, a tuple of names from the coarsest level down, such as
    ``("WAKE",)`` or ``("MECKLENBURG", "052")``, to its district number. It is the same for a map read from a
    v1 file and from a v2 file.
    """
    __slots__ = ("name", "weight", "data", "districting")

    def __init__(self, name, weight, data, districting):
        self.name = name
        self.weight = weight
        self.data = data
        self.districting = districting

    def raw_districting(self):
        """The districting with v1-style string keys, e.g. ``'["MECKLENBURG", "052"]'``, as AtlasIO.jl writes
        them (see :func:`district_key_string`). For code written for the old PythonReader/AtlasIO.py."""
        return {district_key_string(k): v for k, v in self.districting.items()}

    def __repr__(self):
        return "Map(name=%r, weight=%r, %d regions)" % (self.name, self.weight, len(self.districting))


class Atlas:
    """An Atlas open for reading. Iterate over it (or call :meth:`next_map`) to read its maps in order.

    Attributes: ``description``, ``date``, ``atlas_param_type``, ``map_param_type``, ``weight_type``
    (``"Int64"`` or ``"Float64"``), ``format_version`` (``"1"`` or ``"2"``), ``header`` (the whole header as a
    dict) and ``params`` (the atlas parameters, line 3).
    """

    def __init__(self, f, close_file=True):
        self._f = f
        self._close_file = close_file
        try:
            f.readline()                                   # line 1: banner, ignored
            header_line = f.readline()
            params_line = f.readline()
        except (OSError, EOFError) as e:
            raise AtlasFormatError("not a valid Atlas file: failed to read the header (%s)" % e) from e
        try:
            header = _loads(header_line)
        except ValueError as e:
            raise AtlasFormatError("not a valid Atlas file: the header line (line 2) did not parse as JSON "
                                   "(%s)" % e) from e
        if not isinstance(header, dict):
            raise AtlasFormatError("not a valid Atlas file: the header line (line 2) is not a JSON object")
        for k in _REQUIRED_HEADER:
            if k not in header:
                raise AtlasFormatError('not a valid Atlas file: the header line (line 2) is missing "%s"' % k)
        for k, v in header.items():
            if not isinstance(v, str):
                raise AtlasFormatError('not a valid Atlas file: the header value of "%s" must be a JSON string, '
                                       "not %r" % (k, v))
        self.format_version = header.get("formatVersion", "1")
        if self.format_version not in FORMAT_VERSIONS:
            raise AtlasFormatError('unsupported Atlas formatVersion "%s": atlasio %s reads format versions %s. '
                                   "Upgrade atlasio to read this file."
                                   % (self.format_version, __version__, " and ".join(FORMAT_VERSIONS)))
        self.header = header
        self.description = header["description"]
        self.date = header["date"]
        self.atlas_param_type = header["atlasParamType"]
        self.map_param_type = header["mapParamType"]
        self.weight_type = header.get("weightType", "Int64")
        try:
            self.params = _loads(params_line)
        except ValueError as e:
            raise AtlasFormatError("not a valid Atlas file: the atlas-parameters line (line 3) did not parse "
                                   "as JSON (%s)" % e) from e

    def next_map(self):
        """The next map, or ``None`` at the end of the file."""
        line = self._f.readline()
        if not line:
            return None
        return _parse_map(line, self.format_version)

    def __iter__(self):
        while True:
            m = self.next_map()
            if m is None:
                return
            yield m

    def close(self):
        if self._close_file:
            self._f.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def __repr__(self):
        return "Atlas(description=%r, format_version=%r)" % (self.description, self.format_version)


def open_atlas(source):
    """Open an Atlas file for reading.

    ``source`` is a path (``.jsonl``, ``.jsonl.gz`` or ``.jsonl.bz2``; the compression is chosen by the
    extension) or an already open file object (text or binary), which is then left open on ``close``.
    """
    if hasattr(source, "readline"):
        return Atlas(source, close_file=False)
    path = os.fspath(source)
    if path.endswith(".gz"):
        f = gzip.open(path, "rt", encoding="utf-8", newline="\n")
    elif path.endswith(".bz2"):
        f = bz2.open(path, "rt", encoding="utf-8", newline="\n")
    else:
        f = open(path, "r", encoding="utf-8", newline="\n")
    try:
        return Atlas(f)
    except BaseException:
        f.close()
        raise


def parse_map(line):
    """Parse one map line, in either format version, into a :class:`Map`."""
    return _parse_map(line, None)


def _map_name(x):
    n = x.get("name") if isinstance(x, dict) else None
    return ' (map "%s")' % n if isinstance(n, str) else ""


def _parse_map(line, version):
    try:
        x = _loads(line)
    except ValueError as e:
        raise AtlasFormatError("not a valid Atlas map line: failed to parse as JSON (%s)" % e) from e
    if not isinstance(x, dict):
        raise AtlasFormatError("not a valid Atlas map line: a map line must be a JSON object")
    has_v1, has_v2 = "districting" in x, "assignment" in x
    if not (has_v1 or has_v2):
        raise AtlasFormatError('map line has neither "districting" (v1) nor "assignment" (v2)' + _map_name(x))
    if has_v1 and has_v2:
        raise AtlasFormatError('map line has both "districting" (v1) and "assignment" (v2)' + _map_name(x))
    if version is not None and (version == "2") != has_v2:
        raise AtlasFormatError('map line has %s but the header declares formatVersion "%s"%s; a file holds maps '
                               "of one version only" % ('"assignment" (v2)' if has_v2 else '"districting" (v1)',
                                                        version, _map_name(x)))
    for k in ("name", "weight", "data"):
        if k not in x:
            raise AtlasFormatError('not a valid Atlas map line: missing "%s"%s' % (k, _map_name(x)))
    if has_v2:
        districting = _from_assignment(x["assignment"], x)
    else:
        districting = _from_v1(x["districting"], x)
    return Map(x["name"], x["weight"], x["data"], districting)


def _from_v1(entries, x):
    if not isinstance(entries, list):
        raise AtlasFormatError('"districting" must be a JSON array' + _map_name(x))
    d = {}
    for entry in entries:
        for k, v in entry.items():
            d[parse_district_key(k)] = v
    return d


def _from_assignment(tree, x):
    if not isinstance(tree, dict):
        raise AtlasFormatError('"assignment" must be a JSON object' + _map_name(x))
    d = {}
    stack = [((), tree)]
    while stack:
        prefix, node = stack.pop()
        for name, v in node.items():
            key = prefix + (name,)
            if type(v) is int:                      # bool is a subclass of int; it is rejected below
                d[key] = v
            elif isinstance(v, dict):
                if not v:
                    raise AtlasFormatError('empty branch at key %r in "assignment": a split region must have at '
                                           "least one sub-region%s" % (key, _map_name(x)))
                stack.append((key, v))
            else:
                raise AtlasFormatError('the value at key %r in "assignment" is %r; it must be an integer district '
                                       "or an object of sub-regions%s" % (key, v, _map_name(x)))
    return d


_SIMPLE_KEY_PART = re.compile(r'"([^"\\]*)"')


def parse_district_key(s):
    """Decode a v1 district-key string such as ``'["MECKLENBURG", "052"]'`` into ``("MECKLENBURG", "052")``."""
    if "\\" not in s:
        # No escapes, so no quote inside a name: every quoted run is one name, whatever the spacing.
        return tuple(_SIMPLE_KEY_PART.findall(s))
    parts = json.loads(s)
    if not (isinstance(parts, list) and all(isinstance(p, str) for p in parts)):
        raise AtlasFormatError("district key %r is not a JSON array of strings" % s)
    return tuple(parts)


def district_key_string(key):
    """The v1 district-key string for ``key`` exactly as AtlasIO.jl writes it: a JSON-style list with ``", "``
    between names, escaping only ``"`` and ``\\``; e.g. ``("MECKLENBURG", "052")`` -> ``'["MECKLENBURG", "052"]'``."""
    return "[" + ", ".join('"' + p.replace("\\", "\\\\").replace('"', '\\"') + '"' for p in key) + "]"


from ._write import AtlasWriter, map_json, new_atlas  # noqa: E402  (after the definitions they use)
from ._convert import convert  # noqa: E402
