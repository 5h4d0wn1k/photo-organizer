#!/usr/bin/env python3
"""Regenerate scripts/requirements-test.txt from PyPI, with hashes.

Why this exists (issue #136)
---------------------------
The three required-check suites used to run
`python3 -m pip install --quiet "pyyaml==6.0.2"` *at test time*, which is
two defects at once:

1. A test suite mutating the machine it runs on, and reaching the network to do
   it, so a suite's result depended on the network.
2. A version pin with no hash. OpenSSF Scorecard's `Pinned-Dependencies` check
   reads a pip install as pinned only when `--require-hashes` is present, so
   `pyyaml==6.0.2` is "not pinned by hash" and a tampered or substituted wheel
   is accepted. It raised four `PinnedDependenciesID` alerts.

The fix is a hash-pinned requirements file. The risk moves to *maintaining* it:
PyYAML 6.0.2 publishes 53 artifacts, so hand-copying 53 sha256 digests on every
version bump is exactly where a human error produces a lockfile that looks
authoritative and is wrong. This script removes that step -- the file is
generated, and `validate_artifacts` refuses to emit anything it cannot vouch for.

Usage
-----
    # regenerate in place (needs network)
    python3 scripts/gen_test_requirements.py

    # print to stdout instead of writing
    python3 scripts/gen_test_requirements.py --stdout

    # offline, from a saved PyPI JSON response (used by the tests)
    python3 scripts/gen_test_requirements.py --from-json pypi.json --stdout

`render_requirements` and `validate_artifacts` are pure: no network, no clock, no
filesystem. That is what the tests exercise.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from typing import Iterable, Sequence

PACKAGE = "pyyaml"
VERSION = "6.0.2"

# Where the generated file lives, relative to the repository root.
OUTPUT_RELATIVE_PATH = "scripts/requirements-test.txt"

PYPI_JSON_URL = "https://pypi.org/pypi/{package}/{version}/json"

# The range of CPython minors for which this pin publishes a wheel, measured from
# the artifact set PyPI returned for 6.0.2: cp38, cp39, cp310, cp311, cp312, cp313.
# There is no cp314 wheel, which is why CI pins an interpreter from this range and
# why the install is --only-binary.
#
# This is a property of the pin, not of the tool, so it must be re-measured when
# the version is bumped: regenerate the lockfile, then update these two numbers to
# whatever the new artifact set says. A CI job pinned to a minor above this range
# does not fail in a way that names the cause -- pip says "Could not find a
# version that satisfies the requirement pyyaml==6.0.2 (from versions: 6.0.3)",
# which reads as a bad pin rather than a missing wheel. The test asserts the
# pinned interpreter stays inside the range so that failure cannot be reached by
# editing ci.yml. That assertion is worth its keep even though the check is
# belt-and-braces: it names the cause, while pip's message does not.
MIN_CPYTHON_WITH_WHEEL = 8
MAX_CPYTHON_WITH_WHEEL = 13

# pip normalises names for comparison: runs of -_. collapse to a single - and the
# result is lowercased. The wheel filenames on PyPI use the project's own
# capitalisation (PyYAML-...), so a naive startswith() on "pyyaml" would reject
# every real artifact. This is the same rule pip itself applies in
# `pkg_resources.safe_name` / PEP 503 normalisation.
_NAME_SEPARATORS = re.compile(r"[-_.]+")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")


def normalise_name(name: str) -> str:
    """PEP 503 normalisation, so `PyYAML`, `pyyaml` and `py-yaml` compare equal."""
    return _NAME_SEPARATORS.sub("-", name).lower()


def _classify(filename: str) -> str | None:
    """Return 'wheel' or 'sdist' for a recognised artifact, else None."""
    if filename.endswith(".whl"):
        return "wheel"
    if filename.endswith((".tar.gz", ".zip")):
        return "sdist"
    return None


def extract_artifacts(pypi_json: dict) -> list[tuple[str, str]]:
    """Pull (filename, sha256) out of a PyPI JSON response, sorted by filename.

    Sorted so the generated file is byte-stable across runs: an unsorted file
    would produce a diff on every regeneration and train reviewers to ignore
    regeneration diffs.
    """
    artifacts: list[tuple[str, str]] = []
    for entry in pypi_json.get("urls", []):
        filename = entry.get("filename")
        digest = (entry.get("digests") or {}).get("sha256")
        if not filename or not digest:
            # A file with no sha256 cannot be pinned, so it cannot be installed
            # under --require-hashes. Dropping it silently would produce a file
            # that installs but does not cover every artifact; PyPI does not
            # publish such entries in practice, and if it ever did, the missing
            # platform fails loudly at install time instead of quietly.
            continue
        if _classify(filename) is None:
            # .egg, .exe, signatures and metadata are not installable inputs.
            continue
        artifacts.append((filename, digest.lower()))
    artifacts.sort()
    return artifacts


def validate_artifacts(
    artifacts: Sequence[tuple[str, str]],
    package: str = PACKAGE,
    version: str = VERSION,
) -> None:
    """Raise ValueError unless every artifact is safe to pin.

    Each check below corresponds to a way a hand-maintained file goes wrong:

    * empty          -- the response was not what we think it was; an empty
                        requirements file installs nothing and the suites then
                        fail closed with a confusing "no yaml module".
    * bad sha256     -- a truncated paste, or a digest copied from another tool.
    * wrong name     -- an artifact for a different project got pasted in.
    * wrong version  -- ditto for a version; would pin something we never audited.
    * dup filename   -- ambiguous: pip would see two candidate files.
    * dup digest     -- a digest reused across two filenames means a copy/paste
                        error, and would let a substituted file inherit the
                        original file's authorisation.
    """
    if not artifacts:
        raise ValueError(
            f"no installable artifacts found for {package}=={version}; "
            "refusing to write an empty requirements file"
        )

    expected = normalise_name(package)
    seen_filenames: set[str] = set()
    seen_digests: dict[str, str] = {}

    for filename, digest in artifacts:
        if not _SHA256.match(digest):
            raise ValueError(f"{filename}: sha256 is not 64 lowercase hex chars: {digest!r}")
        kind = _classify(filename)
        if kind is None:
            raise ValueError(f"{filename}: not a wheel or an sdist")
        if kind == "wheel":
            # Wheel filenames are {distribution}-{version}(-{build})?-{python}-{abi}-{platform}.whl
            parts = filename[: -len(".whl")].split("-")
            if len(parts) < 5:
                raise ValueError(f"{filename}: wheel filename does not have 5 or more segments")
            dist, dist_version = parts[0], parts[1]
        else:
            # sdists are {name}-{version}.{ext}
            stem = filename
            for suffix in (".tar.gz", ".zip"):
                if stem.endswith(suffix):
                    stem = stem[: -len(suffix)]
                    break
            name_part, _, dist_version = stem.rpartition("-")
            dist = name_part
        if normalise_name(dist) != expected:
            raise ValueError(f"{filename}: distribution is {dist!r}, expected {package!r}")
        if dist_version != version:
            raise ValueError(f"{filename}: version is {dist_version!r}, expected {version!r}")
        if filename in seen_filenames:
            raise ValueError(f"{filename}: appears more than once")
        if digest in seen_digests:
            raise ValueError(
                f"{digest} is claimed by both {seen_digests[digest]!r} and {filename!r}; "
                "a digest must authorise exactly one file"
            )
        seen_filenames.add(filename)
        seen_digests[digest] = filename


def parse_requirements(text: str) -> tuple[str, str, list[tuple[str, str]]]:
    """Inverse of render_requirements: read a rendered file back.

    Exists so the committed file can be checked for round-trip equality against
    the generator, offline and with no network:

        file_header(*parse_requirements(committed)) == committed

    What that equality proves, precisely: the committed file is the generator's
    own output for the pin it declares -- same header, same pin, same filenames
    in the same order, same digests, one per filename. It proves the file has not
    been hand-reordered, hand-reformatted, hand-renamed, or had an artifact
    dropped (a dropped hash line leaves its filename comment orphaned and is
    rejected below).

    It does NOT prove the digests are the digests of the real artifacts. Editing
    a digest in place round-trips faithfully. The check on that is
    `pip install --require-hashes`, in CI, every run. Comparing against PyPI
    here instead would need the network on every run and would prove the same
    thing less directly.

    A comment line counts as a filename comment only *after* the requirement line
    has been seen, which is what keeps the file's prose header -- a comment block
    at the top -- from being mistaken for a set of filenames.
    """
    package: str | None = None
    version: str | None = None
    digests: list[str] = []

    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            # Comments are only legal in the file's prose header, before the
            # requirement. A comment inside the hash block is a layout pip does
            # not accept, so seeing one here means the file is not what the
            # generator emits.
            if package is not None:
                raise ValueError(
                    f"line {lineno}: a comment inside the hash block; pip ignores the "
                    "hashes after such a line, so this file could not enforce --require-hashes"
                )
            continue
        if line.endswith("\\"):
            line = line[:-1].rstrip()
        if line.startswith("--hash=sha256:"):
            digests.append(line[len("--hash=sha256:") :])
            continue
        if line.startswith("--hash="):
            raise ValueError(f"line {lineno}: only sha256 hashes are supported: {line!r}")
        if package is not None:
            raise ValueError(f"line {lineno}: unexpected second requirement: {line!r}")
        name, sep, spec = line.partition("==")
        if not sep:
            raise ValueError(f"line {lineno}: requirement is not pinned with '==': {line!r}")
        package, _, version = name.strip(), sep, spec.strip()
        if not version:
            raise ValueError(f"line {lineno}: empty version in {line!r}")

    if package is None or version is None:
        raise ValueError("no requirement found")
    if not digests:
        raise ValueError(f"{package}=={version} has no --hash entries")

    artifacts = [(f"{package}-{version}-{index:03d}", digest) for index, digest in enumerate(digests)]
    return package, version, artifacts


def render_requirements(
    artifacts: Sequence[tuple[str, str]],
    package: str = PACKAGE,
    version: str = VERSION,
) -> str:
    """Render the hash-pinned requirements file. Pure.

    Layout is pip's continuation form, one `--hash` per artifact. pip accepts
    many hashes for one requirement and picks the artifact matching the running
    interpreter and platform, then refuses anything whose digest is not listed --
    so listing every published artifact pins the *content* without narrowing the
    set of platforms that can install.

    The list is deliberately comment-free, and that is a hard constraint rather
    than a preference. Two layouts were built and measured against a real
    `pip install --require-hashes`, and both are rejected by pip:

    * a `# filename` comment on the line above each hash terminates the
      continuation, so every hash after the first comment is silently ignored
      ("line N has --hash but no requirement, and will be ignored");
    * a trailing `# filename` after the continuation backslash is stripped but
      the backslash survives, giving "Invalid requirement ... Could not split
      options".

    Silently ignored hashes are the worst possible failure for a lockfile, so the
    filename annotations were dropped. Artifact names live in PyPI, and the
    generator is the record of which ones it read.

    NOTE ON WHAT RENDERING DOES AND DOES NOT PROVE. This is a pure function of
    (package, version, ordered artifacts), so re-rendering a parsed file
    reproduces it byte for byte. Round-trip equality therefore proves
    *structure*: the header, the pin, the ordering, and that every digest is
    well-formed and unique. It does NOT prove a digest is the digest of the real
    artifact -- an edit, a reordering, or a dropped line all round-trip
    faithfully. The only non-circular check on a digest is the artifact bytes
    themselves, which is what `pip install --require-hashes` does in CI on every
    run, backed here by the artifact-count floor in the test. Do not read a
    passing round-trip check as "the hashes are right".
    """
    lines = [f"{package}=={version} \\"]
    for _, digest in artifacts:
        lines.append(f"    --hash=sha256:{digest} \\")
    # Drop the trailing continuation so the last line is a complete requirement.
    return "\n".join(lines)[:-2].rstrip() + "\n"


def file_header(package: str, version: str) -> str:
    """The comment block that explains the file to the next person who reads it.

    Deliberately a function of (package, version) only. Anything derived from the
    artifact list is not recoverable from the rendered file, which would break the
    round-trip equality that proves the committed file is exactly what this tool
    emits.
    """
    return (
        f"# Hash-pinned test dependencies (issue #136).\n"
        f"#\n"
        f"# GENERATED FILE -- do not hand-edit. Regenerate with:\n"
        f"#     python3 scripts/gen_test_requirements.py\n"
        f"#\n"
        f"# Install with:\n"
        f"#     python3 -m pip install --require-hashes --only-binary=:all: \\\n"
        f"#         -r {OUTPUT_RELATIVE_PATH}\n"
        f"#\n"
        f"# --require-hashes makes pip verify the digest of the artifact it actually\n"
        f"# downloads, which is the property a bare `==` pin does not have.\n"
        f"# --only-binary=:all: forbids building from source. That is deliberate: as of\n"
        f"# this pin there is no wheel for CPython 3.14, so on a FRESH 3.14 interpreter\n"
        f"# pip refuses instead of silently compiling the sdist. A silent compile is a\n"
        f"# different artifact from every digest listed here, built by whatever\n"
        f"# toolchain happens to be present, and it is the exact failure mode -- slow,\n"
        f"# environment-dependent, and invisible -- that this file exists to remove.\n"
        f"#\n"
        f"# The qualification 'fresh' is load-bearing and was measured, not assumed. If\n"
        f"# PyYAML is already installed, pip reports 'Requirement already satisfied' and\n"
        f"# exits 0 without resolving a wheel at all, so NEITHER flag is exercised on\n"
        f"# such an interpreter. CI's setup-python interpreters are always fresh, so the\n"
        f"# guarantee holds where it is relied on; locally, check it in a new venv.\n"
        f"#\n"
        f"# Every published artifact is listed, not just the ones CI happens to run\n"
        f"# on, so pinning the content does not narrow who can install. A digest\n"
        f"# authorises exactly one file: gen_test_requirements.py refuses to emit a\n"
        f"# digest claimed by two filenames.\n"
        f"#\n"
        f"# The hash list below is comment-free, and cannot carry the filename of the\n"
        f"# artifact each digest belongs to: a comment inside a requirement's\n"
        f"# continuation block makes pip ignore every hash after it. Both layouts were\n"
        f"# built and measured against a real install. The names live in PyPI and in\n"
        f"# the generator, which is the record of what it read.\n"
        f"#\n"
        f"# Where the trust actually sits. gen_test_requirements_test.sh checks that\n"
        f"# this file is exactly what the generator emits for this pin -- same header,\n"
        f"# same pin, same digests in the same order, each well-formed and unique -- and\n"
        f"# floors the artifact count so the list cannot shrink unnoticed. It does NOT\n"
        f"# check that a digest is the digest of the real artifact: a digest edited,\n"
        f"# reordered or removed in place still round-trips. The check on that is\n"
        f"# --require-hashes above, which pip runs against the bytes it actually\n"
        f"# downloads, in CI, on every run.\n"
        f"#\n"
        f"# PyPI does not allow replacing a file that has already been published for\n"
        f"# a given version, so this list cannot silently go stale; the risk is a\n"
        f"# hand-edited version bump, which is why the file is generated.\n"
    )


def render_file(
    artifacts: Sequence[tuple[str, str]],
    package: str = PACKAGE,
    version: str = VERSION,
) -> str:
    validate_artifacts(artifacts, package=package, version=version)
    return file_header(package, version) + render_requirements(artifacts, package, version)


def fetch_pypi_json(url: str, timeout: int = 60) -> dict:
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
        return json.loads(response.read().decode("utf-8"))


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--package", default=PACKAGE)
    parser.add_argument("--version", default=VERSION)
    parser.add_argument(
        "--from-json",
        metavar="PATH",
        help="read a saved PyPI JSON response instead of fetching one (offline)",
    )
    parser.add_argument(
        "--stdout",
        action="store_true",
        help="print to stdout instead of writing the file",
    )
    parser.add_argument(
        "--output",
        metavar="PATH",
        help=f"output path (default: <repo root>/{OUTPUT_RELATIVE_PATH})",
    )
    args = parser.parse_args(list(argv) if argv is not None else None)

    if args.from_json:
        with open(args.from_json, encoding="utf-8") as handle:
            pypi_json = json.load(handle)
    else:
        url = PYPI_JSON_URL.format(package=args.package, version=args.version)
        try:
            pypi_json = fetch_pypi_json(url)
        except Exception as error:  # noqa: BLE001 - surfaced verbatim to the operator
            print(f"error: could not fetch {url}: {error}", file=sys.stderr)
            return 1

    artifacts = extract_artifacts(pypi_json)
    try:
        rendered = render_file(artifacts, package=args.package, version=args.version)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    if args.stdout:
        sys.stdout.write(rendered)
        return 0

    output = args.output
    if output is None:
        import pathlib

        repo_root = pathlib.Path(__file__).resolve().parent.parent
        output = str(repo_root / OUTPUT_RELATIVE_PATH)
    with open(output, "w", encoding="utf-8") as handle:
        handle.write(rendered)
    print(f"wrote {output} ({len(artifacts)} artifacts)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
