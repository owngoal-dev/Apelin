#!/usr/bin/env python3
"""Find the Objective-C selectors Apelin's own classes take over by accident.

Every member of Apelin's own classes that Objective-C can represent is
`@objc dynamic`, so a tweak can hook it (AGENTS.md ▸ Hard rules). A selector
made that way can land on one the class already answers through its Apple
superclasses — public or private —, and then UIKit, which calls that selector,
runs our method instead. Swift catches a clash only with what the SDK's
headers declare; a private method it never sees.

This reads the Objective-C metadata of the built Mach-O files (classes,
categories, protocols), maps each method back to the Swift member through the
symbol table, and compares it with what the Apple superclass chain answers, as
the Mac Catalyst probe (`audit-objc-selectors-probe.m`) printed it from the
runtime. It reports, for each class this repository declares:

  collision  a selector an ancestor already answers, from a member the Swift
             source does not declare `override`
  forbidden  a selector the runtime or ARC treats specially (load, initialize,
             alloc, copy, dealloc, isEqual:, …), a method in the alloc / new /
             copy / mutableCopy / init family that is not an initializer, and
             on a UIResponder subclass an edit action UIResponder.h declares
             (cut:, copy:, paste:, delete:, select:, …)
  optional   an optional selector of an Objective-C protocol answered by a
             member that is no witness of a protocol the Swift class
             declares (an Apple superclass's protocol, or one it never
             adopts), so an object that holds the class as delegate or data
             source may now call it
  category   a method of ours added to an Apple class by a category, which
             replaces the class's own when the selector is the same
  direct     an override, in a final class, of a member of our own base
             class, without `dynamic`: Swift calls it directly through the
             final class's type, so a hook would not see those calls

With `--baseline`, the products of an earlier build, a finding whose selector
the same class did not have there is marked NEW, and an optional selector is
reported only when it is new, a witness of a declared protocol included.
ACCEPTED below names the findings looked at and kept.

Usage (the driver, audit-objc-selectors.sh, runs it):
  audit-objc-selectors.py externals <binary>…
  audit-objc-selectors.py audit --probe <file> --responder-header <UIResponder.h>
      --source-root <repository> --products <products> [--baseline-dir <products>] <binary>…

Exit 0 when nothing is found, 1 when a finding needs a look, 2 on an error.
"""

import argparse
import collections
import os
import re
import struct
import subprocess
import sys

LC_SEGMENT_64 = 0x19
LC_DYLD_CHAINED_FIXUPS = 0x80000034
LC_UUID = 0x1B
CPU_TYPE_ARM64 = 0x0100000C

# Selectors the runtime, ARC or Foundation call by name.
FORBIDDEN = {
    "load", "initialize", "alloc", "allocWithZone:", "new", "copy",
    "copyWithZone:", "mutableCopy", "mutableCopyWithZone:", "dealloc",
    "retain", "release", "autorelease", "retainCount", "class", "self",
    "superclass", "hash", "isEqual:", "zone", "respondsToSelector:",
    "conformsToProtocol:", "isKindOfClass:", "isMemberOfClass:",
    "forwardingTargetForSelector:", "methodSignatureForSelector:",
    "forwardInvocation:", "doesNotRecognizeSelector:",
    "resolveInstanceMethod:", "resolveClassMethod:",
}
# Forbidden on an NSObject subclass unless the Swift member overrides them.
NSOBJECT_DESCRIPTIONS = {"description", "debugDescription"}
FAMILIES = ("alloc", "new", "copy", "mutableCopy", "init")
STATS = collections.Counter()
# Findings looked at and kept, by class and selector, with the reason.
ACCEPTED = {
    ("ComposerAttachmentPreview", "-numberOfPreviewItemsInPreviewController:"):
        "QLPreviewController's own data source method; the subclass is its own data source on purpose, and was before the hooks rule",
    ("ComposerAttachmentPreview", "-previewController:previewItemAtIndex:"):
        "QLPreviewController's own data source method; the subclass is its own data source on purpose, and was before the hooks rule",
}
SOURCE_SKIP_DIRS = {".git", ".build", ".swiftpm", "build", "DerivedData", "Tests", "Documents", "Scripts", "Licenses"}
SOURCE_SKIP_PATHS = ("Packages/Runestone/",)


class MachO:
    """Just enough of a thin or fat arm64 Mach-O to read its Objective-C metadata."""

    def __init__(self, path):
        self.path = path
        with open(path, "rb") as handle:
            data = handle.read()
        if struct.unpack_from(">I", data, 0)[0] == 0xCAFEBABE:
            count = struct.unpack_from(">I", data, 4)[0]
            for index in range(count):
                cputype, _, offset, size, _ = struct.unpack_from(">iiIII", data, 8 + index * 20)
                if cputype == CPU_TYPE_ARM64:
                    data = data[offset : offset + size]
                    break
            else:
                raise ValueError(f"{path}: no arm64 slice")
        if struct.unpack_from("<I", data, 0)[0] != 0xFEEDFACF:
            raise ValueError(f"{path}: not a 64-bit Mach-O")
        self.data = data
        self.segments = []
        self.sections = {}
        self.chained = None
        self.uuid = None
        ncmds = struct.unpack_from("<I", data, 16)[0]
        offset = 32
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", data, offset)
            if cmd == LC_SEGMENT_64:
                segname = data[offset + 8 : offset + 24].rstrip(b"\0").decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", data, offset + 24)
                nsects = struct.unpack_from("<I", data, offset + 64)[0]
                self.segments.append((segname, vmaddr, vmsize, fileoff, filesize))
                for index in range(nsects):
                    base = offset + 72 + index * 80
                    sectname = data[base : base + 16].rstrip(b"\0").decode()
                    addr, size = struct.unpack_from("<QQ", data, base + 32)
                    self.sections[(segname, sectname)] = (addr, size)
            elif cmd == LC_DYLD_CHAINED_FIXUPS:
                self.chained = struct.unpack_from("<II", data, offset + 8)
            elif cmd == LC_UUID:
                self.uuid = data[offset + 8 : offset + 24].hex()
            offset += cmdsize
        self.base = next(vmaddr for name, vmaddr, *_ in self.segments if name == "__TEXT")
        self.imports = []
        self.pointer_format = None
        if self.chained:
            self._read_fixups(*self.chained)

    def _read_fixups(self, dataoff, _datasize):
        data = self.data
        (_, starts_offset, imports_offset, symbols_offset, imports_count,
         imports_format, symbols_format) = struct.unpack_from("<7I", data, dataoff)
        if symbols_format != 0:
            raise ValueError(f"{self.path}: compressed fixup symbols are not read")
        symbols = dataoff + symbols_offset
        for index in range(imports_count):
            if imports_format == 1:
                value = struct.unpack_from("<I", data, dataoff + imports_offset + index * 4)[0]
                name_offset = value >> 9
            elif imports_format == 2:
                value = struct.unpack_from("<I", data, dataoff + imports_offset + index * 8)[0]
                name_offset = value >> 9
            elif imports_format == 3:
                value = struct.unpack_from("<Q", data, dataoff + imports_offset + index * 16)[0]
                name_offset = value >> 32
            else:
                raise ValueError(f"{self.path}: import format {imports_format}")
            self.imports.append(self._cstring_at(symbols + name_offset))
        starts = dataoff + starts_offset
        seg_count = struct.unpack_from("<I", data, starts)[0]
        for index in range(seg_count):
            info = struct.unpack_from("<I", data, starts + 4 + index * 4)[0]
            if info:
                self.pointer_format = struct.unpack_from("<H", data, starts + info + 6)[0]
                break

    def _cstring_at(self, fileoff):
        end = self.data.index(b"\0", fileoff)
        return self.data[fileoff:end].decode("utf-8", "replace")

    def fileoff(self, addr):
        for _, vmaddr, vmsize, fileoff, filesize in self.segments:
            if vmaddr <= addr < vmaddr + min(vmsize, filesize):
                return fileoff + (addr - vmaddr)
        return None

    def u32(self, addr):
        return struct.unpack_from("<I", self.data, self.fileoff(addr))[0]

    def i32(self, addr):
        return struct.unpack_from("<i", self.data, self.fileoff(addr))[0]

    def pointer(self, addr):
        """A pointer as the loader would see it: an address, ('bind', name), or None."""
        offset = self.fileoff(addr)
        if offset is None:
            return None
        raw = struct.unpack_from("<Q", self.data, offset)[0]
        if raw == 0:
            return None
        fmt = self.pointer_format
        if fmt in (2, 6):
            if raw >> 63:
                return ("bind", self.imports[raw & 0xFFFFFF])
            target = raw & 0xFFFFFFFFF
            if fmt == 6:
                target += self.base
            return target | (((raw >> 36) & 0xFF) << 56)
        if fmt in (1, 9, 12):
            auth, bind = raw >> 63, (raw >> 62) & 1
            if bind:
                mask = 0xFFFFFF if fmt == 12 else 0xFFFF
                return ("bind", self.imports[raw & mask])
            if auth:
                return (raw & 0xFFFFFFFF) + self.base
            target = raw & 0x7FFFFFFFFFF
            return target + self.base if fmt != 1 else target
        if fmt is None:
            return raw
        raise ValueError(f"{self.path}: pointer format {fmt}")

    def cstring(self, addr):
        offset = self.fileoff(addr)
        return None if offset is None else self._cstring_at(offset)

    def section_pointers(self, sectname):
        for segname in ("__DATA_CONST", "__DATA", "__DATA_DIRTY"):
            if (segname, sectname) in self.sections:
                addr, size = self.sections[(segname, sectname)]
                return [self.pointer(addr + index * 8) for index in range(size // 8)]
        return []

    def methods(self, addr):
        """[(selector, imp)] of a method_list_t."""
        if not isinstance(addr, int):
            return []
        flags_and_size, count = self.u32(addr), self.u32(addr + 4)
        entsize = flags_and_size & 0xFFFC
        found = []
        for index in range(count):
            entry = addr + 8 + index * entsize
            if flags_and_size & 0x80000000:
                name = entry + self.i32(entry)
                selector = self.cstring(name) if flags_and_size & 0x40000000 else self.cstring(self.pointer(name))
                found.append((selector, entry + 8 + self.i32(entry + 8)))
            else:
                imp = self.pointer(entry + 16)
                found.append((self.cstring(self.pointer(entry)), imp if isinstance(imp, int) else None))
        return found

    def protocol(self, addr, seen):
        """{'name', 'parents', 'required': {(kind, sel)}, 'optional': {(kind, sel)}}."""
        if addr in seen:
            return seen[addr]
        record = {"name": self.cstring(self.pointer(addr + 8)), "parents": [], "required": set(), "optional": set()}
        seen[addr] = record
        for slot, bucket, kind in ((24, "required", "i"), (32, "required", "c"), (40, "optional", "i"), (48, "optional", "c")):
            for selector, _ in self.methods(self.pointer(addr + slot)):
                record[bucket].add((kind, selector))
        record["parents"] = [self.protocol(child, seen) for child in self.protocol_list(self.pointer(addr + 16))]
        return record

    def protocol_list(self, addr):
        if not isinstance(addr, int):
            return []
        count = struct.unpack_from("<Q", self.data, self.fileoff(addr))[0]
        return [p for p in (self.pointer(addr + 8 + index * 8) for index in range(count)) if isinstance(p, int)]


def class_ro(macho, class_addr):
    data = macho.pointer(class_addr + 32)
    return data & ~0x7 & ((1 << 56) - 1) if isinstance(data, int) else None


def read_classes(macho):
    """{address: class record} for every class in __objc_classlist, categories merged in."""
    protocols_seen = {}
    classes = {}
    for addr in macho.section_pointers("__objc_classlist"):
        if not isinstance(addr, int):
            continue
        ro = class_ro(macho, addr)
        superclass = macho.pointer(addr + 8)
        meta = macho.pointer(addr)
        record = {
            "address": addr,
            "raw_name": macho.cstring(macho.pointer(ro + 24)),
            "super": superclass,
            "instance": macho.methods(macho.pointer(ro + 32)),
            "class": [],
            "protocols": [macho.protocol(p, protocols_seen) for p in macho.protocol_list(macho.pointer(ro + 40))],
            "categories": [],
        }
        if isinstance(meta, int):
            meta_ro = class_ro(macho, meta)
            if meta_ro:
                record["class"] = macho.methods(macho.pointer(meta_ro + 32))
        classes[addr] = record
    external_categories = collections.defaultdict(list)
    for addr in macho.section_pointers("__objc_catlist"):
        if not isinstance(addr, int):
            continue
        target = macho.pointer(addr + 8)
        category = {
            "name": macho.cstring(macho.pointer(addr)),
            "instance": macho.methods(macho.pointer(addr + 16)),
            "class": macho.methods(macho.pointer(addr + 24)),
            "protocols": [macho.protocol(p, protocols_seen) for p in macho.protocol_list(macho.pointer(addr + 32))],
        }
        if isinstance(target, int) and target in classes:
            owner = classes[target]
            owner["instance"] += category["instance"]
            owner["class"] += category["class"]
            owner["protocols"] += category["protocols"]
            owner["categories"].append(category["name"])
        elif isinstance(target, tuple):
            external_categories[objc_class_symbol(target[1])].append(category)
    protocols = [macho.protocol(p, protocols_seen) for p in macho.section_pointers("__objc_protolist") if isinstance(p, int)]
    return classes, external_categories, protocols


def objc_class_symbol(symbol):
    return symbol.split("_OBJC_CLASS_$_", 1)[-1]


def demangle(names, simplified):
    if not names:
        return {}
    arguments = ["xcrun", "swift-demangle"] + (["--simplified"] if simplified else [])
    output = subprocess.run(arguments, input="\n".join(names) + "\n", capture_output=True, text=True, check=True).stdout
    return dict(zip(names, output.splitlines()))


def symbols_by_address(path, uuid):
    """{address: [symbol]} from nm: the binary's own, and a dSYM beside it of the same UUID.

    A packaged binary is stripped, so its members are named from the dSYM
    (`<binary>.dSYM` or `<bundle>.dSYM` beside it); one of another build would
    name the wrong members and is left out.
    """
    candidates = [path]
    for dsym in (path + ".dSYM", os.path.dirname(path.rstrip("/")) + ".dSYM"):
        dwarf = os.path.join(dsym, "Contents", "Resources", "DWARF")
        if not os.path.isdir(dwarf):
            continue
        for name in sorted(os.listdir(dwarf)):
            candidate = os.path.join(dwarf, name)
            if MachO(candidate).uuid == uuid:
                candidates.insert(0, candidate)
            else:
                print(f"warning: {candidate} is another build's dSYM (UUID differs); not used", file=sys.stderr)
    table = collections.defaultdict(list)
    for candidate in candidates:
        result = subprocess.run(["nm", "-U", candidate], capture_output=True, text=True)
        for line in result.stdout.splitlines():
            parts = line.split(" ", 2)
            if len(parts) == 3 and parts[1] in "tTsS":
                table[int(parts[0], 16)].append(parts[2])
    return table


class Binary:
    def __init__(self, path):
        self.path = path
        self.macho = MachO(path)
        self.classes, self.external_categories, self.protocols = read_classes(self.macho)
        names = [r["raw_name"] for r in self.classes.values()]
        full, simple = demangle(names, False), demangle(names, True)
        for record in self.classes.values():
            record["name"] = full.get(record["raw_name"], record["raw_name"])
            record["simple"] = simple.get(record["raw_name"], record["raw_name"])
        self.symbols = symbols_by_address(path, self.macho.uuid)
        thunks = sorted({s for names in self.symbols.values() for s in names if s.startswith("_$s") and s.endswith("To")})
        self.member_names = demangle(thunks, True)

    def member(self, imp):
        """The Swift member behind an implementation, as swift-demangle --simplified spells it."""
        for symbol in self.symbols.get(imp, []):
            text = self.member_names.get(symbol)
            if text and text.startswith("@objc "):
                return text[len("@objc ") :]
        for symbol in self.symbols.get(imp, []):
            if symbol.startswith(("-[", "+[")):
                return symbol
        return None


def module_of(name):
    if name.startswith("("):
        return ""
    return name.split(".", 1)[0] if "." in name else ""


def is_ours(record):
    """Apelin's modules (Apelin, apelind, apelin_<worker>, Apelin<Package>), not a dependency's."""
    return module_of(record["name"]).lower().startswith("apelin")


def read_probe(path):
    probe = {"super": {}, "instance": collections.defaultdict(set), "class": collections.defaultdict(set),
             "protocols": collections.defaultdict(list), "protocol_parents": collections.defaultdict(list),
             "protocol_optional": collections.defaultdict(set), "missing": set()}
    with open(path) as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            kind = parts[0]
            if kind == "S":
                probe["super"][parts[1]] = None if parts[2] == "-" else parts[2]
            elif kind == "I":
                probe["instance"][parts[1]].add(parts[2])
            elif kind == "C":
                probe["class"][parts[1]].add(parts[2])
            elif kind == "P":
                probe["protocols"][parts[1]].append(parts[2])
            elif kind == "PP":
                probe["protocol_parents"][parts[1]].append(parts[2])
            elif kind == "PO":
                probe["protocol_optional"][parts[1]].add((parts[2], parts[3]))
            elif kind == "MISSING":
                probe["missing"].add(parts[1])
    return probe


def responder_actions(header):
    actions = set()
    with open(header) as handle:
        for line in handle:
            match = re.match(r"\s*-\s*\(void\)\s*(\w+):\s*\((?:nullable\s+)?id\)\s*sender", line)
            if match:
                actions.add(match.group(1) + ":")
    return actions


def in_family(selector):
    stripped = selector.lstrip("_")
    for family in FAMILIES:
        if stripped.startswith(family):
            rest = stripped[len(family) :]
            if not rest or rest[0] == ":" or rest[0].isupper():
                return family
    return None


# --- the Swift side ---------------------------------------------------------

DECLARATION = re.compile(r"\b(?:class|extension|actor|struct|enum)\s+([A-Za-z_][\w.]*)")
FINAL_CLASS = re.compile(r"\bfinal\b[^{(=]*?\bclass\s+(?!func\b|var\b|let\b|subscript\b)([A-Za-z_]\w*)")


class Sources:
    """The Swift sources, each line knowing the type whose body holds it."""

    def __init__(self, root):
        self.root = root
        self.files = {}
        self.context = {}
        self.by_type = collections.defaultdict(set)
        self.final = set()
        for directory, subdirectories, files in os.walk(root):
            relative = os.path.relpath(directory, root)
            subdirectories[:] = [d for d in subdirectories if d not in SOURCE_SKIP_DIRS and not d.startswith(".")]
            if any((relative + "/").startswith(p) for p in SOURCE_SKIP_PATHS):
                subdirectories[:] = []
                continue
            for name in files:
                if name.endswith(".swift") and name != "EmbeddedSchemas.swift":
                    path = os.path.join(directory, name)
                    with open(path, encoding="utf-8", errors="replace") as handle:
                        text = handle.read()
                    self.files[path] = text.split("\n")
                    code = code_only(text).split("\n")
                    self.context[path] = body_owners(code)
                    for line in code:
                        for match in DECLARATION.finditer(line):
                            self.by_type[match.group(1).split(".")[-1]].add(path)
                        match = FINAL_CLASS.search(line)
                        if match:
                            self.final.add(match.group(1))

    def relative(self, path):
        return os.path.relpath(path, self.root)

    def declaration(self, class_simple, member):
        """[(path, line number, line, line with the attributes above it)] that may declare the member."""
        parsed = parse_member(member)
        if not parsed:
            return []
        type_name = class_simple.split(".")[-1]
        kind, name, labels = parsed
        if kind == "init":
            pattern = re.compile(r"\binit\s*[?!]?\s*(?:<[^>]*>)?\s*\(")
        elif kind == "subscript":
            pattern = re.compile(r"\bsubscript\s*(?:<[^>]*>)?\s*\(")
        elif kind == "var":
            pattern = re.compile(r"\b(?:var|let)\s+(?:[^,\n]*,\s*)*?`?" + re.escape(name) + r"`?\b")
        else:
            pattern = re.compile(r"\bfunc\s+`?" + re.escape(name) + r"`?\s*(?:<[^>]*>)?\s*\(")
        candidates = []
        for path in sorted(self.by_type.get(type_name, ())):
            lines = self.files[path]
            owners = self.context[path]
            for index, line in enumerate(lines):
                if owners[index] != type_name:
                    continue
                code = line.split("//", 1)[0]
                match = pattern.search(code)
                if not match:
                    continue
                if labels is not None and kind in ("func", "init", "subscript"):
                    if declared_labels(lines, index, match.end() - 1) != labels:
                        continue
                candidates.append((path, index + 1, line.strip(), attributes_before(lines, index)))
        return candidates


def code_only(text):
    """The text with comments and string literals blanked, line breaks kept."""
    out, index, size = [], 0, len(text)
    mode, interpolations = "code", []
    while index < size:
        character = text[index]
        if mode == "code":
            if text.startswith("//", index):
                end = text.find("\n", index)
                end = size if end < 0 else end
                out.append(" " * (end - index))
                index = end
                continue
            if text.startswith("/*", index):
                depth, end = 0, index
                while end < size:
                    if text.startswith("/*", end):
                        depth, end = depth + 1, end + 2
                    elif text.startswith("*/", end):
                        depth, end = depth - 1, end + 2
                        if depth == 0:
                            break
                    else:
                        end += 1
                out.append("".join("\n" if c == "\n" else " " for c in text[index:end]))
                index = end
                continue
            if text.startswith('"""', index):
                mode = "multiline"
                out.append("   ")
                index += 3
                continue
            if character == '"':
                mode = "string"
                out.append(" ")
                index += 1
                continue
            if interpolations and character == "(":
                interpolations[-1][1] += 1
            elif interpolations and character == ")":
                if interpolations[-1][1] == 0:
                    mode = interpolations.pop()[0]
                    out.append(" ")
                    index += 1
                    continue
                interpolations[-1][1] -= 1
            out.append(character)
            index += 1
            continue
        if character == "\\" and index + 1 < size:
            if text[index + 1] == "(":
                interpolations.append([mode, 0])
                mode = "code"
                out.append("  ")
            else:
                out.append(" \n" if text[index + 1] == "\n" else "  ")
            index += 2
            continue
        if mode == "string" and character in '"\n':
            mode = "code"
        elif mode == "multiline" and text.startswith('"""', index):
            mode = "code"
            out.append("   ")
            index += 3
            continue
        out.append("\n" if character == "\n" else " ")
        index += 1
    return "".join(out)


TYPE_OR_BRACE = re.compile(r"\b(?:class|extension|struct|enum|actor|protocol)\s+([A-Za-z_][\w.]*)|[{}]")
NOT_TYPE_NAMES = {"func", "var", "let", "subscript", "init", "deinit", "case", "where"}


def body_owners(code):
    """For each line, the type whose body directly holds its start, or None."""
    stack, pending, owners = [], None, []
    for line in code:
        owners.append(stack[-1] if stack else None)
        for match in TYPE_OR_BRACE.finditer(line):
            if match.group(1):
                name = match.group(1).split(".")[-1]
                if name not in NOT_TYPE_NAMES:
                    pending = name
            elif match.group(0) == "{":
                stack.append(pending)
                pending = None
            elif stack:
                stack.pop()
    return owners


def parse_member(member):
    """('func'|'var'|'init'|'subscript', name, labels or None) from a simplified demangling."""
    member = re.sub(r"^static\s+", "", member)
    match = re.search(r"\.([^.()]+)\.(getter|setter|modify|_modify)$", member)
    if match:
        return ("var", match.group(1), None)
    match = re.search(r"\.([^.()]+|init|subscript)\(([^()]*)\)$", member)
    if not match:
        return None
    name, raw = match.group(1), match.group(2)
    labels = [label for label in raw.split(":") if label != ""] if raw else []
    if name == "init":
        return ("init", name, labels)
    if name == "subscript":
        return ("subscript", name, labels)
    return ("func", name, labels)


def declared_labels(lines, index, paren):
    """The argument labels of the declaration whose parameter list opens at lines[index][paren]."""
    text = lines[index][paren:]
    following = index + 1
    while text.count("(") > text.count(")") and following < len(lines) and following < index + 40:
        text += " " + lines[following]
        following += 1
    # Arrows, shifts and comparisons are no brackets.
    text = re.sub(r"->|<<|>>|<=|>=", "  ", text)
    depth, current, parameters = 0, "", []
    for character in text:
        if character in "([<":
            depth += 1
            if depth == 1 and character == "(":
                continue
        elif character in ")]>":
            depth -= 1
            if depth == 0:
                parameters.append(current)
                break
        if depth == 1 and character == ",":
            parameters.append(current)
            current = ""
        elif depth >= 1:
            current += character
    labels = []
    for parameter in parameters:
        head = parameter.split(":", 1)[0].split()
        head = [word for word in head if not word.startswith("@")]
        if head:
            labels.append(head[0])
    return labels


def attributes_before(lines, index):
    """The declaration line with the attribute-only lines right above it."""
    text = lines[index]
    above = index - 1
    while above >= 0 and re.match(r"\s*@\w+(\([^)]*\))?\s*$", lines[above]):
        text = lines[above] + " " + text
        above -= 1
    return text


# --- the audit ---------------------------------------------------------------

def apple_chain(probe, name):
    chain = []
    while name and name not in chain:
        chain.append(name)
        name = probe["super"].get(name)
    return chain


def protocol_optionals(record, into):
    for kind, selector in record["optional"]:
        into.add((kind, selector, record["name"]))
    for parent in record["parents"]:
        protocol_optionals(parent, into)


def probe_protocol_optionals(probe, name, into, seen):
    if name in seen:
        return
    seen.add(name)
    for kind, selector in probe["protocol_optional"].get(name, ()):
        into.add((kind, selector, name))
    for parent in probe["protocol_parents"].get(name, ()):
        probe_protocol_optionals(probe, parent, into, seen)


def externals(binaries):
    names = set()
    for binary in binaries:
        for record in binary.classes.values():
            if isinstance(record["super"], tuple):
                names.add(objc_class_symbol(record["super"][1]))
        names.update(binary.external_categories)
    return sorted(names)


def compiler_made(member):
    """Initializers, deinitializers and the ivar destroyer, whose selectors Swift picks."""
    return bool(member) and re.search(r"(\.init\(|__deallocating_deinit|__ivar_destroyer|\.deinit$)", member) is not None


def audit(binary, probe, actions, sources, baseline):
    findings = []
    known_optionals = set()
    for protocol in binary.protocols:
        protocol_optionals(protocol, known_optionals)
    seen = set()
    for name in probe["protocol_optional"]:
        probe_protocol_optionals(probe, name, known_optionals, seen)
    for record in sorted(binary.classes.values(), key=lambda r: r["name"]):
        if not is_ours(record):
            continue
        # The superclasses in this binary, then the Apple chain the probe printed.
        ancestors_instance, ancestors_class = {}, {}
        declared, inherited = set(), set()
        protocols = list(record["protocols"])
        current = record["super"]
        apple_root = None
        while isinstance(current, int) and current in binary.classes:
            ancestor = binary.classes[current]
            for selector, _ in ancestor["instance"]:
                ancestors_instance.setdefault(selector, ancestor["name"])
            for selector, _ in ancestor["class"]:
                ancestors_class.setdefault(selector, ancestor["name"])
            protocols += ancestor["protocols"]
            current = ancestor["super"]
        if isinstance(current, tuple):
            apple_root = objc_class_symbol(current[1])
        for protocol in protocols:
            protocol_optionals(protocol, declared)
        apple = apple_chain(probe, apple_root) if apple_root else []
        if apple_root and apple_root in probe["missing"]:
            findings.append(("unprobed", record["name"], apple_root, None, None, "the probe found no such class"))
        seen = set()
        for name in apple:
            for selector in probe["instance"].get(name, ()):
                ancestors_instance.setdefault(selector, name)
            for selector in probe["class"].get(name, ()):
                ancestors_class.setdefault(selector, name)
            for category in binary.external_categories.get(name, ()):
                for selector, _ in category["instance"]:
                    ancestors_instance.setdefault(selector, f"{name} (category {category['name']} in this binary)")
                for selector, _ in category["class"]:
                    ancestors_class.setdefault(selector, f"{name} (category {category['name']} in this binary)")
            for protocol in probe["protocols"].get(name, ()):
                probe_protocol_optionals(probe, protocol, inherited, seen)
        # A class object answers its root class's instance methods too.
        if apple:
            for selector in probe["instance"].get(apple[-1], ()):
                ancestors_class.setdefault(selector, apple[-1] + " (root class)")
        apple_instance = set().union(*(probe["instance"].get(n, set()) for n in apple)) if apple else set()
        apple_class = set().union(*(probe["class"].get(n, set()) for n in apple)) if apple else set()
        is_final = record["simple"].split(".")[-1] in sources.final
        is_responder = "UIResponder" in apple
        is_nsobject = bool(apple) and apple[-1] == "NSObject"
        old = baseline.get(record["raw_name"], set()) if baseline is not None else None

        for kind, own, ancestors, apple_side in (("-", record["instance"], ancestors_instance, apple_instance),
                                                 ("+", record["class"], ancestors_class, apple_class)):
            for selector, imp in own:
                member = binary.member(imp)
                is_new = old is not None and (kind, selector) not in old
                swift = member and not member.startswith(("-[", "+["))
                declarations = sources.declaration(record["simple"], member) if swift else []
                overrides = any(re.search(r"\boverride\b", d[3]) for d in declarations)
                explicit = any(re.search(r"@objc\b", d[3]) for d in declarations)
                made = compiler_made(member)
                where = sources.relative(declarations[0][0]) + f":{declarations[0][1]}" if declarations else "source not found"
                context = (member or "no symbol", where, is_new)
                if made:
                    continue
                if selector in ancestors and not overrides:
                    findings.append(("collision", record["name"], kind + selector, context, ancestors[selector], ""))
                elif selector in ancestors:
                    STATS["overrides declared in the source"] += 1
                if not declarations:
                    STATS["members whose declaration was not found"] += 1
                if selector in FORBIDDEN and not overrides:
                    findings.append(("forbidden", record["name"], kind + selector, context, None, "the runtime calls it by name"))
                elif is_nsobject and selector in NSOBJECT_DESCRIPTIONS and not overrides:
                    findings.append(("forbidden", record["name"], kind + selector, context, None, "NSObject's description"))
                elif in_family(selector) and not overrides:
                    findings.append(("forbidden", record["name"], kind + selector, context, None, f"{in_family(selector)} method family"))
                if is_responder and kind == "-" and selector in actions and not overrides:
                    findings.append(("forbidden", record["name"], kind + selector, context, None, "UIResponder edit action"))
                wanted = "i" if kind == "-" else "c"
                if overrides:
                    base = ancestors.get(selector, "")
                    dynamic = any(re.search(r"\bdynamic\b", d[3]) for d in declarations)
                    if is_final and not dynamic and selector not in apple_side and module_of(base).lower().startswith("apelin"):
                        findings.append(("direct", record["name"], kind + selector, context, base,
                                         "an override in a final class: Swift calls it directly through this type unless it is dynamic"))
                    continue
                matches = {protocol for o_kind, o_selector, protocol in declared | inherited | known_optionals
                           if o_selector == selector and o_kind == wanted}
                if not matches:
                    continue
                if any((wanted, selector, p) in declared for p in matches):
                    # A witness of a protocol the Swift class declares: Swift makes it @objc anyway.
                    if not is_new:
                        continue
                    note = "witness of a declared protocol, new since the baseline"
                elif old is not None:
                    if not is_new:
                        continue
                    note = "new since the baseline"
                elif not explicit:
                    continue
                else:
                    note = "the class does not declare the protocol"
                findings.append(("optional", record["name"], kind + selector, context, ", ".join(sorted(matches)), note))
    # Category methods of ours on Apple classes replace what the class answered.
    for name, categories in sorted(binary.external_categories.items()):
        apple = apple_chain(probe, name)
        instance = set().union(*(probe["instance"].get(n, set()) for n in apple)) if apple else set()
        class_side = set().union(*(probe["class"].get(n, set()) for n in apple)) if apple else set()
        for category in categories:
            if not category["name"].lower().startswith("apelin"):
                continue
            for kind, own, answered in (("-", category["instance"], instance), ("+", category["class"], class_side)):
                for selector, imp in own:
                    member = binary.member(imp)
                    is_new = baseline is not None and (kind, selector) not in baseline.get("category " + name, set())
                    context = (member or "no symbol", "category " + category["name"], is_new)
                    if selector in answered:
                        findings.append(("collision", name, kind + selector, context, name + " itself", "a category replaces it"))
                    else:
                        findings.append(("category", name, kind + selector, context, None, "a category method on an Apple class"))
    return findings


def class_selectors(path):
    """{class name: {(kind, selector)}}, our categories on Apple classes as 'category <class>'."""
    classes, categories, _ = read_classes(MachO(path))
    table = {}
    for record in classes.values():
        table[record["raw_name"]] = {("-", s) for s, _ in record["instance"]} | {("+", s) for s, _ in record["class"]}
    for name, found in categories.items():
        table["category " + name] = {("-", s) for c in found for s, _ in c["instance"]} | {("+", s) for c in found for s, _ in c["class"]}
    return table


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    ext = sub.add_parser("externals")
    ext.add_argument("binaries", nargs="+")
    run = sub.add_parser("audit")
    run.add_argument("--probe", required=True)
    run.add_argument("--responder-header", required=True)
    run.add_argument("--source-root", required=True)
    run.add_argument("--baseline-dir")
    run.add_argument("--products", required=True)
    run.add_argument("binaries", nargs="+")
    arguments = parser.parse_args()

    if arguments.command == "externals":
        print("\n".join(externals([Binary(path) for path in arguments.binaries])))
        return 0

    probe = read_probe(arguments.probe)
    actions = responder_actions(arguments.responder_header)
    sources = Sources(arguments.source_root)
    total = collections.Counter()
    for path in arguments.binaries:
        binary = Binary(path)
        baseline = None
        if arguments.baseline_dir:
            relative = os.path.relpath(path, arguments.products)
            old_path = os.path.join(arguments.baseline_dir, relative)
            baseline = class_selectors(old_path) if os.path.exists(old_path) else {}
        ours = [r for r in binary.classes.values() if is_ours(r)]
        selectors = sum(len(r["instance"]) + len(r["class"]) for r in ours)
        print(f"== {os.path.relpath(path, arguments.products)}: {len(ours)} classes of ours, {selectors} selectors")
        unnamed = sum(1 for r in ours for _, imp in r["instance"] + r["class"] if binary.member(imp) is None)
        if unnamed:
            # Without the member's name, an override cannot be told from a collision.
            print(f"error: {unnamed} of its methods have no symbol: the binary is stripped and no dSYM "
                  f"of its UUID is beside it (<binary>.dSYM or <bundle>.dSYM)", file=sys.stderr)
            return 2
        findings = audit(binary, probe, actions, sources, baseline)
        for kind, class_name, selector, context, other, note in findings:
            reason = ACCEPTED.get((class_name.split(".")[-1], selector))
            if reason:
                kind, note = "accepted", reason
            total[kind] += 1
            if context and context[2]:
                total["NEW"] += 1
            if context:
                member, where, is_new = context
                tag = " NEW" if is_new else ""
                detail = f"{member} ({where})"
            else:
                tag, detail = "", ""
            extra = f" also answered by {other}" if kind == "collision" else (f" optional in {other}" if kind == "optional" else "")
            print(f"{kind}{tag}: {class_name} {selector} {detail}{extra}{(' — ' + note) if note else ''}")
    print("== checked: " + ", ".join(f"{k} {v}" for k, v in sorted(STATS.items())))
    print("== totals: " + ", ".join(f"{k} {v}" for k, v in sorted(total.items())) if total else "== no findings")
    return 1 if any(k != "accepted" for k in total) else 0


if __name__ == "__main__":
    sys.exit(main())
