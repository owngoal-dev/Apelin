#!/usr/bin/env python3
"""Run Documents/Schemas/Fixtures against the reference implementation.

  project/valid, extension/valid      must validate
  project/invalid, extension/invalid  must fail, with the error named in
                                      their expectations.json
  canonical-json.json                 RFC 8785 vectors, byte for byte
  manifest-format.json                apelin-project.json's written form, byte
                                      for byte, and what is left as it is
  digest/<case>/                      the build and packaging digests of
                                      project/ equal expected.json, and the
                                      edits below move exactly the digests
                                      README ▸ Approval digests says they move

--update rewrites digest/<case>/expected.json from the current rules; read
the diff before committing it: a changed digest means every project's
Confirm-mode baseline changes with it.
"""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE))

import apelin_schema as schema  # noqa: E402

FIXTURES = HERE.parent / "Fixtures"


def check_documents(kind: str, validate) -> int:
    failures = 0
    for path in sorted((FIXTURES / kind / "valid").glob("*.json")):
        errors = validate(schema.load_json(path))
        if errors:
            failures += 1
            print(f"FAIL {kind}/valid/{path.name}: {errors[0]}")
        else:
            print(f"ok   {kind}/valid/{path.name}")
    expectations = schema.load_json(FIXTURES / kind / "invalid" / "expectations.json")
    listed = set(expectations)
    for path in sorted((FIXTURES / kind / "invalid").glob("*.json")):
        if path.name == "expectations.json":
            continue
        listed.discard(path.name)
        expected = expectations.get(path.name)
        try:
            errors = validate(schema.load_json(path))
        except ValueError as error:
            errors = [str(error)]
        if not errors:
            failures += 1
            print(f"FAIL {kind}/invalid/{path.name}: passed")
        elif expected is None or not any(expected in e for e in errors):
            failures += 1
            print(f"FAIL {kind}/invalid/{path.name}: expected '{expected}', got {errors}")
        else:
            print(f"ok   {kind}/invalid/{path.name}: {next(e for e in errors if expected in e)}")
    for name in sorted(listed):
        failures += 1
        print(f"FAIL {kind}/invalid/{name}: listed but missing")
    return failures


def check_canonical() -> int:
    failures = 0
    for index, vector in enumerate(schema.load_json(FIXTURES / "canonical-json.json")):
        actual = schema.canonical_json(vector["input"]).decode("utf-8")
        if actual != vector["canonical"]:
            failures += 1
            print(f"FAIL canonical-json[{index}]: {actual!r} != {vector['canonical']!r}")
        else:
            print(f"ok   canonical-json[{index}] {vector['name']}")
    return failures


def check_manifest_format() -> int:
    failures = 0
    for index, vector in enumerate(schema.load_json(FIXTURES / "manifest-format.json")):
        actual = schema.formatted_manifest(vector["text"].encode("utf-8"))
        expected = vector["formatted"]
        again = actual and schema.formatted_manifest(actual)
        if (actual and actual.decode("utf-8")) != expected or again != actual:
            failures += 1
            print(f"FAIL manifest-format[{index}] {vector['name']}: {actual!r}")
        else:
            print(f"ok   manifest-format[{index}] {vector['name']}")
    return failures


PLACEHOLDER_TYPES = {
    **{name: {"type": kind} for name, kind in schema.BUILTIN_PARAMETERS.items()},
    "displayName": {"type": "string"},
    "productName": {"type": "identifier"},
    "bundles": {"type": "bundleIDList"},
    "enabled": {"type": "bool"},
}

# (format, template text, allowed)
PLACEHOLDER_RULES = [
    ("objc", 'self.title = @"{{displayName}}";', True),
    ("objc", "NSString *title = {{displayName}};", False),
    ("objc", "@interface {{productName}}Controller : NSObject", True),
    ("objc", "static int on = {{enabled}};", True),
    ("objc", "NSArray *b = {{bundles}};", False),
    ("swift", 'let title = "{{displayName}}"', True),
    ("json", '"name": "{{displayName}}"', True),
    ("json", '"name": {{displayName}}', False),
    ("json", '"bundles": {{bundles}}', True),
    ("json", '"bundles": "{{bundles}}"', False),
    ("json", '"architectures": {{architectures}}', True),
    ("plist-xml", "<string>{{displayName}}</string>", True),
    ("plist-xml", '<string attr="{{displayName}}">x</string>', False),
    ("plist-xml", "<array>{{bundles}}</array>", True),
    ("shell", "echo {{packageID}}", True),
    ("shell", "echo {{displayName}}", False),
    ("shell", "echo {{projectName}}", False),
    ("deb-control", "Name: {{displayName}}", True),
    ("text", "{{unknownName}}", False),
    ("copy", "{{anything}}", True),
]

# (format, value, substituted text for "{{displayName}}" inside a literal)
ESCAPES = [
    ("objc", 'a"b\\c\nd', 'a\\"b\\\\c\\nd'),
    ("swift", 'say \\(x) "hi"', 'say \\\\(x) \\"hi\\"'),
    ("json", 'a"b\\c\u0001', 'a\\"b\\\\c\\u0001'),
    ("plist-xml", "<Tom & 'Jerry'>", "&lt;Tom &amp; &apos;Jerry&apos;&gt;"),
]


def check_placeholders() -> int:
    failures = 0
    for file_format, text, allowed in PLACEHOLDER_RULES:
        errors = schema.check_template_text(text, file_format, PLACEHOLDER_TYPES, "rule")
        if (not errors) != allowed:
            failures += 1
            print(f"FAIL placeholder {file_format}: {text!r} should be {'allowed' if allowed else 'refused'}: {errors}")
        else:
            print(f"ok   placeholder {file_format}: {text!r} {'allowed' if allowed else 'refused'}")
    for name, kind, allowed in (("{{productName}}.m", "identifier", True), ("{{displayName}}.m", "string", False), ("{{projectName}}/x", "projectName", False)):
        errors = schema.check_template_path(name, PLACEHOLDER_TYPES, "path")
        if (not errors) != allowed:
            failures += 1
            print(f"FAIL placeholder path {name}")
        else:
            print(f"ok   placeholder path {name!r} {'allowed' if allowed else 'refused'}")
    for file_format, value, expected in ESCAPES:
        actual = schema.substitute("{{displayName}}", file_format, PLACEHOLDER_TYPES, {"displayName": value})
        if actual != expected:
            failures += 1
            print(f"FAIL escape {file_format}: {actual!r} != {expected!r}")
        else:
            print(f"ok   escape {file_format}: {value!r} -> {actual!r}")
    for file_format, value in (("deb-control", "two\nlines"), ("shell", "a b")):
        try:
            schema.substitute("{{displayName}}", file_format, PLACEHOLDER_TYPES, {"displayName": value})
        except schema.TemplateError:
            print(f"ok   escape {file_format}: {value!r} refused")
        else:
            failures += 1
            print(f"FAIL escape {file_format}: {value!r} accepted")
    return failures


def edit_json(path: Path, change) -> None:
    document = schema.load_json(path)
    change(document)
    path.write_text(json.dumps(document, indent=4, sort_keys=True) + "\n")


def write_compact(path: Path) -> None:
    path.write_bytes((json.dumps(schema.load_json(path), ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"))


def write_formatted(path: Path) -> None:
    write_compact(path)
    path.write_bytes(schema.formatted_manifest(path.read_bytes()))


def append(path: Path, text: str) -> None:
    with open(path, "a") as handle:
        handle.write(text)


# (description, edit(project_root), build moves, packaging moves)
EDITS = [
    ("source code edited", lambda r: append(r / "Sources/main.c", "/* edited */\n"), False, False),
    ("new source file under an existing glob", lambda r: (r / "Sources/extra.c").write_text("int extra;\n"), False, False),
    ("package version bumped", lambda r: edit_json(r / "apelin-project.json", lambda d: d["package"].__setitem__("version", "9.9.9")), False, False),
    ("members reordered and reindented", lambda r: edit_json(r / "apelin-project.json", lambda d: None), False, False),
    ("written on one line", lambda r: write_compact(r / "apelin-project.json"), False, False),
    ("formatted from one line", lambda r: write_formatted(r / "apelin-project.json"), False, False),
    ("toolchain rebound", lambda r: edit_json(r / "apelin-project.json", lambda d: d["environment"]["toolchain"].__setitem__("id", "clt-28.0")), False, False),
    ("compile flag added", lambda r: edit_json(r / "apelin-project.json", lambda d: d["build"]["steps"][1].__setitem__("flags", ["-DEXTRA=1"])), True, False),
    ("build script edited", lambda r: append(r / "Scripts/generate-version.sh", "# edited\n"), True, False),
    ("entitlements edited", lambda r: append(r / "Packaging/Tool.entitlements", "\n"), True, False),
    ("deployment target raised", lambda r: edit_json(r / "apelin-project.json", lambda d: d.__setitem__("deploymentTarget", "17.0")), True, False),
    ("postinst edited", lambda r: append(r / "Packaging/postinst", "# edited\n"), False, True),
    ("installed data file edited", lambda r: append(r / "Packaging/apelinhello.conf", "x=1\n"), False, True),
    ("dependency added", lambda r: edit_json(r / "apelin-project.json", lambda d: d["package"].__setitem__("depends", ["coreutils"])), False, True),
    ("icon set", lambda r: edit_json(r / "apelin-project.json", lambda d: d["package"].__setitem__("icon", "https://example.com/icon.png")), False, True),
    ("install path changed", lambda r: edit_json(r / "apelin-project.json", lambda d: d["package"]["layout"][0].__setitem__("path", "/usr/local/bin/apelinhello")), False, True),
]


def check_digests(update: bool) -> int:
    failures = 0
    for case in sorted(p for p in (FIXTURES / "digest").iterdir() if p.is_dir()):
        digests = schema.project_digests(case / "project")
        expected_path = case / "expected.json"
        if update:
            expected_path.write_text(json.dumps(digests, indent=2, ensure_ascii=False) + "\n")
        expected = schema.load_json(expected_path)
        if digests != expected:
            failures += 1
            print(f"FAIL digest/{case.name}: {digests['build']['digest']} / {digests['packaging']['digest']} differ from expected.json")
            continue
        print(f"ok   digest/{case.name}: build {digests['build']['digest']}")
        print(f"     digest/{case.name}: packaging {digests['packaging']['digest']}")
        for description, edit, build_moves, packaging_moves in EDITS:
            with tempfile.TemporaryDirectory(prefix="apelin-digest.", dir="/private/tmp") as scratch:
                root = Path(scratch) / "project"
                shutil.copytree(case / "project", root)
                edit(root)
                after = schema.project_digests(root)
            moved = (after["build"]["digest"] != digests["build"]["digest"],
                     after["packaging"]["digest"] != digests["packaging"]["digest"])
            if moved != (build_moves, packaging_moves):
                failures += 1
                print(f"FAIL digest/{case.name}: {description}: build moved {moved[0]}, packaging moved {moved[1]}")
            else:
                print(f"ok   digest/{case.name}: {description} -> build {'moves' if moved[0] else 'same'}, packaging {'moves' if moved[1] else 'same'}")
    return failures


def main() -> int:
    update = "--update" in sys.argv[1:]
    failures = check_documents("project", schema.validate_project)
    failures += check_documents("extension", schema.validate_manifest)
    failures += check_canonical()
    failures += check_manifest_format()
    failures += check_placeholders()
    failures += check_digests(update)
    print("all fixtures pass" if not failures else f"{failures} fixture(s) failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
