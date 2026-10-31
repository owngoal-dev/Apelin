"""Reference implementation of Documents/Schemas/README.md.

The app and the session host implement the same rules in Swift; this module is
what the fixtures, the extension packager and the template check run on the
Mac, and the yardstick the Swift side is tested against. Standard library only:
the JSON Schema keywords the two schemas use are validated here, and an
unknown keyword is an error rather than silently passing.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import stat
from pathlib import Path
from typing import Any

from apelin_schema_validator import SchemaError, Validator  # noqa: F401

SCHEMA_DIRECTORY = Path(__file__).resolve().parent.parent
PROJECT_SCHEMA = SCHEMA_DIRECTORY / "apelin-project.schema.json"
MANIFEST_SCHEMA = SCHEMA_DIRECTORY / "extension-manifest.schema.json"


_MAXIMUM_INTEGER = 2**53 - 1


def load_json(path: Path) -> Any:
    with open(path, "rb") as handle:
        return parse_json(handle.read(), path)


def parse_json(data: bytes, path: Any = "document") -> Any:
    """The strict reader: README ▸ Common rules ▸ JSON. `path` names it in a refusal."""
    if data.startswith(b"\xef\xbb\xbf"):
        raise ValueError(f"{path}: a byte order mark is not allowed")

    def reject_duplicates(pairs):
        seen = {}
        for key, value in pairs:
            if key in seen:
                raise ValueError(f"{path}: duplicate member {key!r}")
            seen[key] = value
        return seen

    def reject_float(text):
        raise ValueError(f"{path}: non-integer number {text} is not allowed")

    def bounded_integer(text):
        value = int(text)
        if abs(value) > _MAXIMUM_INTEGER:
            raise ValueError(f"{path}: integer {text} is outside ±(2^53-1)")
        return value

    # parse_constant takes NaN, Infinity and -Infinity, which json reads as floats.
    return json.loads(data.decode("utf-8"), object_pairs_hook=reject_duplicates, parse_float=reject_float,
                      parse_int=bounded_integer, parse_constant=reject_float)


def validate_project(document: Any) -> list[str]:
    errors = Validator(load_json(PROJECT_SCHEMA)).errors(document)
    if not errors:
        errors = project_semantic_errors(document)
    return errors


def validate_manifest(document: Any) -> list[str]:
    errors = Validator(load_json(MANIFEST_SCHEMA)).errors(document)
    if not errors:
        errors = manifest_semantic_errors(document)
    return errors


# --------------------------------------------------------------------------
# Rules JSON Schema cannot say (README ▸ Checks beyond the schema)
# --------------------------------------------------------------------------

_STEP_ORDER = {"compile": 0, "link": 1, "bundle-resources": 2, "lipo": 3, "dsym": 4, "strip": 5, "sign": 6}


def project_semantic_errors(project: dict) -> list[str]:
    errors: list[str] = []
    products = {p["id"]: p for p in project["products"]}
    if len(products) != len(project["products"]):
        errors.append("/products: product ids must be unique")
    names = [p["name"] for p in project["products"]]
    if len(set(names)) != len(names):
        errors.append("/products: product names must be unique")
    seen: dict[str, list[str]] = {pid: [] for pid in products}
    script_ids = set()
    for index, step in enumerate(project["build"]["steps"]):
        where = f"/build/steps/{index}"
        if step["type"] == "script":
            if step["id"] in script_ids:
                errors.append(f"{where}: script id {step['id']} is used twice")
            script_ids.add(step["id"])
            continue
        pid = step["product"]
        if pid not in products:
            errors.append(f"{where}: unknown product {pid}")
            continue
        done = seen[pid]
        if step["type"] in done:
            errors.append(f"{where}: {step['type']} appears twice for {pid}")
        if done and _STEP_ORDER[step["type"]] < _STEP_ORDER[done[-1]]:
            errors.append(f"{where}: {step['type']} cannot follow {done[-1]} for {pid}")
        if step["type"] == "bundle-resources" and products[pid]["type"] not in ("app", "bundle"):
            errors.append(f"{where}: bundle-resources is only for app and bundle products")
        done.append(step["type"])
    for pid, done in seen.items():
        for required in ("compile", "link", "lipo", "sign"):
            if required not in done:
                errors.append(f"/build/steps: {pid} has no {required} step")
        if products[pid]["type"] in ("app", "bundle") and "bundle-resources" not in done:
            errors.append(f"/build/steps: {pid} has no bundle-resources step")
        if done and done[-1] != "sign":
            errors.append(f"/build/steps: sign must be the last step for {pid}")
    package = project["package"]
    for index, entry in enumerate(package["layout"]):
        if "product" in entry and entry["product"] not in products:
            errors.append(f"/package/layout/{index}: unknown product {entry['product']}")
    paths = [e["path"] for e in package["layout"]]
    if len(set(paths)) != len(paths):
        errors.append("/package/layout: two entries install to the same path")
    for relation in package.get("depends", []):
        if any(alternative.split(" ")[0] == "firmware" for alternative in relation.split(" | ")):
            errors.append("/package/depends: firmware is added from deploymentTarget by the packager")
    if "tweakFilter" in package:
        dylib = package["tweakFilter"]["dylib"]
        if products.get(dylib, {}).get("type") != "dylib":
            errors.append("/package/tweakFilter/dylib: must name a dylib product")
        elif not any(e.get("product") == dylib and e["path"].startswith("/Library/MobileSubstrate/DynamicLibraries/")
                     for e in package["layout"]):
            errors.append("/package/tweakFilter: the dylib must be installed under /Library/MobileSubstrate/DynamicLibraries/")
    bootstraps = set(project["architectures"])
    for key in package.get("dependsByBootstrap", {}):
        if key not in bootstraps:
            errors.append(f"/package/dependsByBootstrap/{key}: the project does not build for {key}")
    is_swift = project["language"] == "swift"
    for index, product in enumerate(project["products"]):
        for source in product["sources"]:
            suffix = os.path.splitext(source)[1]
            if is_swift and suffix != ".swift":
                errors.append(f"/products/{index}/sources: a Swift project compiles .swift sources only in v1")
            elif not is_swift and suffix not in (".c", ".m"):
                errors.append(f"/products/{index}/sources: {source} is not a .c or .m source")
    return errors


def manifest_semantic_errors(manifest: dict) -> list[str]:
    errors: list[str] = []
    ids = [t["id"] for t in manifest["templates"]]
    if len(set(ids)) != len(ids):
        errors.append("/templates: template ids must be unique")
    for index, template in enumerate(manifest["templates"]):
        if template["directory"] != f"templates/{template['id']}":
            errors.append(f"/templates/{index}/directory: must be templates/{template['id']}")
        names = [p["name"] for p in template["parameters"]]
        if len(set(names)) != len(names):
            errors.append(f"/templates/{index}/parameters: parameter names must be unique")
        for name in names:
            if name in BUILTIN_PARAMETERS:
                errors.append(f"/templates/{index}/parameters: {name} is a built-in parameter")
        paths = [f["path"] for f in template["files"]]
        if len(set(paths)) != len(paths):
            errors.append(f"/templates/{index}/files: a path is listed twice")
        if "apelin-project.json" not in paths:
            errors.append(f"/templates/{index}/files: apelin-project.json is not listed")
        if template["language"] not in manifest["requirements"]["languages"]:
            errors.append(f"/templates/{index}/language: not in requirements.languages")
    scopes = {f"template:{t}" for t in ids} | {f"support:{s}" for s in manifest.get("support", {})} | {"manifest"}
    for index, entry in enumerate(manifest["provenance"]):
        if entry["scope"] not in scopes:
            errors.append(f"/provenance/{index}/scope: names nothing in this manifest")
    covered = {s for lic in manifest["licenses"] for s in lic["covers"]}
    for scope in scopes - {"manifest"}:
        if scope not in covered:
            errors.append(f"/licenses: nothing covers {scope}")
    for scope in covered:
        if scope not in scopes:
            errors.append(f"/licenses: {scope} names nothing in this manifest")
    bootstraps = set(manifest["requirements"]["bootstraps"])
    if set(manifest["requirements"]["architectures"]) != bootstraps:
        errors.append("/requirements/architectures: must have exactly the bootstraps listed")
    return errors


# --------------------------------------------------------------------------
# Canonical JSON (RFC 8785) and digests
# --------------------------------------------------------------------------


def _jcs_string(text: str) -> str:
    out = ['"']
    for ch in text:
        code = ord(ch)
        if 0xD800 <= code <= 0xDFFF:
            raise ValueError("a lone surrogate cannot be canonicalised")
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "\b":
            out.append("\\b")
        elif ch == "\f":
            out.append("\\f")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif code < 0x20:
            out.append(f"\\u{code:04x}")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def canonical_json(value: Any) -> bytes:
    """RFC 8785 for the value space Apelin allows: no non-integer numbers."""

    def encode(v: Any) -> str:
        if v is None:
            return "null"
        if v is True:
            return "true"
        if v is False:
            return "false"
        if isinstance(v, int):
            if abs(v) > _MAXIMUM_INTEGER:
                raise ValueError("an integer outside ±(2^53-1) cannot be canonicalised")
            return str(v)
        if isinstance(v, float):
            raise ValueError("non-integer numbers are not part of Apelin documents")
        if isinstance(v, str):
            return _jcs_string(v)
        if isinstance(v, list):
            return "[" + ",".join(encode(x) for x in v) + "]"
        if isinstance(v, dict):
            keys = sorted(v, key=lambda k: k.encode("utf-16-be"))
            return "{" + ",".join(_jcs_string(k) + ":" + encode(v[k]) for k in keys) + "}"
        raise ValueError(f"cannot canonicalise {type(v).__name__}")

    return encode(value).encode("utf-8")


def sha256_tag(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def digest_of(document: Any) -> str:
    return sha256_tag(canonical_json(document))


# --------------------------------------------------------------------------
# Written form of apelin-project.json
# --------------------------------------------------------------------------


def manifest_text(document: Any) -> bytes:
    """apelin-project.json as Apelin writes it (README ▸ Written form)."""
    return (json.dumps(document, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def formatted_manifest(data: bytes) -> bytes | None:
    """data in the written form, or None when it does not read strictly."""
    try:
        return manifest_text(parse_json(data))
    except ValueError:
        # A lone surrogate reads here and only fails as UTF-8, a ValueError too.
        return None


def read_inside(root: Path, relative: str) -> bytes:
    """Read a regular file that realpaths to somewhere under root."""
    if "\0" in relative:
        raise ValueError("embedded NUL")
    real_root = os.path.realpath(root)
    real = os.path.realpath(os.path.join(real_root, relative))
    if os.path.commonpath([real_root, real]) != real_root or real == real_root:
        raise ValueError(f"{relative} resolves outside {root}")
    info = os.stat(real)
    if not stat.S_ISREG(info.st_mode):
        raise ValueError(f"{relative} is not a regular file")
    with open(real, "rb") as handle:
        return handle.read()


_BUILD_PROJECT_MEMBERS = ("kind", "language", "deploymentTarget", "architectures", "configurations")
_PRODUCT_INPUT_MEMBERS = ("sources", "headerSearchPaths", "resources")


def build_description(project: dict, root: Path) -> dict:
    selected: dict = {k: project[k] for k in _BUILD_PROJECT_MEMBERS if k in project}
    selected["products"] = [
        {k: v for k, v in product.items() if k not in _PRODUCT_INPUT_MEMBERS} for product in project["products"]
    ]
    selected["build"] = project["build"]
    files: dict[str, str] = {}
    for product in project["products"]:
        if "entitlements" in product:
            files[product["entitlements"]] = sha256_tag(read_inside(root, product["entitlements"]))
    for step in project["build"]["steps"]:
        if step["type"] == "script":
            files[step["file"]] = sha256_tag(read_inside(root, step["file"]))
    return {"description": "apelin.build", "version": 1, "project": selected, "files": files}


def packaging_description(project: dict, root: Path) -> dict:
    package = {k: v for k, v in project["package"].items() if k != "version"}
    files: dict[str, str] = {}
    for path in project["package"].get("maintainerScripts", {}).values():
        files[path] = sha256_tag(read_inside(root, path))
    for entry in project["package"]["layout"]:
        if "file" in entry:
            files[entry["file"]] = sha256_tag(read_inside(root, entry["file"]))
    return {
        "description": "apelin.packaging",
        "version": 1,
        "project": {"kind": project["kind"], "package": package},
        "files": files,
    }


def project_digests(project_root: Path) -> dict:
    project = load_json(project_root / "apelin-project.json")
    errors = validate_project(project)
    if errors:
        raise ValueError("; ".join(errors))
    build = build_description(project, project_root)
    packaging = packaging_description(project, project_root)
    build_bytes = canonical_json(build)
    packaging_bytes = canonical_json(packaging)
    return {
        "build": {"canonical": build_bytes.decode("utf-8"), "digest": sha256_tag(build_bytes)},
        "packaging": {"canonical": packaging_bytes.decode("utf-8"), "digest": sha256_tag(packaging_bytes)},
    }


# --------------------------------------------------------------------------
# Templates: digest, placeholder rules, instantiation
# --------------------------------------------------------------------------

TOKEN = re.compile(r"\{\{([a-z][A-Za-z0-9]*)\}\}")

# Built-in parameters the IDE always supplies. Their types decide where they
# may appear, exactly like declared ones.
BUILTIN_PARAMETERS = {
    "projectName": "projectName",
    "projectID": "uuid",
    "bundleID": "bundleID",
    "packageID": "packageID",
    "deploymentTarget": "deploymentTarget",
    "architectures": "architectureMap",
    "templateExtensionID": "packageID",
    "templateID": "identifierDashed",
    "templateVersion": "version",
    "templateDigest": "digest",
    "toolchainID": "registrationID",
    "toolchainDigest": "digest",
    "sdkID": "registrationID",
    "sdkDigest": "digest",
}

# \Z, not $: Python's $ also matches before a final newline, so "Foo\n" would pass as an identifier.
_TYPE_PATTERNS = {
    "projectName": r"^[^/\x00-\x1f\x7f.][^/\x00-\x1f\x7f]{0,63}\Z",
    "identifier": r"^[A-Za-z_][A-Za-z0-9_]{0,63}\Z",
    "identifierDashed": r"^[a-z][a-z0-9-]{0,63}\Z",
    "bundleID": r"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+\Z",
    "packageID": r"^[a-z0-9][a-z0-9+.-]+\Z",
    "version": r"^[0-9][0-9A-Za-z.+~-]{0,63}\Z",
    "deploymentTarget": r"^(1[6-9]|[2-9][0-9])\.[0-9]{1,2}(\.[0-9]{1,2})?\Z",
    "uuid": r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z",
    "digest": r"^sha256:[0-9a-f]{64}\Z",
    "registrationID": r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\Z",
    "string": r"^[^\x00-\x08\x0b\x0c\x0e-\x1f\x7f]*\Z",
}
_LIST_ITEM_PATTERNS = {
    "bundleIDList": _TYPE_PATTERNS["bundleID"],
    "executableList": r"^[A-Za-z0-9_][A-Za-z0-9_.+ -]{0,63}\Z",
}

# Types whose every value is safe in a shell script and outside a string
# literal: their alphabet has no quote, space, backslash, dollar, backtick or
# newline.
_SAFE_TYPES = {"identifier", "identifierDashed", "bundleID", "packageID", "version", "deploymentTarget", "uuid", "digest", "registrationID", "enum"}
_PATH_TYPES = {"identifier", "identifierDashed", "bundleID", "packageID", "version"}
_TEXT_TYPES = {"projectName", "string"}
_STRUCTURED_TYPES = {"bundleIDList", "executableList", "architectureMap", "bool"}
_LIST_AND_MAP_TYPES = _STRUCTURED_TYPES - {"bool"}


class TemplateError(Exception):
    pass


def template_digest(template_root: Path, files: list[dict]) -> str:
    entries = []
    for entry in sorted(files, key=lambda f: f["path"].encode("utf-8")):
        data = read_inside(template_root, entry["path"])
        item = {"path": entry["path"], "format": entry["format"], "sha256": hashlib.sha256(data).hexdigest()}
        if "mode" in entry:
            item["mode"] = entry["mode"]
        entries.append(item)
    return digest_of({"description": "apelin.template", "version": 1, "files": entries})


def _parameter_types(template: dict) -> dict[str, dict]:
    types = {name: {"type": kind} for name, kind in BUILTIN_PARAMETERS.items()}
    for parameter in template["parameters"]:
        types[parameter["name"]] = parameter
    return types


def _inside_string(line_prefix: str) -> bool:
    count = 0
    escaped = False
    for ch in line_prefix:
        if escaped:
            escaped = False
        elif ch == "\\":
            escaped = True
        elif ch == '"':
            count += 1
    return count % 2 == 1


def _plist_text_context(text: str, start: int) -> bool:
    """True when the token sits in character data (not inside a tag)."""
    return text.rfind("<", 0, start) <= text.rfind(">", 0, start)


def check_template_text(text: str, file_format: str, types: dict[str, dict], where: str) -> list[str]:
    errors: list[str] = []
    if file_format == "copy":
        return errors
    for match in TOKEN.finditer(text):
        name = match.group(1)
        if name not in types:
            errors.append(f"{where}: {{{{{name}}}}} names no parameter")
            continue
        kind = types[name]["type"]
        line_start = text.rfind("\n", 0, match.start()) + 1
        prefix = text[line_start:match.start()]
        in_string = _inside_string(prefix)
        if file_format in ("c", "objc", "swift"):
            if kind in _TEXT_TYPES and not in_string:
                errors.append(f"{where}: {{{{{name}}}}} ({kind}) may only appear inside a string literal")
            elif kind in _LIST_AND_MAP_TYPES:
                errors.append(f"{where}: {{{{{name}}}}} ({kind}) cannot appear in source code")
        elif file_format == "json":
            if kind in _STRUCTURED_TYPES and in_string:
                errors.append(f"{where}: {{{{{name}}}}} ({kind}) is a JSON value and must not be quoted")
            elif kind not in _STRUCTURED_TYPES and not in_string:
                errors.append(f"{where}: {{{{{name}}}}} ({kind}) must appear inside a JSON string")
        elif file_format == "plist-xml":
            if not _plist_text_context(text, match.start()):
                errors.append(f"{where}: {{{{{name}}}}} may only appear in plist character data")
            if kind == "architectureMap":
                errors.append(f"{where}: {{{{{name}}}}} ({kind}) cannot appear in a plist")
        elif file_format == "shell":
            if kind not in _SAFE_TYPES:
                errors.append(f"{where}: {{{{{name}}}}} ({kind}) cannot appear in a shell script")
        elif file_format == "deb-control":
            if kind in _LIST_AND_MAP_TYPES:
                errors.append(f"{where}: {{{{{name}}}}} ({kind}) cannot appear in a control file")
        elif file_format == "text":
            if kind in _LIST_AND_MAP_TYPES:
                errors.append(f"{where}: {{{{{name}}}}} ({kind}) cannot appear in text")
    return errors


def check_template_path(path: str, types: dict[str, dict], where: str) -> list[str]:
    errors = []
    for match in TOKEN.finditer(path):
        name = match.group(1)
        kind = types.get(name, {}).get("type")
        if kind is None:
            errors.append(f"{where}: {{{{{name}}}}} names no parameter")
        elif kind not in _PATH_TYPES:
            errors.append(f"{where}: {{{{{name}}}}} ({kind}) cannot appear in a file name")
    return errors


def validate_value(name: str, parameter: dict, value: Any) -> None:
    kind = parameter["type"]
    if kind == "bool":
        if not isinstance(value, bool):
            raise TemplateError(f"{name}: expected true or false")
        return
    if kind == "architectureMap":
        if not isinstance(value, dict) or not value or set(value) - {"rootless", "roothide"}:
            raise TemplateError(f"{name}: expected an object keyed by rootless and/or roothide")
        for archs in value.values():
            if not isinstance(archs, list) or not archs or len(set(archs)) != len(archs) or set(archs) - {"arm64", "arm64e"}:
                raise TemplateError(f"{name}: architectures are arm64 and arm64e, each at most once")
        return
    if kind in _LIST_ITEM_PATTERNS:
        if not isinstance(value, list) or not value or len(value) > 32:
            raise TemplateError(f"{name}: expected a list of 1 to 32 items")
        for item in value:
            if not isinstance(item, str) or not re.search(_LIST_ITEM_PATTERNS[kind], item):
                raise TemplateError(f"{name}: {item!r} is not valid")
        return
    if not isinstance(value, str):
        raise TemplateError(f"{name}: expected a string")
    if kind == "enum":
        if value not in parameter["values"]:
            raise TemplateError(f"{name}: {value!r} is not one of {parameter['values']}")
        return
    if not re.search(_TYPE_PATTERNS[kind], value):
        raise TemplateError(f"{name}: {value!r} is not a valid {kind}")
    limit = parameter.get("maxLength", 200)
    if len(value) > limit:
        raise TemplateError(f"{name}: longer than {limit}")


def _escape(value: Any, kind: str, file_format: str) -> str:
    if kind == "bool":
        if file_format in ("c", "objc"):
            return "1" if value else "0"
        if file_format == "plist-xml":
            return "<true/>" if value else "<false/>"
        return "true" if value else "false"
    if kind == "architectureMap":
        return json.dumps({k: value[k] for k in ("rootless", "roothide") if k in value}, separators=(", ", ": "))
    if kind in _LIST_ITEM_PATTERNS:
        if file_format == "json":
            return json.dumps(value, ensure_ascii=False, separators=(", ", ": "))
        if file_format == "plist-xml":
            return "".join(f"<string>{_xml(v)}</string>" for v in value)
        raise TemplateError(f"{kind} cannot be written in {file_format}")
    if file_format in ("c", "objc", "swift"):
        out = []
        for ch in value:
            if ch == "\\":
                out.append("\\\\")
            elif ch == '"':
                out.append('\\"')
            elif ch == "\n":
                out.append("\\n")
            elif ch == "\r":
                out.append("\\r")
            elif ch == "\t":
                out.append("\\t")
            else:
                out.append(ch)
        return "".join(out)
    if file_format == "json":
        return json.dumps(value, ensure_ascii=False)[1:-1]
    if file_format == "plist-xml":
        return _xml(value)
    if file_format in ("deb-control", "text"):
        if any(ord(c) < 0x20 or ord(c) == 0x7F for c in value):
            raise TemplateError("a control-file or text value must be a single line")
        return value
    if file_format == "shell":
        if not re.fullmatch(r"[A-Za-z0-9._+:~-]+", value):
            raise TemplateError(f"{value!r} is not shell-safe")
        return value
    raise TemplateError(f"no substitution in {file_format}")


def _xml(text: str) -> str:
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;").replace("'", "&apos;"))


def substitute(text: str, file_format: str, types: dict[str, dict], values: dict[str, Any]) -> str:
    def replace(match: re.Match) -> str:
        name = match.group(1)
        return _escape(values[name], types[name]["type"], file_format)

    return TOKEN.sub(replace, text)


def check_template(extension_root: Path, template: dict) -> list[str]:
    """Everything the IDE checks about a template at scan time."""
    errors: list[str] = []
    root = extension_root / template["directory"]
    types = _parameter_types(template)
    declared = {f["path"] for f in template["files"]}
    on_disk = set()
    for dirpath, dirnames, filenames in os.walk(root):
        for name in filenames + [d for d in dirnames if os.path.islink(os.path.join(dirpath, d))]:
            full = os.path.join(dirpath, name)
            relative = os.path.relpath(full, root)
            if os.path.islink(full):
                errors.append(f"{template['id']}: {relative} is a symbolic link")
            on_disk.add(relative)
    for missing in sorted(declared - on_disk):
        errors.append(f"{template['id']}: {missing} is listed but missing")
    for extra in sorted(on_disk - declared):
        errors.append(f"{template['id']}: {extra} is not listed in the manifest")
    for entry in template["files"]:
        where = f"{template['id']}/{entry['path']}"
        errors += check_template_path(entry["path"], types, where)
        # A missing or linked file is already an error above; a link may lead outside or to a directory.
        if entry["path"] not in on_disk or os.path.islink(root / entry["path"]):
            continue
        data = read_inside(root, entry["path"])
        if entry["format"] != "copy":
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                errors.append(f"{where}: not UTF-8; use format copy")
                continue
            errors += check_template_text(text, entry["format"], types, where)
    for parameter in template["parameters"]:
        if "default" in parameter:
            try:
                validate_value(parameter["name"], parameter, parameter["default"])
            except TemplateError as error:
                errors.append(f"{template['id']}: default {error}")
    if not errors:
        actual = template_digest(root, template["files"])
        if actual != template["digest"]:
            errors.append(f"{template['id']}: digest is {actual}, manifest says {template['digest']}")
    return errors


def instantiate(extension_root: Path, manifest: dict, template: dict, values: dict[str, Any], destination: Path) -> None:
    """Write the template into destination, which must not exist yet, apelin-project.json in its written form."""
    if destination.exists():
        raise TemplateError(f"{destination} already exists")
    types = _parameter_types(template)
    resolved: dict[str, Any] = {}
    for name, parameter in types.items():
        if name in values:
            resolved[name] = values[name]
        elif "default" in parameter:
            resolved[name] = parameter["default"]
        else:
            raise TemplateError(f"{name}: no value")
        validate_value(name, parameter, resolved[name])
    unknown = set(values) - set(types)
    if unknown:
        raise TemplateError(f"unknown parameters: {sorted(unknown)}")
    root = extension_root / template["directory"]
    staging = destination.with_name("." + destination.name + ".creating")
    staging.mkdir(parents=True)
    try:
        for entry in template["files"]:
            relative = TOKEN.sub(lambda m: resolved[m.group(1)], entry["path"])
            if any(part == "" or part.startswith(".") for part in relative.split("/")):
                raise TemplateError(f"{entry['path']} resolves to an unusable path")
            data = read_inside(root, entry["path"])
            if entry["format"] != "copy":
                data = substitute(data.decode("utf-8"), entry["format"], types, resolved).encode("utf-8")
            target = staging / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            with open(target, "xb") as handle:
                handle.write(data)
            os.chmod(target, 0o755 if entry.get("mode") == "0755" else 0o644)
        project = load_json(staging / "apelin-project.json")
        errors = validate_project(project)
        if errors:
            raise TemplateError("generated apelin-project.json: " + "; ".join(errors))
        (staging / "apelin-project.json").write_bytes(manifest_text(project))
        # Claim the name first: rename replaces an empty directory made since the check above.
        try:
            destination.mkdir()
        except FileExistsError:
            raise TemplateError(f"{destination} already exists") from None
        try:
            os.rename(staging, destination)
        except OSError:
            destination.rmdir()
            raise
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
