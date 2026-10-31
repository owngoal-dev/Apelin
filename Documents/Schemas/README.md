# Apelin schemas

Two documents, both JSON, both versioned, both read and never executed:

| File | Lives at | Schema |
|---|---|---|
| `apelin-project.json` | `~/Documents/wiki.qaq.apelin/Projects/<name>/` | [`apelin-project.schema.json`](apelin-project.schema.json) |
| development extension `manifest.json` | `<install-root>/usr/share/apelin/development/<id>/` | [`extension-manifest.schema.json`](extension-manifest.schema.json) |

The schemas are JSON Schema draft 2020-12. This file is the specification:
where it says more than a schema can, it wins, and the rules marked
**beyond the schema** are checked by `projectCheck` and the extension scanner.
`Tools/apelin_schema.py` is the reference implementation (standard library
only); the Swift side is tested against the same fixtures.

```
Tools/check-fixtures.py              every fixture below, plus the digest edit table
Extensions/Development/check-templates.py   every shipped extension, instantiated and built on the Mac
```

## Common rules

- **JSON.** UTF-8, no byte order mark, no duplicate member names. No
  non-integer numbers anywhere: versions are strings, integers stay within
  ±(2^53−1). A file that breaks any of these is rejected before the schema
  runs.
- **Unknown members are errors.** Every object is closed
  (`additionalProperties: false`). A newer document is refused by
  `schemaVersion`, never half-read.
- **Paths.** A *project path* (`relativePath`) is relative to the project
  root; no component may be empty or start with `.`, so `.` and `..` cannot be
  spelled. A *glob* adds `*` (within a component), `**` (any depth) and `?`.
  Before anything is read through either, it is resolved with `realpath(3)`
  after rejecting an embedded NUL, and refused unless it is still under the
  project root by component comparison. An *install path* (`logicalPath`) is
  how the package sees the bootstrap: rooted at `/`, first component
  `Applications`, `Library`, `usr` or `etc`. The packager maps it per
  bootstrap (`@PREFIX@` is empty on roothide, `/var/jb` on rootless); a
  project never stores a jbroot path, and nothing installs outside the
  bootstrap.
- **Digests** are `sha256:` followed by 64 lowercase hex digits.

## `apelin-project.json`, version 1

The build entry the UI, the agent and `apelin-build` all read. There is no
other hidden configuration.

| Member | Meaning |
|---|---|
| `schemaVersion` | `1`. |
| `projectID` | Lowercase UUID, made at creation. Renaming the folder never changes it; approvals are bound to it. |
| `kind` | `app`, `tweak`, `cli` or `preferences`. Requires a product of type `app`, `dylib` (plus `package.tweakFilter`), `executable` or `bundle` respectively. Only `tweak` may carry `tweakFilter`. |
| `template` | `{extensionID, templateID, version, digest}`: the extension, its version and the template digest (below) the project was generated from. The Confirm baseline. |
| `environment` | `{toolchain, sdk}`, each `{id, digest}`: the registered toolchain and SDK the project is pinned to. Changing either is an explicit operation (the agent's `apelin_project_set_environment`, checked first by `projectCheck` with `environment`); a new default never moves a project. |
| `language` | `c`, `objc` or `swift`. A C-family project compiles `.c` and `.m`; a Swift one `.swift` only (beyond the schema). No mixing in v1. |
| `deploymentTarget` | `16.0` or later, as a string. |
| `architectures` | `{rootless?, roothide?}` → `arm64`/`arm64e` lists. The keys present are the bootstraps the project packages for. Templates default to rootless `[arm64, arm64e]`, roothide `[arm64e]`. |
| `configurations` | `Debug` and `Release`, each `{optimization: "0"…"3"/"s"/"z", debugInfo, defines?, cFlags?, swiftFlags?, linkFlags?}`. A define's name may not start with `APELIN_`. A flag is one argv element starting with `-`; nothing here is ever given to a shell. |
| `products` | 1–8 of `{id, type, name, sources, headerSearchPaths?, resources?, infoPlist?, entitlements?, installName?, objcARC?, frameworks?, weakFrameworks?, libraries?, frameworkSearchPaths?, librarySearchPaths?, extensionSupport?}`. `app` and `bundle` require `infoPlist`; only they may have `resources`; only `dylib` may set `installName` (default `@rpath/<name>.dylib`). `extensionSupport` names `{extension, component}` from an installed extension's manifest; the build adds that component's include directories, link-stub directories for the bootstrap being built and rpaths. Ids and names are unique (beyond the schema). |
| `build.steps` | The typed steps, below. |
| `package` | `{id, name, version, description, longDescription?, icon?, author, maintainer?, section, depends?, dependsByBootstrap?, recommends?, suggests?, conflicts?, breaks?, replaces?, provides?, layout, maintainerScripts?, tweakFilter?}`. |

### Build steps

Each product goes through, in this order, `compile` → `link` →
`bundle-resources` (app and bundle only) → `lipo` → `dsym` → `strip` →
`sign`. `compile`, `link`, `lipo` and `sign` are required; each appears at
most once per product; `sign` is the last step for its product (beyond the
schema). Steps of different products may interleave.

| Step | Does |
|---|---|
| `compile {product, flags?}` | Every source, once per architecture, to an object kept for `dsym`. Swift compiles the module whole, one object per architecture. |
| `link {product, flags?}` | One Mach-O per architecture: `MH_EXECUTE` for app and executable, `MH_DYLIB` for dylib, `MH_BUNDLE` for bundle. |
| `bundle-resources {product}` | Builds the `.app`/`.bundle` directory: the product's Info.plist with `CFBundleExecutable`, `CFBundleShortVersionString`, `CFBundleVersion` and `MinimumOSVersion` set by the build, then each resource flattened to its file name; a `.plist` is linted and written as XML. |
| `lipo {product}` | Merges the slices into the product (inside the bundle for app/bundle). |
| `dsym {product}` | `dsymutil` while the objects exist. Fails on any warning, a dSYM without `__debug_info`, or UUIDs that differ from the product's. |
| `strip {product, style?}` | `non-global` (`strip -x`, default) or `debug` (`strip -S`). Exported symbols stay. |
| `sign {product, identity?}` | Ad-hoc (`identity: "adhoc"`, the only value), with the product's `entitlements` if any. |
| `script {id, interpreter, file, arguments?, inputs?, outputs?, requiresApproval: true}` | The only step that runs project-supplied code: `argv = [<bootstrap interpreter>, file, arguments...]`, as mobile, in the project root. `interpreter` is `sh`, `bash`, `zsh`, `python3` or `perl`, resolved by the host inside the bootstrap. There is no command-string form. `requiresApproval` must be spelled `true` so a reader sees the step is reviewed. |

What `apelin-build` always adds and a project cannot remove: `-isysroot`
with the SDK's physical path, `-mios-version-min` / `-target` from
`deploymentTarget`, `-arch`, `-O<optimization>`, `-g` when `debugInfo`,
`-fobjc-arc` when `objcARC`, `-Werror=unguarded-availability-new`,
`-fvisibility=hidden`, `-ffile-prefix-map=<project>=.` (Swift:
`-debug-prefix-map`), and these definitions on every C-family compile:

| Define | Value |
|---|---|
| `APELIN_BUILD_ID` | String literal, unique per build; the marker `apelin_package_confirm_loaded` matches. |
| `APELIN_PACKAGE_ID`, `APELIN_VERSION`, `APELIN_PRODUCT_NAME` | String literals from `package.id`, `package.version`, the product's `name`. |
| `APELIN_BOOTSTRAP_ROOTLESS` or `APELIN_BOOTSTRAP_ROOTHIDE` | `1`, for the bootstrap being built. |
| `APELIN_CONFIGURATION_DEBUG` or `APELIN_CONFIGURATION_RELEASE` | `1`. |

Swift gets the bootstrap and configuration names as `-D` conditions.

### Packaging

- `layout` entries are `{path, product, mode?}` (the merged, signed Mach-O,
  or the whole `.app`/`.bundle` directory) or `{path, file, mode?,
  substitutePrefix?}` (a project file, copied verbatim, or with `@PREFIX@` and
  `@ROOTFS@` replaced when `substitutePrefix`). `mode` is `0644` or `0755`;
  products default to `0755` for executables, files to `0644`. Two entries may
  not share a path (beyond the schema).
- `Architecture` is not stored: rootless packages are `iphoneos-arm64`,
  roothide `iphoneos-arm64e`. `Depends` is `firmware (>= deploymentTarget)`
  (added by the packager; a `firmware` relation in `depends` is refused),
  then `depends`, then `dependsByBootstrap[<bootstrap>]`, which may only name
  bootstraps the project builds for.
- `icon` is written as the control's `Icon`, the image a package manager
  shows beside the package (not an app's own icon), and nothing is written
  without it: an `https://` URL whose host starts with a letter or digit, in
  printable ASCII, so it has no space or control character, and at most
  2048 characters, which are 2048 bytes. Every template writes its
  extension's icon on Apelin's Pages,
  `https://owngoal-dev.github.io/Apelin/icons/<extension id>.png`; a project
  may keep it, name its own or drop it.
- `maintainerScripts` are project files; the packager substitutes `@PREFIX@`
  and `@ROOTFS@` and nothing else, requires `sh -n` to pass, and the install
  card shows them in full.
- `tweakFilter {dylib, bundles?, executables?, classes?}` (at least one list)
  is written as `<dylib file name without .dylib>.plist`, an XML plist with a
  single `Filter` dictionary, beside the dylib's layout path, which must be
  under `/Library/MobileSubstrate/DynamicLibraries/` (beyond the schema).
- Runtime dependencies of a support component the project uses
  (`extensionSupport`) belong in `depends`; `projectCheck` warns when one is
  missing.

## Approval digests

Confirm mode (Milestone 1 §7) compares descriptions, not sources. Two
descriptions are cut out of the project; each has a digest; the host keeps
the digests, and the description documents themselves to render a diff.

### Build description

```json
{
  "description": "apelin.build",
  "version": 1,
  "project": { …members below, copied as written… },
  "files": { "<project path>": "sha256:<digest of the file's bytes>", … }
}
```

`project` holds exactly these members of `apelin-project.json`, each only if
present: `kind`, `language`, `deploymentTarget`, `architectures`,
`configurations`, `products` (every product, every member **except**
`sources`, `headerSearchPaths` and `resources`), and `build`.

`files` holds every product's `entitlements` file and every `script` step's
`file`.

So a compile or link flag, a define, an optimisation level, a step, a
framework, a library, an extension support component, an install name, an
entitlement or a build script's content each moves the build digest. Editing,
adding or removing a source, header or resource under the existing globs does
not, nor does `template`, `environment`, `projectID` or `package`.

### Packaging description

```json
{
  "description": "apelin.packaging",
  "version": 1,
  "project": { "kind": …, "package": { …package, without "version"… } },
  "files": { "<project path>": "sha256:…", … }
}
```

`files` holds every `maintainerScripts` file and every layout entry's `file`.

So control fields, relations, the install layout, modes, the tweak filter,
a maintainer script or an installed data file each moves the packaging
digest. `package.version` does not: a version bump never asks. The compiled
products are not in it; every install is still bound to the artifact digest
of the build being installed, which the host copies to private staging
before handing it over.

### Canonical form and digest

`digest = "sha256:" + lowercase hex SHA-256 of the RFC 8785 (JCS)
serialisation of the description document, as UTF-8.` With no non-integer
numbers in Apelin documents, JCS here is:

1. No insignificant whitespace.
2. Object members sorted by their names as UTF-16 code units (not code
   points: `U+1F600` sorts before `U+FF61`).
3. Array order kept.
4. Strings: `"` → `\"`, `\` → `\\`, U+0008/0009/000A/000C/000D → `\b \t \n
   \f \r`, other U+0000–U+001F → `\u00xx` (lowercase hex); everything else,
   `/`, DEL and non-ASCII included, as itself. A lone surrogate is an error.
5. `true`, `false`, `null`; integers in shortest decimal form.

The description is cut from the parsed document, so formatting and member
order in the file never matter. Values are taken as written: an omitted
member and the same member spelled with its default value are different
descriptions. A `files` key is the path exactly as the project spells it; a
referenced file that is missing, irregular or resolves outside the project
makes the description uncomputable, which `projectCheck` reports and which
blocks the build or install.

### How the host uses them

At `projectCreate` the host computes both digests of the project exactly as
the template generated it and stores them, with the description documents,
as the approved baseline for that `projectID`, together with
`template.{extensionID, version, digest}`. Under Confirm, a build whose build
digest equals the baseline or a later approval runs; otherwise the first
build after the change asks, showing the diff against the last approved
description, and approval records the new digest. Install does the same with
the packaging digest and the card adds the package id, the artifact digest
and every maintainer script. A later template upgrade does not move an
existing project's baseline. The stored digests live in the host's private
state; neither the agent nor any project file can write them. Relaxed never
asks.

## Extension manifest, version 1

Members, after Milestone 1 §5.2:

| Member | Meaning |
|---|---|
| `schemaVersion`, `id`, `version`, `kind` | `1`; reverse-DNS id equal to the package id and the folder name; `x.y.z` version equal to the package version; one of the four kinds. |
| `displayName`, `summary` | English source text, resolved against the app's catalogue. |
| `apelinCompatibility` | `{minimumAppVersion, projectSchemaVersions, manifestSchemaVersion: 1}`. The packager turns `minimumAppVersion` into `Depends: wiki.qaq.apelin (>= …)`. |
| `requirements` | `{toolchainComponents, languages, sdkFrameworks?, bootstraps, architectures, runtimeDependencies?}`. `architectures` has exactly the `bootstraps` (beyond the schema). `runtimeDependencies` are what packages built from the templates need on the device, per bootstrap, as virtual package names; the extension package depends on them too, so a template that builds also runs. |
| `support` | Named components: `{summary, includeDirectories?, linkStubDirectories?, libraries?, frameworks?, rpaths?, installNames?, symbols?, architectures, runtimeDependencies?, spdx, license}`. Stubs are hand-written `.tbd` link inputs, never loaded. `rpaths` may start with `@PREFIX@`, which the build replaces. `symbols` is the declared compatible set; the stubs declare exactly those and the install names in `installNames`. |
| `templates` | `{id, directory: "templates/<id>", displayName, summary, language, toolchainComponents?, project: "apelin-project.json", parameters, files, digest}`. |
| `provenance` | Per scope (`template:<id>`, `support:<name>`, `manifest`): `origin` `imported` (with `repository`, 40-hex `commit`, upstream `paths`) or `written`, and the `adaptations` made. |
| `licenses` | `{path, spdx, covers}`, MIT / BSD / Apache / 0BSD / MIT-0 only. Every template and support scope is covered (beyond the schema). |

Scanning: the app scans at launch, on return from an install and on a manual
refresh, through the daemon's install root. Each manifest is validated on its
own; a bad manifest, an unknown `schemaVersion`, a duplicate id, a path that
escapes the extension, an undeclared or symlinked template file, or a stale
template digest isolates that extension and the Settings page says why. A
duplicate id isolates both. Nothing named in a manifest is executed.

### Template digest

```
digest = sha256 over JCS({
  "description": "apelin.template", "version": 1,
  "files": [ {"path", "format", "sha256": <hex of the raw file>, "mode"?}, … sorted by path as UTF-8 bytes ]
})
```

taken over the template files **before** substitution. It is recorded in the
manifest and copied into `template.digest` of every project made from it.

### Placeholders

A template file may contain `{{name}}`, where `name` matches
`[a-z][A-Za-z0-9]*` and names a declared parameter or a built-in one. Every
such token is a substitution; v1 has no escape for a literal one. Anything
else with braces is left alone.

Built-in parameters, always supplied by the IDE and not redeclarable:

| Name | Type |
|---|---|
| `projectName` | `projectName`: the folder name — one component, no `/`, NUL, control characters, not `.`/`..`, not starting with `.`, at most 64 characters |
| `projectID` | `uuid` |
| `bundleID` | `bundleID` |
| `packageID` | `packageID` |
| `deploymentTarget` | `deploymentTarget` |
| `architectures` | `architectureMap` |
| `templateExtensionID`, `templateID`, `templateVersion`, `templateDigest` | `packageID`, `identifierDashed`, `version`, `digest` |
| `toolchainID`, `toolchainDigest`, `sdkID`, `sdkDigest` | `registrationID`, `digest` |

Declared parameter types: `identifier` (`[A-Za-z_][A-Za-z0-9_]{0,63}`),
`bundleID`, `packageID`, `version`, `deploymentTarget`, `projectName`,
`string` (text without NUL, DEL or C0 controls other than tab, newline and
CR, up to `maxLength`, default 200), `enum` (one of
`values`), `bool`, `bundleIDList`, `executableList` (1–32 items). Every
parameter needs a value or a `default`; `required` only marks the field.

Each file has a `format`, which decides where a type may appear and how its
value is escaped. Checked when the extension is scanned, so a template that
could produce broken output is never offered:

| Format | Allowed | Escaping |
|---|---|---|
| `c`, `objc`, `swift` | `projectName`/`string` only inside a `"…"` literal on the token's line; safe types (`identifier`, `identifierDashed`, `bundleID`, `packageID`, `version`, `deploymentTarget`, `uuid`, `digest`, `registrationID`, `enum`) anywhere; `bool` anywhere; lists and `architectureMap` nowhere | `\` `"` newline CR tab escaped as in a string literal (in Swift, escaping `\` also defuses `\(`); `bool` → `1`/`0` in C and Objective-C, `true`/`false` in Swift |
| `json` | text and safe types only inside a JSON string; `bool`, lists and `architectureMap` only outside one | JSON string escaping; structured values written as JSON |
| `plist-xml` | in character data only, never inside a tag; not `architectureMap` | XML entities for `& < > " '`; `bool` → `<true/>`/`<false/>`; lists → `<string>` elements |
| `deb-control`, `text` | not lists or `architectureMap` | the value must be a single line |
| `shell` | safe types only | none needed: their alphabets have no quote, space, `$`, backtick, backslash or newline |
| `copy` | nothing | bytes copied as they are |

In a file **path**, only `identifier`, `identifierDashed`, `bundleID`,
`packageID` and `version` may appear, and the substituted path must still
have no empty, `.`-leading or `..` component.

Creation writes into a sibling staging folder on the same file system,
validates the generated `apelin-project.json`, then renames into
`Projects/<name>/`, which must not exist. A failure removes only the staging
folder. No template script runs at creation.

## Fixtures

```
Fixtures/project/valid/              one project per kind, plus cli-with-script
Fixtures/project/invalid/            each with the error it must produce, in expectations.json
Fixtures/extension/valid|invalid/    the same for manifests
Fixtures/canonical-json.json         RFC 8785 vectors
Fixtures/manifest-format.json        the written form (below), and text left as it is
Fixtures/digest/cli-with-script/     a project with every referenced-file kind, and its expected digests
```

`Tools/check-fixtures.py` also runs a table of placeholder rules (which
types each format accepts where) and escaping vectors, then copies the
digest project and applies an edit
table (source edited, new source under a glob, version bumped, members
reordered, written on one line, formatted from one line, toolchain
rebound, flag added, build script edited, entitlements
edited, deployment target raised, postinst edited, installed data file
edited, dependency added, icon set, install path changed), and requires each to move
exactly the digests this file says it moves. `--update` rewrites
`expected.json`; a changed digest changes every project's baseline, so read
that diff before committing it.


### Project display metadata

A v1 project may also carry `displayName` (1–80 characters) and `autoName`
(boolean). They describe the project in the UI, not its build identity. Changing
them does not change the folder, `projectID`, products, package identifiers, or
Confirm approval digests. Generated placeholder names start with `autoName: true`;
a manual name or the first accepted automatic replacement sets it to false.
An empty workspace uses these same optional fields in its minimal manifest.

### Workspace manifest

A workspace's `apelin-project.json` is not a version 1 description: it has
`schemaVersion`, `projectID`, `kind: workspace`, `buildSystem: external` and
the display fields above, and may declare the build Apelin runs for it:

| Member | Meaning |
|---|---|
| `external.script` | A regular file inside the project (canonical path; no empty component, none starting with `.`). |
| `external.interpreter` | `sh` (default), `bash`, `zsh`, `python3` or `perl`, the bootstrap's own. |
| `external.arguments` | At most 32 one-line strings handed to the script after its path. |

No other member goes in `external`. apelin-build reads it
(`ExternalBuildDeclaration`); what the script gets and must write is in
AGENTS.md ▸ Workspace builds. No digest covers it: under Confirm every
build of a workspace asks.

### Written form

Apelin writes `apelin-project.json` one way, whatever writes it: creating a
project (the template's file after substitution, or an empty workspace's),
renaming it, switching its toolchain or SDK, importing a transfer file under
a new ID, and every build, which puts a file written otherwise into this
form before its first step. The form is Python's
`json.dumps(document, ensure_ascii=False, indent=2)` followed by one `\n`:

1. Two spaces a level, one member or element a line, `"name": value`.
2. Members and elements in the order they were written, never sorted.
3. An empty object or array as `{}` or `[]` on its line.
4. Strings escaped as in the canonical form (rule 4 above): `/`, DEL and
   non-ASCII as themselves.
5. Integers in shortest decimal form, so `-0` is written `0`.
6. `\n` line ends, and one after the document.

Only the text changes: the document read back is the one the file held,
member order included, so neither digest moves. A file that breaks a rule of
**JSON** above is left as it is. A file already in the form is the same
bytes and is not written again. The template files themselves are not JSON
before substitution and keep their own layout. The reference
implementation's `manifest_text` and ApelinProject's `ProjectManifestFormat`
write it; `Fixtures/manifest-format.json` holds both to it.
