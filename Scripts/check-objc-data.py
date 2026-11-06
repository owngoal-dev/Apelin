#!/usr/bin/env python3
"""Fail on a `dynamic` member with `Data` in its signature.

Swift then calls the member through `objc_msgSend`, and `Data` crosses as an
`NSData` both ways. On an older iOS the Foundation the system ships turns it
back into `Data` leaving an object in the autorelease pool that keeps the
bytes alive until the pool drains, which a long synchronous loop on a worker
never lets it do. The same code runs in constant memory on iOS 26, so no
vphone and no Mac shows it.

0.3.6 made the toolchain reader `@objc dynamic`: on the iOS 15.5 runtime
extracting Command Line Tools 16.4 went from a 104 MB peak to 5.5 GB, and
users' devices could no longer unpack a toolchain. Of the types Swift bridges
only `Data` does this; `make old-runtime` measures it.

Leave such a member plain, whatever `AGENTS.md`'s rule on hooks says for the
others. Nothing passes this check by a comment.

Usage: check-objc-data.py <root>

Exit 0 clean, 65 when such a member is found.
"""

import os
import re
import sys

SKIP_DIRS = {".git", ".build", ".swiftpm", "build", "DerivedData", "node_modules", ".claude", "Vendor"}
SKIP_PATHS = ("Packages/Runestone/",)
SOURCE_ROOTS = ("Apelin", "Apelind", "Workers", "Shared", "Widgets", "Packages", "Extensions")

DYNAMIC = re.compile(r"\bdynamic\b")
DATA = re.compile(r"\bData\b")
KEYWORD = re.compile(r"\b(?:func|var|subscript)\b")


def code_only(text):
    """The file with its strings emptied and its comments blanked, line for line."""
    text = re.sub(r'""".*?"""', lambda match: "\n" * match.group().count("\n"), text, flags=re.S)
    text = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', text)
    text = re.sub(r"/\*.*?\*/", lambda match: "\n" * match.group().count("\n"), text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def declaration(text, start):
    """The text of the declaration `start` is inside, as far as its body: a
    function's signature, a property's type and initial value."""
    depth = 0
    is_property = None
    index = start
    while index < len(text):
        character = text[index]
        if is_property is None:
            match = KEYWORD.match(text, index)
            if match:
                is_property = match.group() == "var"
        if character in "([":
            depth += 1
        elif character in ")]":
            depth -= 1
        elif depth == 0 and character == "{":
            return text[start:index]
        elif depth == 0 and character == "\n" and is_property:
            return text[start:index]
        index += 1
    return text[start:index]


def check(path, relative):
    with open(path, encoding="utf-8") as handle:
        text = code_only(handle.read())
    problems = []
    for match in DYNAMIC.finditer(text):
        found = declaration(text, match.start())
        if KEYWORD.search(found) and DATA.search(found):
            line = text.count("\n", 0, match.start()) + 1
            problems.append(f"{relative}:{line}: {' '.join(found.split())[:120]}")
    return problems


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 64
    root = sys.argv[1]
    problems = []
    for source in SOURCE_ROOTS:
        for folder, directories, files in os.walk(os.path.join(root, source)):
            directories[:] = [name for name in directories if name not in SKIP_DIRS]
            for name in sorted(files):
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(folder, name)
                relative = os.path.relpath(path, root)
                if relative.startswith(SKIP_PATHS):
                    continue
                problems += check(path, relative)
    if problems:
        print("error: Data in a dynamic member's signature, which holds the bytes in the", file=sys.stderr)
        print("error: autorelease pool on older iOS; leave these plain (AGENTS.md):", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 65
    return 0


if __name__ == "__main__":
    sys.exit(main())
