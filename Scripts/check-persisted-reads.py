#!/usr/bin/env python3
"""Fail on a read of saved data that one bad entry can turn into a loss.

Two shapes took users' data (issues #33 and the audit after #34):

1. A read — a decode, a file's bytes, a stored item — with a bare `try` inside a closure that walks a list — files in
   a folder, records in an array — passed to `map`, `compactMap`,
   `flatMap` or `forEach`. One entry that does not decode throws out of the
   whole walk: every chat vanished because one chat file was cut short.
   Catch per entry (`try?`, or `do`/`catch` that sets the entry aside).

2. A decode with `try?` whose failure falls back to an empty value, `?? []`,
   `?? [:]` or `?? SomeType()`. The empty value is what the next save writes,
   over every good entry: one toolchain record a version could not read
   unregistered all of them. Read lists with `PreservedList`, and set a file
   that does not read aside with `UnreadableFile` (both in ApelinCore).

A line, or the line above it, carrying `// persisted-read: <why>` passes:
for data that is never written back from what was read, say so there.

Usage: check-persisted-reads.py <root>

Exit 0 clean, 65 when a read of either shape is found.
"""

import os
import re
import sys

SKIP_DIRS = {".git", ".build", ".swiftpm", "build", "DerivedData", "node_modules", ".claude", "Tests", "Vendor"}
SKIP_PATHS = ("Packages/Runestone/",)
SOURCE_ROOTS = ("Apelin", "Apelind", "Workers", "Shared", "Widgets", "Packages")

DECODE = re.compile(r"\b(?:decode|JSONFile\.read)\s*\(")
# What a walk reads per entry: a decode, the bytes of a file, a stored item.
READ = re.compile(r"\b(?:decode|JSONFile\.read|load|credential|record)\s*\(|Data\(contentsOf:")
BARE_TRY = re.compile(r"\btry(?![?!])\b")
WALK = re.compile(r"\.(?:compactMap|map|flatMap|forEach)\s*(?:\([^)]*\))?\s*\{")
EMPTY_FALLBACK = re.compile(r"\?\?\s*(?:\[\]|\[:\]|[A-Z][A-Za-z0-9_]*\(\s*\))")
ALLOW = "persisted-read:"


def strip_strings(line):
    line = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
    return line.split("//", 1)[0]


def check(path, relative):
    problems = []
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")
    depth = 0
    walks = []  # depths at which a walking closure opened
    previous = ""
    for number, raw in enumerate(lines, 1):
        allowed = ALLOW in raw or ALLOW in previous
        previous = raw
        code = strip_strings(raw)
        # the braces that open a walk's closure on this line
        walk_braces = {match.end() - 1 for match in WALK.finditer(code)}
        inside_walk = bool(walks) or bool(walk_braces)
        if not allowed:
            if READ.search(code) and BARE_TRY.search(code) and inside_walk:
                problems.append((number, "a bare `try` read inside a walk over a list: one bad entry throws out every one"))
            if DECODE.search(code) and "try?" in code and EMPTY_FALLBACK.search(code):
                problems.append((number, "a `try?` decode that falls back to empty: the next save writes the empty value over the file"))
        for index, character in enumerate(code):
            if character == "{":
                depth += 1
                if index in walk_braces:
                    walks.append(depth)
            elif character == "}":
                while walks and walks[-1] >= depth:
                    walks.pop()
                depth -= 1
    return [(relative, number, message) for number, message in problems]


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[-3], file=sys.stderr)
        return 64
    root = os.path.abspath(sys.argv[1])
    found = []
    for top in SOURCE_ROOTS:
        for directory, names, files in os.walk(os.path.join(root, top)):
            names[:] = [name for name in names if name not in SKIP_DIRS]
            for name in files:
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(directory, name)
                relative = os.path.relpath(path, root)
                if relative.startswith(SKIP_PATHS):
                    continue
                found += check(path, relative)
    for relative, number, message in found:
        print(f"{relative}:{number}: {message}", file=sys.stderr)
    if found:
        print(f"error: {len(found)} read(s) of saved data one bad entry can lose; "
              "see Scripts/check-persisted-reads.py", file=sys.stderr)
        return 65
    return 0


if __name__ == "__main__":
    sys.exit(main())
