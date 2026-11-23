"""Write Atlas files (atlas_format.md), format version 1 or 2, laid out as AtlasIO.jl's newAtlas/addMap write them.

Also holds the districting encoders that ``convert`` shares, so a map written here and the same map converted (or
written by AtlasIO.jl) have byte-identical assignments.
"""
import bz2
import datetime
import gzip
import io
import json
import math
import numbers
import operator
import os
from collections.abc import Mapping

from . import AtlasFormatError, Map, district_key_string

#: Line 1 of every Atlas file, exactly as AtlasIO.jl writes it.
BANNER = ("This is an Atlas for Redistricting Maps. See "
          "'https://github.com/jonmjonm/AtlasIO.jl/blob/main/atlas_format.md' for more information about the format.")

#: The parameter type name AtlasIO.jl writes for plain dictionaries (Julia's ``string(Dict{String,Any})``).
DEFAULT_PARAM_TYPE = "Dict{String, Any}"

WEIGHT_TYPES = ("Int64", "Float64")

_INT64_MIN, _INT64_MAX = -2 ** 63, 2 ** 63 - 1


def _version(v):
    """Normalize a format version given as 1, 2, '1' or '2' to the header's string form."""
    s = v if isinstance(v, str) else (str(v) if isinstance(v, int) and not isinstance(v, bool) else "")
    if s not in ("1", "2"):
        raise ValueError("format version must be 1 or 2 (or '1' or '2'), got %r" % (v,))
    return s


# ---------------------------------------------------------------------------------------------------------------
# Encoders (shared with convert)

def _districting_v1(d):
    """The v1 ``districting`` array for ``d`` ({key tuple: district}), entries in sorted key order."""
    return "[" + ",".join("{%s:%d}" % (json.dumps(district_key_string(k), ensure_ascii=False), d[k])
                          for k in sorted(d)) + "]"


def _assignment_json(d, err, hint=""):
    """The v2 ``assignment`` tree for ``d`` ({key tuple: district}), names sorted at every level.

    A districting v2 cannot hold raises AtlasFormatError: ``err`` starts the message, ``hint`` ends it.
    """
    tree = {}
    for k, v in d.items():
        if not k:
            raise AtlasFormatError("%sthe district key () is empty; a v2 key names at least one region%s"
                                   % (err, hint))
        node = tree
        for i, part in enumerate(k[:-1]):
            child = node.setdefault(part, {})
            if not isinstance(child, dict):
                _prefix_error(err, hint, k[:i + 1], k)
            node = child
        if k[-1] in node:
            _prefix_error(err, hint, k, _some_key_under(k, node[k[-1]]))
        node[k[-1]] = v
    # sort_keys sorts by code point, the UTF-8 byte order the spec asks for
    return json.dumps(tree, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def _some_key_under(prefix, node):
    while isinstance(node, dict):
        name = min(node)
        prefix, node = prefix + (name,), node[name]
    return prefix


def _prefix_error(err, hint, short, long):
    raise AtlasFormatError("%sthe key %r is a prefix of the key %r, so the region would be both whole and split "
                           "(rule 1 of atlas_format.md)%s" % (err, tuple(short), tuple(long), hint))


def _json_default(o):
    # numpy scalars and arrays (and anything else with .tolist()) become plain Python values
    if hasattr(o, "tolist"):
        return o.tolist()
    raise TypeError("%s is not JSON serializable" % type(o).__name__)


def _dumps(x):
    return json.dumps(x, ensure_ascii=False, separators=(",", ":"), allow_nan=False, default=_json_default)


# ---------------------------------------------------------------------------------------------------------------
# Checking what the caller passes

def _for_map(name):
    return 'map "%s": ' % name if name else ""


def _check_districting(d, name):
    """``d`` as {tuple of str: int}, or TypeError/ValueError saying what is wrong."""
    if not isinstance(d, Mapping):
        raise TypeError("%sthe districting must be a dict of {key tuple: district}, not %s"
                        % (_for_map(name), type(d).__name__))
    out = {}
    for k, v in d.items():
        if type(k) is not tuple:
            if isinstance(k, (str, bytes)):
                raise TypeError("%sdistrict key %r is a string; keys are tuples of names from the coarsest level "
                                "down, e.g. ('WAKE',) or ('MECKLENBURG', '052')" % (_for_map(name), k))
            try:
                k = tuple(k)
            except TypeError:
                raise TypeError("%sdistrict key %r is not a tuple of names" % (_for_map(name), k)) from None
        for p in k:
            if not isinstance(p, str):
                raise TypeError("%sdistrict key %r: every name must be a string, not %r" % (_for_map(name), k, p))
        if type(v) is not int:
            if isinstance(v, bool) or not hasattr(v, "__index__"):
                raise TypeError("%sthe district of %r is %r; it must be an integer" % (_for_map(name), k, v))
            v = operator.index(v)          # e.g. a numpy integer
        if not _INT64_MIN <= v <= _INT64_MAX:
            raise ValueError("%sthe district of %r is %d, beyond a 64-bit integer" % (_for_map(name), k, v))
        out[k] = v
    return out


def _check_weight(w, weight_type, name):
    if weight_type == "Int64":
        if isinstance(w, bool) or not hasattr(w, "__index__"):
            raise TypeError("%sthe weight is %r, but this atlas's weight_type is Int64 (pass an integer, or use "
                            "weight_type='Float64')" % (_for_map(name), w))
        w = operator.index(w)
        if not _INT64_MIN <= w <= _INT64_MAX:
            raise ValueError("%sthe weight %d is beyond a 64-bit integer" % (_for_map(name), w))
        return w
    if isinstance(w, bool) or not isinstance(w, numbers.Real):
        raise TypeError("%sthe weight must be a number, not %r" % (_for_map(name), w))
    w = float(w)
    if not math.isfinite(w):
        raise ValueError("%sthe weight is %r; JSON has no NaN or infinity" % (_for_map(name), w))
    return w


def map_json(m, format_version=1, weight_type=None):
    """The JSON line (without the newline) for :class:`Map` ``m`` in format version ``format_version``, as
    :meth:`AtlasWriter.add_map` writes it: fields ``name``, ``weight``, ``data`` and then the assignment
    (``districting`` in v1, ``assignment`` in v2). ``weight_type`` (``"Int64"`` or ``"Float64"``) checks the
    weight and writes a Float64 weight as a float; by default an integer weight is written as Int64 and a float
    one as Float64.
    """
    return _map_json(m.name, m.districting, m.weight, m.data, _version(format_version), weight_type)


def _map_json(name, districting, weight, data, version, weight_type):
    if not isinstance(name, str):
        raise TypeError("the map name must be a string, not %r" % (name,))
    if weight_type is None:
        weight_type = "Float64" if isinstance(weight, float) else "Int64"
    weight = _check_weight(weight, weight_type, name)
    d = _check_districting(districting, name)
    if version == "2":
        field = '"assignment":' + _assignment_json(d, "cannot write format v2: " + _for_map(name),
                                                   ". Write format v1 or fix the districting.")
    else:
        field = '"districting":' + _districting_v1(d)
    try:
        data_json = _dumps({} if data is None else data)
    except ValueError as e:                  # NaN or infinity
        raise ValueError("%sthe map data cannot be written as JSON: %s" % (_for_map(name), e)) from None
    return '{"name":%s,"weight":%s,"data":%s,%s}' % (_dumps(name), _dumps(weight), data_json, field)


# ---------------------------------------------------------------------------------------------------------------
# The writer

class AtlasWriter:
    """An Atlas open for writing, as returned by :func:`new_atlas`; the header is already written. Add maps with
    :meth:`add_map` or :meth:`add_maps`, then :meth:`close` (or use it in a ``with`` block).

    Attributes: ``format_version`` (``"1"`` or ``"2"``), ``weight_type``, ``header`` (the header written, as a
    dict), ``params`` and ``count`` (the number of maps written so far).
    """

    def __init__(self, f, close, header, params):
        self._f = f
        self._close = close
        self.header = header
        self.params = params
        self.format_version = header.get("formatVersion", "1")
        self.weight_type = header["weightType"]
        self.count = 0
        f.write(_dumps(BANNER) + "\n" + _dumps(header) + "\n")
        try:
            f.write(_dumps(params) + "\n")
        except ValueError as e:
            raise ValueError("the atlas parameters cannot be written as JSON: %s" % e) from None

    def add_map(self, map_or_name, districting=None, weight=1, data=None):
        """Write one map: ``add_map(name, districting, weight=1, data=None)``, or ``add_map(m)`` for a
        :class:`Map` (such as one read from another atlas).

        ``districting`` maps each region's key, a tuple of names from the coarsest level down such as
        ``("WAKE",)`` or ``("MECKLENBURG", "052")``, to its integer district. ``data`` is any JSON-serializable
        value (numpy numbers and arrays are converted); ``None`` writes ``{}``. In format v2 a districting with a
        region both whole and split (one key a prefix of another) raises :class:`AtlasFormatError`.
        """
        if self._f is None:
            raise ValueError("add_map: the atlas is closed")
        if isinstance(map_or_name, Map):
            if districting is not None:
                raise TypeError("add_map(m) takes a Map alone; pass add_map(name, districting, ...) otherwise")
            m = map_or_name
            name, districting, weight, data = m.name, m.districting, m.weight, m.data
        else:
            name = map_or_name
            if districting is None:
                raise TypeError("add_map(name, districting, weight=1, data=None): the districting is missing")
        line = _map_json(name, districting, weight, data, self.format_version, self.weight_type)
        self._f.write(line + "\n")
        self.count += 1

    def add_maps(self, maps):
        """Write each :class:`Map` in ``maps``, in order."""
        for m in maps:
            self.add_map(m)

    @property
    def closed(self):
        return self._f is None

    def close(self):
        if self._f is not None:
            f, self._f = self._f, None
            self._close(f)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def __repr__(self):
        return "AtlasWriter(format_version=%r, %d maps%s)" % (self.format_version, self.count,
                                                            ", closed" if self.closed else "")


def new_atlas(dest, description=None, params=None, *, date=None, atlas_param_type=None, map_param_type=None,
              weight_type=None, format_version=None, like=None):
    """Create an Atlas file and write its header; returns an :class:`AtlasWriter` to add maps to.

    ``dest`` is a path (``.jsonl``, ``.jsonl.gz`` or ``.jsonl.bz2``; the compression is chosen by the extension)
    or an open file object (text or binary), which is left open on ``close``.

    The header: ``description`` (default ``""``), ``date`` (default now), ``atlas_param_type`` and
    ``map_param_type`` (names of the types the parameters and map data hold; default ``"Dict{String, Any}"``, as
    AtlasIO.jl writes for a dict) and ``weight_type`` (``"Int64"``, the default, or ``"Float64"``). ``params``
    (default ``{}``) is the atlas parameters, line 3. ``format_version`` is 1 (the default, as in AtlasIO.jl) or
    2; v2 adds ``"formatVersion":"2"`` to the header and writes each map's assignment as a tree.

    ``like`` is an open :class:`Atlas` whose header and parameters (and format version) are copied, for writing a
    modified copy of an atlas; any argument given explicitly overrides what it supplies.
    """
    def pick(value, attr, default):
        if value is not None:
            return value
        return getattr(like, attr) if like is not None else default

    version = _version(pick(format_version, "format_version", 1))
    header = {
        "description": pick(description, "description", ""),
        "date": pick(date, "date", None) or datetime.datetime.now().isoformat(timespec="milliseconds"),
        "atlasParamType": pick(atlas_param_type, "atlas_param_type", DEFAULT_PARAM_TYPE),
        "mapParamType": pick(map_param_type, "map_param_type", DEFAULT_PARAM_TYPE),
        "weightType": pick(weight_type, "weight_type", "Int64"),
    }
    if version != "1":
        header["formatVersion"] = version
    for k, v in header.items():
        if not isinstance(v, str):
            raise TypeError("new_atlas: the header value %s must be a string, not %r" % (k, v))
    if header["weightType"] not in WEIGHT_TYPES:
        raise ValueError("new_atlas: weight_type must be 'Int64' or 'Float64', not %r" % header["weightType"])
    params = pick(params, "params", {})

    path = None
    if hasattr(dest, "write"):
        if isinstance(dest, io.TextIOBase):
            f, close = dest, lambda f: f.flush()
        else:
            f = io.TextIOWrapper(dest, encoding="utf-8", newline="\n", write_through=True)
            close = lambda f: (f.flush(), f.detach())
    else:
        path = os.fspath(dest)
        opener = gzip.open if path.endswith(".gz") else bz2.open if path.endswith(".bz2") else None
        f = (opener(path, "wt", encoding="utf-8", newline="\n") if opener
             else open(path, "w", encoding="utf-8", newline="\n"))
        close = lambda f: f.close()
    try:
        return AtlasWriter(f, close, header, params)
    except BaseException:
        close(f)
        if path is not None:          # the header could not be written: leave no half-written file
            try:
                os.remove(path)
            except OSError:
                pass
        raise
