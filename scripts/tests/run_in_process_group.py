#!/usr/bin/env python3
"""Start a command in a new POSIX session, replacing this process."""

import os
import sys


def main() -> int:
    if os.name != "posix":
        print("process-group isolation requires a POSIX host", file=sys.stderr)
        return 2
    if len(sys.argv) < 2:
        print("usage: run_in_process_group.py COMMAND [ARG ...]", file=sys.stderr)
        return 2
    os.setsid()
    os.execvp(sys.argv[1], sys.argv[1:])
    return 127


if __name__ == "__main__":
    raise SystemExit(main())
