#!/usr/bin/env python3
"""Canonicalize XcodeGen's equivalent duplicate copy-phase ordering."""

from pathlib import Path
import re
import sys

PROJECT = Path(__file__).resolve().parents[1] / "Flowlight.xcodeproj/project.pbxproj"
PHASE = re.compile(
    r"(?P<header>\t\t(?P<id>[A-F0-9]{24}) /\* Embed Dependencies \*/ = \{\n)"
    r"(?P<body>\t\t\tisa = PBXCopyFilesBuildPhase;\n.*?"
    r'\t\t\tname = "Embed Dependencies";\n'
    r"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n)"
    r"(?P<footer>\t\t\};)",
    re.DOTALL,
)


def main() -> int:
    source = PROJECT.read_text()
    matches = list(PHASE.finditer(source))
    if len(matches) != 2:
        print(
            f"expected exactly two Embed Dependencies phases, found {len(matches)}",
            file=sys.stderr,
        )
        return 1

    bodies = [match.group("body") for match in matches]
    destinations = []
    for body in bodies:
        found = re.search(r"^\t\t\tdstPath = (.*);$", body, re.MULTILINE)
        if found is None:
            print("an Embed Dependencies phase has no destination", file=sys.stderr)
            return 1
        destinations.append(found.group(1))

    expected = {"../Library/Helpers", "../Library/SystemExtensions"}
    if set(destinations) != expected:
        print(
            f"unexpected Embed Dependencies destinations: {sorted(destinations)}",
            file=sys.stderr,
        )
        return 1

    ordered_bodies = sorted(bodies, key=lambda body: re.search(
        r"^\t\t\tdstPath = (.*);$", body, re.MULTILINE
    ).group(1))
    pieces = []
    cursor = 0
    for match, body in zip(matches, ordered_bodies):
        pieces.append(source[cursor:match.start()])
        pieces.append(match.group("header") + body + match.group("footer"))
        cursor = match.end()
    pieces.append(source[cursor:])
    PROJECT.write_text("".join(pieces))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
