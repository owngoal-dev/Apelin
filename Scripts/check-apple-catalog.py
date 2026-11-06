#!/usr/bin/env python3
"""Compare Apple's software update catalog with the reviewed toolchain releases.

Apple's catalog lists only what it offers today. It replaced Command Line
Tools 27.0 with 27.2 and nothing in Apelin said so: 27.0 went from every
device's list, while its file stayed on Apple's servers. Reviewed packages now
carry their own address (`CommandLineToolsPackage`), so what this watches for
is what they cannot answer:

- a reviewed package Apple stopped serving, or serves at another size, which
  no device could download;
- a release Apple lists that is neither reviewed nor refused, waiting for a
  review.

Everything is read from `Packages/ApelinToolchain/.../Support.swift`, so there
is no second table to keep. `.github/workflows/apple-catalog.yml` runs this
every day and files an issue with what it prints.

Usage: check-apple-catalog.py <repository root>

Exit 0 when nothing needs doing, 65 when it printed something that does, 2
when Apple could not be read; anything else is this script failing, which the
workflow does not file.
"""

import http.client
import plistlib
import re
import sys
import time
import urllib.error
import urllib.request
import xml.parsers.expat

CATALOG = (
    "https://swscan.apple.com/content/catalogs/others/index-27-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11"
    "-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog"
)
SUPPORT = "Packages/ApelinToolchain/Sources/ApelinToolchain/Support.swift"
VERSION = re.compile(r'(?:Command Line Tools (?:for Xcode )?|"SU_VERS"\s*=\s*")([0-9]+(?:\.[0-9]+)*)')
PACKAGE = re.compile(
    r'productID: "(?P<id>[^"]+)",\s*sha256: "[0-9a-f]{64}",\s*url: "(?P<url>[^"]+)",\s*size: (?P<size>[\d_]+),',
)


UNREACHABLE = (urllib.error.URLError, http.client.HTTPException, OSError)


def fetch(url, headers=None):
    request = urllib.request.Request(url, headers={"User-Agent": "Apelin catalog check", **(headers or {})})
    return urllib.request.urlopen(request, timeout=60)


def served_size(url):
    """The size Apple serves `url` at, asked the way a device asks, by range.
    Apple's CDN answers an odd request 403, so one refusal is asked again."""
    for attempt in range(3):
        try:
            with fetch(url, {"Range": "bytes=0-0"}) as reply:
                return int(reply.headers["Content-Range"].rsplit("/", 1)[1])
        except urllib.error.HTTPError as error:
            if attempt == 2 or error.code not in (403, 404):
                raise
            time.sleep(10)


def reviewed(text):
    """Each reviewed package's version, by product, and its address and size."""
    releases = text.split("public static let releases: [CommandLineToolsRelease] = [", 1)[1]
    releases = releases.split("/// Releases looked at and refused", 1)[0]
    packages = {}
    for row in re.split(r"\n\s*\.init\(\n", releases)[1:]:
        version = re.search(r'version: "([^"]+)"', row).group(1)
        for match in PACKAGE.finditer(row):
            packages[match["id"]] = (version, match["url"], int(match["size"]))
    if not packages:
        raise SystemExit(f"error: no package read from {SUPPORT}")
    return packages


def refused(text):
    """The versions Apelin refuses by name."""
    names = set(re.findall(r'^\s+"(\d+\.\d+)": "', text, re.M))
    retired = re.search(r"static let retired = \[([^\]]*)\]", text).group(1)
    return names | set(re.findall(r'"([^"]+)"', retired))


def listed():
    """Every Command Line Tools product Apple lists today, by product."""
    catalog = plistlib.loads(fetch(CATALOG).read())
    products = {}
    for identifier, product in catalog["Products"].items():
        if not any(package.get("URL", "").endswith("/CLTools_Executables.pkg") for package in product.get("Packages", [])):
            continue
        address = product.get("Distributions", {}).get("English")
        text = fetch(address).read().decode("utf-8", "replace") if address else ""
        match = VERSION.search(text)
        products[identifier] = match[1] if match else "unknown"
    return products


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 64
    with open(f"{sys.argv[1]}/{SUPPORT}", encoding="utf-8") as handle:
        text = handle.read()
    packages = reviewed(text)
    known = refused(text)
    try:
        products = listed()
    except UNREACHABLE + (plistlib.InvalidFileException, xml.parsers.expat.ExpatError) as error:
        print(f"error: Apple's catalog could not be read: {error}", file=sys.stderr)
        return 2

    gone, moved = [], []
    for product, (version, address, size) in sorted(packages.items()):
        try:
            length = served_size(address)
        except urllib.error.HTTPError as error:
            if error.code not in (403, 404):
                print(f"error: {version} could not be read: {error}", file=sys.stderr)
                return 2
            gone.append(f"- {version} (`{product}`): {error}")
            continue
        except UNREACHABLE as error:
            print(f"error: {version} could not be read: {error}", file=sys.stderr)
            return 2
        if length != size:
            moved.append(f"- {version} (`{product}`): {length} bytes, reviewed at {size}")
    unreviewed = [
        f"- {version} (`{product}`)"
        for product, version in sorted(products.items(), key=lambda item: item[1])
        if product not in packages and version not in known
    ]
    unlisted = [f"- {packages[product][0]} (`{product}`)" for product in sorted(packages) if product not in products]

    sections = [
        ("Reviewed packages Apple no longer serves. No device can set these up:", gone),
        ("Reviewed packages Apple serves at another size:", moved),
        ("Releases Apple lists that nobody has reviewed:", unreviewed),
    ]
    needed = False
    for title, lines in sections:
        if lines:
            needed = True
            print(f"{title}\n\n" + "\n".join(lines) + "\n")
    if needed and unlisted:
        print("Reviewed releases Apple no longer lists, offered from their recorded address:\n\n" + "\n".join(unlisted) + "\n")
    return 65 if needed else 0


if __name__ == "__main__":
    sys.exit(main())
