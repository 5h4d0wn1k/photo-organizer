#!/usr/bin/env python3
"""Prefix streamed shard output while preserving each original log file."""

import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: prefix_shard_output.py SHARD_INDEX", file=sys.stderr)
        return 2
    prefix = f"[shard {sys.argv[1]}] "
    for line in sys.stdin:
        sys.stdout.write(prefix + line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
