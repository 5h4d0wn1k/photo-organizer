#!/usr/bin/env python3
"""Regenerate the Local API Surface list in docs/architecture.md from
native_core/src/api.rs.

Usage: python3 scripts/generate-api-list.py [--check]

Default rewrites the section in place. --check exits non-zero when the
committed list differs, for CI or pre-merge verification. Either way the
list cannot rot silently: it is derived, not hand-maintained.
"""

import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
API_RS = ROOT / "native_core" / "src" / "api.rs"
DOC = ROOT / "docs" / "architecture.md"
SECTION_START = "## Local API Surface\n"
SECTION_END = "## Implementation Defaults"


def parse_routes():
    src = API_RS.read_text(encoding="utf-8")
    routes = re.findall(r'\.route\(\s*"([^"]+)"\s*,\s*([a-z_]+)\s*\(', src)
    groups: dict[str, list[tuple[str, str]]] = defaultdict(list)
    for path, method in routes:
        top = path.strip("/").split("/")[0] if path.strip("/") else "(root)"
        groups[top].append((method.upper(), path))
    return groups


def render(groups):
    lines = [SECTION_START.rstrip("\n"), ""]
    lines.append(
        "_Generated from `native_core/src/api.rs` by "
        "`scripts/generate-api-list.py` -- edit the routes, not this list._"
    )
    lines.append("")
    for top in sorted(groups):
        lines.append(f"### `/{top}`")
        lines.append("")
        for method, path in sorted(groups[top], key=lambda item: item[1]):
            lines.append(f"- `{method} {path}`")
        lines.append("")
    return "\n".join(lines).rstrip("\n") + "\n"


def main():
    groups = parse_routes()
    total = sum(len(v) for v in groups.values())
    doc = DOC.read_text(encoding="utf-8")
    start = doc.index(SECTION_START)
    end = doc.index(SECTION_END)
    updated = doc[:start] + render(groups) + "\n" + doc[end:]
    if "--check" in sys.argv:
        if updated != doc:
            print(
                f"docs/architecture.md API list is stale "
                f"({total} routes in api.rs); run scripts/generate-api-list.py",
                file=sys.stderr,
            )
            return 1
        print(f"API list current ({total} routes).")
        return 0
    DOC.write_text(updated, encoding="utf-8")
    print(f"wrote {total} routes into docs/architecture.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
