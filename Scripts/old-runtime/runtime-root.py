#!/usr/bin/env python3
"""Copy what a program needs to run out of Apple's simulator runtime package.

Apple's iOS 15.5 package is a xar holding one compressed cpio of the whole
runtime, which unpacks to about 15 GB. A check needs only the libraries, so
this reads the stream once and writes `usr/lib` and the frameworks' binaries,
about 4 GB, keeping the runtime's own layout.

Usage: runtime-root.py <package> <destination>
"""

import lzma
import os
import struct
import sys
import xml.etree.ElementTree as ElementTree
import zlib

MARK = "/RuntimeRoot/"
FRAMEWORKS = ("System/Library/Frameworks/", "System/Library/PrivateFrameworks/")


def payload(package):
    """The offset and length of the Payload member."""
    header = package.read(28)
    if header[:4] != b"xar!":
        raise SystemExit("not a xar archive")
    size, _, compressed, _ = struct.unpack(">HHQQ", header[4:24])
    package.seek(size)
    table = ElementTree.fromstring(zlib.decompress(package.read(compressed)))
    for entry in table.iter("file"):
        if entry.findtext("name") == "Payload":
            data = entry.find("data")
            return size + compressed + int(data.findtext("offset")), int(data.findtext("length"))
    raise SystemExit("no Payload member")


def chunks(package, end):
    """The decompressed payload, as it comes."""
    magic = package.read(4)
    if magic == b"pbzx":
        package.read(8)
        while package.tell() < end:
            expanded, packed = struct.unpack(">QQ", package.read(16))
            data = package.read(packed)
            yield data if packed == expanded else lzma.decompress(data)
        return
    decoder = zlib.decompressobj(31) if magic[0] == 0x1F else lzma.LZMADecompressor()
    data = magic
    while True:
        output = decoder.decompress(data)
        if output:
            yield output
        if package.tell() >= end:
            return
        data = package.read(min(16 << 20, end - package.tell()))


class Stream:
    def __init__(self, source):
        self.source = source
        self.buffer = bytearray()

    def take(self, count):
        while len(self.buffer) < count:
            self.buffer += next(self.source)
        result = bytes(self.buffer[:count])
        del self.buffer[:count]
        return result

    def copy(self, count, output):
        while count > 0:
            if not self.buffer:
                self.buffer += next(self.source)
            length = min(count, len(self.buffer))
            if output:
                output.write(memoryview(self.buffer)[:length])
            del self.buffer[:length]
            count -= length


def wanted(relative):
    if relative.startswith("usr/lib/"):
        return not relative.endswith((".dat", ".db", ".png"))
    if relative.startswith(FRAMEWORKS):
        name = relative.rsplit("/", 1)[1]
        return ("." not in name or name.endswith(".dylib")) and ".lproj/" not in relative and "Resources/" not in relative
    return False


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 64
    destination = sys.argv[2]
    with open(sys.argv[1], "rb") as package:
        offset, length = payload(package)
        package.seek(offset)
        stream = Stream(chunks(package, offset + length))
        while True:
            magic = stream.take(6)
            if magic == b"070707":
                header = stream.take(70)
                mode, name_size, size = int(header[12:18], 8), int(header[53:59], 8), int(header[59:70], 8)
                prefix, alignment = 76, 1
            elif magic == b"070701":
                header = stream.take(104)
                mode, size, name_size = int(header[8:16], 16), int(header[48:56], 16), int(header[88:96], 16)
                prefix, alignment = 110, 4
            else:
                raise SystemExit(f"unknown archive entry {magic!r}")
            name = stream.take(name_size)[:-1].decode()
            stream.take((alignment - (prefix + name_size) % alignment) % alignment)
            if name == "TRAILER!!!":
                return 0
            relative = name.split(MARK, 1)[1] if MARK in name else ""
            target = os.path.join(destination, relative) if wanted(relative) else None
            if target:
                os.makedirs(os.path.dirname(target), exist_ok=True)
            kind = mode & 0o170000
            if kind == 0o100000:
                with open(target, "wb") if target else open(os.devnull, "wb") as output:
                    stream.copy(size, output if target else None)
                if target:
                    os.chmod(target, mode & 0o755 | 0o200)
            elif kind == 0o120000:
                link = stream.take(size).decode()
                if target:
                    os.symlink(link, target)
            else:
                stream.copy(size, None)
            stream.take((alignment - size % alignment) % alignment)


if __name__ == "__main__":
    sys.exit(main())
