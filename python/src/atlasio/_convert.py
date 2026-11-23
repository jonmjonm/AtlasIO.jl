"""Convert Atlas files between format versions 1 and 2 (atlas_format.md).

Mirrors AtlasIO.jl's convertAtlas: only the header's formatVersion and each map's assignment field are rewritten;
the banner, the atlas parameters and each map's name, weight and data are copied byte for byte.
"""
import bz2
import gzip
import json
import os
import re

_FIELD = {"1": "districting", "2": "assignment"}


def _open_text(path, mode):
    path = os.fspath(path)
    if path.endswith(".gz"):
        return gzip.open(path, mode + "t", encoding="utf-8", newline="\n")
    if path.endswith(".bz2"):
        return bz2.open(path, mode + "t", encoding="utf-8", newline="\n")
    return open(path, mode, encoding="utf-8", newline="\n")


def _version(v):
    s = v if isinstance(v, str) else (str(v) if isinstance(v, int) and not isinstance(v, bool) else "")
    if s not in ("1", "2"):
        raise ValueError("format version must be 1 or 2 (or '1' or '2'), got %r" % (v,))
    return s


def convert(src, dst, to):
    """Copy the Atlas file ``src`` to ``dst``, converting every map to format version ``to`` (1 or 2).

    Either file may be plain, ``.gz`` or ``.bz2`` (chosen by extension). Returns the number of maps.

    Only what the version changes is rewritten: the header's ``formatVersion`` (added for v2, removed for v1)
    and each map's assignment field (``districting`` in v1, ``assignment`` in v2). The banner, the atlas
    parameters and each map's name, weight and data are copied byte for byte. v2 trees are written with sorted
    names; v1 entries in sorted key order, with keys in the form AtlasIO.jl writes. Every line ends with a
    newline. Converting is lossless: converting back gives the same districting for every map.

    Raises ``atlasio.AtlasFormatError`` naming the line and map for anything that cannot be converted (a map
    line that does not match the header's version, a districting v2 cannot hold, or a map line whose assignment
    is not its last field); ``dst`` is then removed.
    """
    from . import AtlasFormatError  # noqa: F401  (imported here to avoid a cycle at import time)

    to = _version(to)
    if os.path.abspath(os.fspath(src)) == os.path.abspath(os.fspath(dst)):
        raise ValueError("convert: src and dst are the same file: %s" % (src,))
    n = 0
    with _open_text(src, "r") as fin:
        banner = _strip_newline(fin.readline())
        header = _strip_newline(fin.readline())
        params = _strip_newline(fin.readline())
        frm, new_header = _convert_header(header, to)
        try:
            with _open_text(dst, "w") as fout:
                fout.write(banner + "\n" + new_header + "\n" + params + "\n")
                lineno = 3
                for line in fin:
                    lineno += 1
                    fout.write(_convert_map_line(_strip_newline(line), frm, to, lineno))
                    n += 1
        except BaseException:
            try:
                os.remove(dst)
            except OSError:
                pass
            raise
    return n


def _strip_newline(line):
    if line.endswith("\n"):
        line = line[:-1]
        if line.endswith("\r"):
            line = line[:-1]
    return line


_VERSION_FIELD = r'"formatVersion"\s*:\s*"[^"\\]*"'


def _convert_header(line, to):
    from . import AtlasFormatError
    try:
        h = json.loads(line)
    except ValueError as e:
        raise AtlasFormatError("not a valid Atlas file: the header line (line 2) did not parse as JSON (%s)" % e)
    if not isinstance(h, dict):
        raise AtlasFormatError("not a valid Atlas file: the header line (line 2) is not a JSON object")
    for k, v in h.items():
        if not isinstance(v, str):
            raise AtlasFormatError('not a valid Atlas file: the header value of "%s" must be a JSON string' % k)
    frm = h.get("formatVersion", "1")
    if frm not in ("1", "2"):
        raise AtlasFormatError('unsupported Atlas formatVersion "%s": upgrade atlasio' % frm)
    if frm == to:
        return frm, line
    had = "formatVersion" in h
    if to == "1":
        del h["formatVersion"]
    else:
        h["formatVersion"] = to
    # Edit just that field in the original text, so the rest of the header keeps its exact bytes; keep the edit
    # only if it parses to exactly the intended header (same fields, values and order).
    edited = _edit_header_version(line, had, to)
    if edited is not None:
        try:
            if list(json.loads(edited).items()) == list(h.items()):
                return frm, edited
        except ValueError:
            pass
    return frm, json.dumps(h, ensure_ascii=False, separators=(",", ":"))


def _edit_header_version(line, had, to):
    if to == "2":
        if had:
            return re.sub(_VERSION_FIELD, '"formatVersion":"2"', line, count=1)
        s = line.rstrip()
        if not s.endswith("}"):
            return None
        body = s[:-1].rstrip()
        return body + ("" if body.endswith("{") else ",") + '"formatVersion":"2"}'
    for pat in (r"\s*,\s*" + _VERSION_FIELD, _VERSION_FIELD + r"\s*,?\s*"):
        if re.search(pat, line):
            return re.sub(pat, "", line, count=1)
    return None


def _convert_map_line(line, frm, to, lineno):
    from . import AtlasFormatError, _from_assignment, _from_v1, district_key_string
    if frm == to:
        return line + "\n"
    try:
        x = json.loads(line)
    except ValueError as e:
        raise AtlasFormatError("line %d: not a valid Atlas map line: failed to parse as JSON (%s)" % (lineno, e))
    if not isinstance(x, dict):
        raise AtlasFormatError("line %d: not a valid Atlas map line: a map line must be a JSON object" % lineno)
    name = x.get("name") if isinstance(x.get("name"), str) else None
    where = "line %d%s" % (lineno, ' (map "%s")' % name if name is not None else "")
    field, other = _FIELD[frm], _FIELD[to]
    if field not in x:
        raise AtlasFormatError('%s: the header declares formatVersion "%s" but the map line has no "%s"%s'
                               % (where, frm, field, ' (it has "%s")' % other if other in x else ""))
    if other in x:
        raise AtlasFormatError('%s: the map line has both "districting" and "assignment"' % where)
    try:
        d = _from_v1(x[field], x) if frm == "1" else _from_assignment(x[field], x)
    except AtlasFormatError as e:
        raise AtlasFormatError("%s: %s" % (where, e))
    except (AttributeError, TypeError, ValueError) as e:
        raise AtlasFormatError("%s: not a valid Atlas map line: %s" % (where, e))
    start = _last_top_level_key_start(line)
    key = '"%s"' % field
    if start < 0 or line[start:start + len(key)] != key:
        raise AtlasFormatError('%s: the assignment ("%s") must be the map line\'s last field, as atlas_format.md '
                               "requires; convert only rewrites that field" % (where, field))
    if to == "2":
        new = '"assignment":' + _assignment_json(d, where)
    else:
        new = '"districting":[' + ",".join(
            "{%s:%d}" % (json.dumps(district_key_string(k), ensure_ascii=False), d[k]) for k in sorted(d)) + "]"
    return line[:start] + new + "}\n"


def _assignment_json(d, where):
    """The v2 tree for districting ``d`` ({key tuple: district}), names sorted at every level."""
    from . import AtlasFormatError
    tree = {}
    for k, v in d.items():
        if not k:
            raise AtlasFormatError("%s: cannot convert to v2: the district key () is empty" % where)
        node = tree
        for i, part in enumerate(k[:-1]):
            child = node.setdefault(part, {})
            if not isinstance(child, dict):
                _prefix_error(where, k[:i + 1], k)
            node = child
        if k[-1] in node:
            _prefix_error(where, k, _some_key_under(k, node[k[-1]]))
        node[k[-1]] = v
    # sort_keys sorts by code point, the UTF-8 byte order the spec asks for
    return json.dumps(tree, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def _some_key_under(prefix, node):
    while isinstance(node, dict):
        name = min(node)
        prefix, node = prefix + (name,), node[name]
    return prefix


def _prefix_error(where, short, long):
    from . import AtlasFormatError
    raise AtlasFormatError("%s: cannot convert to v2: the key %r is a prefix of the key %r, so the region would "
                           "be both whole and split (rule 1 of atlas_format.md)" % (where, tuple(short), tuple(long)))


def _last_top_level_key_start(s):
    """Index of the opening quote of the last key of the top-level JSON object in ``s``, or -1."""
    depth = 0
    instr = esc = expect_key = False
    last = -1
    for i, c in enumerate(s):
        if instr:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                instr = False
        elif c == '"':
            instr = True
            if depth == 1 and expect_key:
                last = i
            expect_key = False
        elif c in "{[":
            depth += 1
            expect_key = depth == 1 and c == "{"
        elif c in "}]":
            depth -= 1
            expect_key = False
        elif c == ",":
            expect_key = depth == 1
        elif c not in " \t\n\r":
            expect_key = False
    return last
