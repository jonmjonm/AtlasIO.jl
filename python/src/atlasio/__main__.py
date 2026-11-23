"""Command line: ``python -m atlasio convert SRC DST --to 2`` (or ``atlasio convert ...`` once installed)."""
import argparse
import sys

from . import AtlasFormatError, __version__, convert


def main(argv=None):
    parser = argparse.ArgumentParser(prog="atlasio", description="Tools for Atlas files (redistricting ensembles).")
    parser.add_argument("--version", action="version", version="atlasio " + __version__)
    sub = parser.add_subparsers(dest="command", required=True)
    c = sub.add_parser("convert", help="convert an Atlas file between format versions 1 and 2",
                       description="Copy SRC to DST, converting every map to format version --to. Only the "
                                   "header's formatVersion and each map's assignment are rewritten; everything "
                                   "else is copied byte for byte. Files may be .jsonl, .jsonl.gz or .jsonl.bz2.")
    c.add_argument("src")
    c.add_argument("dst")
    c.add_argument("--to", required=True, choices=["1", "2"], help="target format version")
    args = parser.parse_args(argv)
    try:
        n = convert(args.src, args.dst, args.to)
    except (AtlasFormatError, ValueError, OSError) as e:
        print("atlasio convert: %s" % e, file=sys.stderr)
        return 1
    print("converted %d maps to format v%s: %s" % (n, args.to, args.dst))
    return 0


if __name__ == "__main__":
    sys.exit(main())
