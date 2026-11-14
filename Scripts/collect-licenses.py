#!/usr/bin/env python3
"""Collect reviewed offline notices into Apelin.app/Licenses.json.

Runs as the app target's "Collect Licenses" build phase, so the list is what
this build links, never a hand-kept copy: the repository LICENSE, the
vendored notices under Licenses/ (one folder per component that ships inside
a binary with no license file of its own), then every pin in
Package.resolved, its checkout walked for nested notices too. Missing
notices, changed text, an unreviewed component and an unreviewed binary
upgrade fail the build. See Licenses/README.md and Licenses/Compatibility.md.

A project with no Swift packages yet (no Package.resolved, no SourcePackages)
collects the rest.

Output: a JSON array of {id, name, version?, license, url, text}, read by
LicensesViewController and, for the version of a package the build links,
by LinkedPackage.
"""

import argparse
import hashlib
import json
import os
import re
import sys

LICENSE_FILE = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE)([-_.].*)?$", re.IGNORECASE)
PACKAGE_RESOLVED = os.path.join(
    "Apelin.xcodeproj", "project.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved"
)
SKIPPED_DIRECTORIES = {
    ".git", ".build", ".swiftpm", "Tests", "Test", "Example", "Examples",
    "docs", "Documentation", "node_modules", "Script", "Scripts", "Patches",
}
# The app's own code is MIT and ships no GPL-family code; LGPL's relinking
# condition cannot be met by a statically linked, ad-hoc signed binary either.
GPL_FAMILY = re.compile(
    r"GNU (Affero |Lesser |Library )?General Public License|www\.gnu\.org/licenses/(a|l)?gpl",
    re.IGNORECASE,
)


def fail(message):
    # Xcode reads "error:" lines into the issue navigator.
    print(f"error: collect-licenses: {message}", file=sys.stderr)
    sys.exit(1)


def read(path):
    with open(path, encoding="utf-8", errors="strict") as f:
        return f.read().strip("\n") + "\n"


def entry(identifier, name, version, url, text):
    # validate_review fills "license" from review.json; the key is placed here
    # so Licenses.json keeps its field order.
    item = {"id": identifier, "name": name, "license": "", "url": url, "text": text}
    if version:
        item["version"] = version
    return item


def xcconfig_setting(path, key):
    for line in read(path).splitlines():
        head, sep, value = line.partition("=")
        if sep and head.strip() == key:
            return value.split("//")[0].strip()
    fail(f"{key} is missing from {path}")


def app_entry(project):
    manifest = json.load(open(os.path.join(project, "manifest.json"), encoding="utf-8"))
    return entry(
        "app/Apelin",
        "Apelin",
        xcconfig_setting(os.path.join(project, "Configuration", "Version.xcconfig"), "MARKETING_VERSION"),
        manifest.get("homepage", ""),
        read(os.path.join(project, "LICENSE")),
    )


def vendored_entries(project, checkouts):
    root = os.path.join(project, "Licenses")
    entries = []
    for folder in sorted(os.listdir(root)):
        directory = os.path.join(root, folder)
        if not os.path.isdir(directory):
            continue
        notice_path = os.path.join(directory, "notice.json")
        license_path = os.path.join(directory, "LICENSE")
        for required in (notice_path, license_path):
            if not os.path.isfile(required):
                fail(f"Licenses/{folder} lacks {os.path.basename(required)}")
        notice = json.load(open(notice_path, encoding="utf-8"))
        version = notice.get("version")
        version_file = notice.get("version_file")
        if version_file:
            path = os.path.join(checkouts or "", version_file)
            if not checkouts or not os.path.isfile(path):
                fail(f"Licenses/{folder}: version_file {version_file} is not in the package checkouts")
            version = read(path).strip()
        entries.append(entry("vendored/" + folder, notice["name"], version, notice.get("url", ""), read(license_path)))
    return entries


def package_pins(project):
    path = os.path.join(project, PACKAGE_RESOLVED)
    if not os.path.isfile(path):
        return []
    return json.load(open(path, encoding="utf-8"))["pins"]


def excluded_paths(review):
    """Reviewed: folders a package's own manifest leaves out of every target
    it builds (libpng's contrib, zlib's contrib). A notice there describes
    code that is never compiled into Apelin, so it is not collected. Each
    entry is a review decision in review.json, never inferred."""
    return {identity: [os.path.normpath(path) for path in paths]
            for identity, paths in review.get("excludedPaths", {}).items()}


def stated_version(package, checkout, rule):
    """The version a checkout states for itself, for a package pinned by
    revision, whose pin names none: the one match of `pattern` in `file`.
    The app shows it (Model Providers names the kwwk in use), so a checkout
    that no longer states one where review.json says fails the build
    rather than leaving a stale or missing version."""
    path = os.path.join(checkout, rule["file"])
    if not os.path.isfile(path):
        fail(f"{package}: statedVersions file {rule['file']} is not in its checkout")
    found = re.findall(rule["pattern"], read(path))
    if len(found) != 1:
        fail(f"{package}: {rule['file']} states {len(found)} versions, expected one")
    return found[0]


def package_entries(pins, checkouts, excluded, stated):
    entries = []
    for pin in sorted(pins, key=lambda pin: pin["identity"]):
        location = pin["location"]
        url = location[:-4] if location.endswith(".git") else location
        package = url.rstrip("/").rsplit("/", 1)[-1]
        version = pin.get("state", {}).get("version") or pin.get("state", {}).get("revision")
        checkout = os.path.join(checkouts, package)
        if not os.path.isdir(checkout):
            fail(f"{package} is pinned in Package.resolved but has no checkout under {checkouts}")
        if pin["identity"] in stated:
            version = stated_version(package, checkout, stated[pin["identity"]])
        found = []
        skipped = excluded.get(pin["identity"], [])
        for directory, subdirectories, files in os.walk(checkout):
            relative = os.path.relpath(directory, checkout)
            subdirectories[:] = sorted(
                d for d in subdirectories
                if d not in SKIPPED_DIRECTORIES and os.path.normpath(os.path.join(relative, d)) not in skipped
            )
            for filename in sorted(files):
                if LICENSE_FILE.match(filename) and not filename.endswith(".template"):
                    found.append(os.path.join(directory, filename))
        if not found:
            fail(f"{package} has no LICENSE, COPYING, or NOTICE file in its checkout")
        # The root license first, nested notices after it, so a package reads
        # as itself and then what it vendors.
        found.sort(key=lambda path: (os.path.dirname(path) != checkout, path))
        for path in found:
            relative_directory = os.path.relpath(os.path.dirname(path), checkout)
            stem = os.path.splitext(os.path.basename(path))[0]
            suffix = re.sub(r"^(LICEN[CS]E|COPYING|NOTICE)[-_.]?", "", stem, flags=re.IGNORECASE)
            if relative_directory == ".":
                name = package
            elif suffix:
                name = package + " / " + relative_directory + " / " + suffix
            else:
                name = package + " / " + relative_directory
            entries.append(entry(
                pin["identity"] + "/" + os.path.relpath(path, checkout),
                name,
                version if relative_directory == "." else None,
                url,
                read(path),
            ))
    return entries


def gpl_exception(review, revisions, item, digest):
    """Whether this one notice is a reviewed exception to the GPL-family rule.

    An exception in review.json's "gplExceptions" names one notice id, the
    exact text hash the owner read, and — for a notice from a package
    checkout — the package identity and revision it came from. Any change to
    the text or the pin voids it; nothing else is relaxed. See
    Licenses/Compatibility.md for each one and why it was accepted."""
    exception = review.get("gplExceptions", {}).get(item["id"])
    if exception is None:
        return False
    if exception.get("sha256") != digest:
        fail(f"{item['id']} changed since its GPL-family exception was reviewed; review it again")
    package = exception.get("package")
    if package is not None and revisions.get(package) != exception.get("revision"):
        fail(f"{item['id']}: {package} is not at the revision its GPL-family exception was reviewed for")
    if not exception.get("accepted"):
        fail(f"{item['id']}: its GPL-family exception records no acceptance")
    return True


def validate_review(review, pins, entries):
    """Changed/new notices and binary upgrades require a fresh human review."""
    revisions = {pin["identity"]: pin["state"].get("revision") for pin in pins}
    for package, revision in review["binaryRevisions"].items():
        if revisions.get(package) != revision:
            fail(f"{package} binary changed; review its bundled components and update Licenses/review.json")
    actual = {item["id"] for item in entries}
    expected = set(review["notices"])
    if len(actual) != len(entries) or actual != expected:
        fail(f"notice inventory changed; added={sorted(actual - expected)}, removed={sorted(expected - actual)}")
    stale = set(review.get("gplExceptions", {})) - actual
    if stale:
        fail(f"GPL-family exceptions for notices no longer collected: {sorted(stale)}; remove them")
    for item in entries:
        reviewed = review["notices"][item["id"]]
        digest = hashlib.sha256(item["text"].encode("utf-8")).hexdigest()
        if GPL_FAMILY.search(item["text"]) and not gpl_exception(review, revisions, item, digest):
            fail(f"{item['id']} carries GPL-family license text; the app does not ship GPL or LGPL code")
        if reviewed["sha256"] != digest:
            fail(f"{item['id']} license text changed; review before updating its hash")
        item["license"] = reviewed["license"]


def find_checkouts(build_dir):
    """Xcode keeps SourcePackages beside Build/ in the derived data folder;
    BUILD_DIR is Build/Products for a build and a deeper archive path for an
    archive, so walk up until the sibling appears."""
    directory = os.path.abspath(build_dir)
    # Xcode nests BUILD_DIR at most this far below the derived-data root; past
    # it the walk would leave derived data and test the user's home and /.
    for _ in range(8):
        candidate = os.path.join(directory, "SourcePackages", "checkouts")
        if os.path.isdir(candidate):
            return candidate
        parent = os.path.dirname(directory)
        if parent == directory:
            break
        directory = parent
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--project", required=True, help="the repository root (SRCROOT)")
    parser.add_argument("--build-dir", required=True, help="Xcode's BUILD_DIR, used to find SourcePackages")
    parser.add_argument("--output", required=True, help="where to write Licenses.json")
    arguments = parser.parse_args()

    pins = package_pins(arguments.project)
    checkouts = find_checkouts(arguments.build_dir)
    if pins and not checkouts:
        fail(f"no SourcePackages/checkouts above {arguments.build_dir}; resolve the packages first")
    entries = [app_entry(arguments.project)]
    entries += vendored_entries(arguments.project, checkouts)
    review = json.load(open(os.path.join(arguments.project, "Licenses", "review.json"), encoding="utf-8"))
    entries += package_entries(pins, checkouts, excluded_paths(review), review.get("statedVersions", {}))
    validate_review(review, pins, entries)

    os.makedirs(os.path.dirname(arguments.output), exist_ok=True)
    with open(arguments.output, "w", encoding="utf-8") as f:
        json.dump(entries, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"collect-licenses: {len(entries)} licenses -> {arguments.output}")


if __name__ == "__main__":
    main()
