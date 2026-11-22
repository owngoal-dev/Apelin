# ApelinToolchain

Device-side CLT acquisition and adaptation for the mobile `apelin-environment`
worker. This standalone SwiftPM package does not link into `apelind` and does
not change the app project. Requires iOS 16+; macOS is a host-test platform.
There are no third-party package dependencies. Foundation, CryptoKit,
Compression and system zlib provide networking, hashing and decompression.
The one package dependency is local: `../ApelinFormats`, for `ApelinCodeSign`
(CryptoKit only), the signer apelin-build uses too. Its libarchive pin is
resolved, never linked here.

```swift
let sources = try await ToolchainCatalog().list()
let prepared = try await ToolchainSetup().run(
    source: source, components: [.base], staging: taskDirectory,
    output: preparedTree, progress: reportProgress
)
// Hand preparedTree to the environment host's local package writer / Irisin transaction.
let ready = try await ToolchainSetup().installAndValidate(
    manifest: prepared, tree: preparedTree,
    installRoot: rootFromDaemonHello, sdk: registeredSDK,
    journal: taskJournal, scratch: validationScratch,
    install: installThroughIrisin, progress: reportProgress
)
// Publish the default/registered toolchain only after this returns .ready.
```

`ToolchainCatalog.list()` lists product ID, human version, executable-package
URL, size and upstream digest. The default is Apple's current merged software
update catalog. Apple catalog/package requests use HTTPS. Catalog `Digest` is the SHA-1 of the
**compressed xar TOC**, recorded as `xar-toc-sha1`; it is not the whole package
hash. The downloader verifies that digest; extraction verifies the Payload's
archived checksum in that TOC. `sourceSHA256` is a separate local whole-file
consistency hash. This implementation does not independently validate xar's
RSA certificate chain: catalog/transport authentication relies on HTTPS.

`ToolchainSetup.run(source:components:staging:output:progress:)` returns a
`ToolchainManifest` and a signed tree, at the **packaging** stage. It does not
claim to have installed anything. The tree contains `usr/bin`, compiler
resources, dependency libraries, and `manifest.json`. Its eventual location is
`<hello.installRoot>/<manifest.installRelativePath>`; the latter is
`usr/lib/apelin/toolchains/<id>`. No bootstrap prefix is compiled into Swift.
The ID includes the source SHA256, retarget scheme, target OS and components.

`installAndValidate` owns the subsequent installing → validating → ready
journal. Its installation closure is the integration point for the environment
worker's package writer and authenticated Irisin transaction. It must be
idempotent for the manifest ID, and settle its transaction before returning,
including when cancellation is requested. This package contains no dpkg/apt
or alternate installer. Installed digests must still match the prepared tree;
an installer that changes signatures needs an explicit post-install receipt
contract before it can be integrated.

`ToolchainSelfTest.run(toolchain:sdk:scratch:progress:)` can also
be called independently. It returns one result per language/architecture with
elapsed seconds, success/failure and executable/dSYM UUID. The matrix
is C (with `__builtin_available`), C++, ObjC × arm64, arm64e; with Swift,
also Swift, Swift dylib (a library module and a client that loads it),
Swift async and Swift macro (`@Observable`), for each architecture the
SDK has Swift interfaces for, sharing one module cache; last, for a scheme 3
tree, `ar` (`ar rcs`, which execs ranlib, then a program linked from the
archive and run) and `otool` (`-hv`, `-L` and `-l` on that program, which
exec otool-classic) on arm64. It retains `.o` files through dsymutil, signs
only after linking, executes each hello, and requires its expected output.
The SDK is canonicalized with `realpath`; `-isysroot` receives that physical
path. The caller registers the SDK first. Tests use explicit `posix_spawn`
argument vectors, never shell strings. Output is captured in task scratch;
children have a two-minute bound (fifteen for swiftc, whose first run builds the SDK's modules) and cancellation kills/reaps the child.

Recovery and cancellation:

- One advisory lock prevents two setup calls using the same staging directory.
  The caller owns this private directory and must prevent concurrent external
  mutation. Different source/component/OS requests cannot reuse its journal.
- Download uses bounded 8 MiB HTTP ranges, retries transport/server failures,
  and saves length, validator and prefix SHA256 after durable writes. Restart
  verifies the prefix before appending. A changed remote object invalidates
  the partial file and requires retry. An interrupted in-flight range is
  discarded. A verified complete download is reused without network traffic.
- Incomplete extraction/adaptation restart from the verified package; stage
  markers alone are never evidence. A completed output is reused only after
  every manifest digest verifies. Other installed IDs are never removed.
- Extraction limits default to 8 GiB file data, 200,000 entries, depth 64 and
  64 MiB pbzx chunks. Odc/newc cpio is supported. Traversal, NUL, special
  files, duplicate names, escaping/cyclic links and malformed lengths fail.
  In-tree dangling links in Apple's archive may remain in staging, but cannot
  enter the dependency closure. Links are created only after file extraction.
- Task cancellation is checked during download, decompression, copying,
  hashing and self-test. Download/checkpoint data and failure diagnostics stay
  in this task's staging for retry; the host owns cancellation cleanup.
- Recovery after installation checks installed digests and reruns interrupted
  validation. Each call reruns validation against the supplied SDK, including
  after a previous ready journal; that journal cannot prove the SDK is unchanged.

The reviewed adapter accepts the base tools of the releases
`CommandLineToolsSupport.releases` lists — 27.0, 16.4, 15.3, 15.0 and
14.2 — each set up and self-tested on a device; `refusal(for:)` gives every
other version a sentence naming it and why (12.4: its arm64e C++ is killed
at run time; 16.2, 14.3, 13.4, 13.2 and 12.5: dropped on 2026-10-21, a kept
release reads every SDK they read). Each release records
`newestSDK`, the iPhoneOS SDK its Xcode shipped with: its linker and headers
read that one and older, so the host self-tests against the newest
registered SDK the release reads. A release whose ld loads a macOS system
library iOS lacks (`libxar` for bitcode in 14.2, `libcodedirectory`
for linker signatures in 15.x) gets that load weakened, with every
launch-time bind from it marked weak (`MachOImage.weakenLoads`); Apelin
never takes the paths that call them. Entry points
are clang, ld, lipo, dsymutil, strip, ar, ranlib, libtool, nm, otool,
llvm-otool and otool-classic: from retarget scheme 3, the siblings two tools
exec by path beside themselves, which no load command names — otool-classic,
which `otool` (llvm-otool) execs for every flag, and ranlib (libtool by that
name), which `ar` execs for its `s` (`ar rcs`). llvm-otool's `-objdump`
(llvm-objdump) and ld-classic (15.3's strip of an object file with `-x`,
`-S`, `-u` or `-r`, and `ld -ld_classic`) stay out: 14.2's and 15.3's
llvm-objdump and 15.3's ld-classic load libxar, which iOS lacks;
resources come from `usr/lib/clang` (only iOS target runtime libraries),
libraries from their dependency closure. Target compiler runtimes are preserved
as resource bytes; they are not host executables to retarget.
Fat inputs select an arm64 slice; image fields and load commands are bounded
before access. Platform commands become iOS, framework Versions directories
are flattened, and internal loads become relative `@loader_path` references.
AppKit/Cocoa/Carbon dependencies fail clearly. Load-command growth never moves
sections: insufficient room is an explicit error. Signing is the last byte
change. The signature and entitlements blobs are `ApelinCodeSign`'s
`LdidStyleSignature` and `LdidEntitlements` (Irisin's, MIT), the one signer
Apelin has. The layout around them stays in `MachOImage.signed` and differs
from `CodeSigner`'s on purpose: it works on the retargeted command list, keeps
every byte up to the old signature (ldid ends the code at the string table),
re-appends the signature command last, signs only the arm64 slice, and gives
an executable `platform-application` and `no-sandbox`.

**Swift** (`components: [.base, .swift]`) is set up for CLT 14.2 (Swift
5.7.2), 15.0 (5.9) and 15.3 (5.10) on iOS 17.3.1 or later with LRCPC, and
for CLT 27.0 (6.4) on iOS 26 or later with SHA3 and DotProd; 16.4's Swift
6.1.2 is not offered (`swiftUnavailable` says why). For 27.0, on an
iOS 26 or later host: `swift-frontend` and `swift-driver` with their closure
(run paths inherited from the loading image, as dyld resolves them), the
host libraries and macro plugins in `usr/lib/swift/host`, `swiftc`/`swift`
and `usr/lib/swift/clang` kept as links (`ToolchainManifest.links`), and
libSwiftScan left out. The one import iOS lacks,
`_stdlib_isOSVersionAtLeastOrVariantVersion`, is rebound in the chained-fixup
symbol pool to `_stdlib_isOSVersionAtLeast` (`MachOImage.renameImports`;
`CommandLineToolsSupport.swiftImportRenames` says why the answer is the same
from iOS 26). The CLT has no iphoneos compatibility libraries: code whose
parameter packs need runtime metadata binds `swift_allocateMetadataPack`
from the system and needs iOS 17 to load. Retarget scheme 2 also keeps
`libclang_rt.ios.a`, the builtins `@available` links against; scheme 3 adds
otool-classic and ranlib. A scheme 2 tree is still verified, self-tested,
exported and imported under its own ID (`ToolchainSetup.readableSchemes`).
Evidence is in the research document (▸ Swift, ▸ Retarget scheme 2,
▸ Retarget scheme 3).
Other CLT versions are discoverable but refused by setup with their reason.
Both tested vphones pass the base-language matrix with 27.0; the iOS 26.6.2
iPhone vphone with every other reviewed release. Setup peak RSS is measured
in the linked report; bounded autorelease pools release Foundation file buffers
between chunks and images. A successful vphone run does not establish rootless,
real-device or iOS 16 compatibility.

Host verification:

```sh
swift test --package-path Packages/ApelinToolchain \
  --scratch-path /private/tmp/apelin-toolchain-tests
# Optional: a locally downloaded Apple package, never a committed fixture.
APELIN_TEST_PACKAGE=/path/to/CLTools_Executables.pkg swift test \
  --package-path Packages/ApelinToolchain \
  --scratch-path /private/tmp/apelin-toolchain-tests --filter LivePackageTests
```

Use the installed buildlock shims for all builds. `apelin-toolchain-probe`
provides `catalog`, `setup PRODUCT_ID STAGING OUTPUT` and
`test TOOLCHAIN PHYSICAL_SDK SCRATCH` for on-device validation. It is not an
application peer, installer, or product CLI. `setup` requires uid 501. Sign
its iOS arm64 executable ad hoc with `platform-application` and
`com.apple.private.security.no-sandbox` before transferring it. Keep its dSYM
and UUID for any installed build. Device evidence lives in
`Documents/Research/2026-10-17-Toolchain-Retarget.md` (this package alone)
and `Documents/Research/Device-Validation.md` (`toolchainSetup` through
Apelin and irisind).

Irisin provenance: `Lakr233/Irisin` revision
`a0bd81d523ae679f3aefb31d11bf93477a079345`, MIT, copyright OwnGoal Studio.
The two signature/entitlements sources live in
`Packages/ApelinFormats/Sources/ApelinCodeSign` with their notice and the
upstream LICENSE beside them (`Licenses/IrisinCodeSign`). Upstream
input/expected fixtures and their generation source are preserved here; tests
compare seven independently generated ldid signatures, rebuilt through
`ApelinCodeSign`, including XML/DER entitlements, embedded Info.plist and
executable flags. Tests also cover range resume with corrupted-prefix recovery, archive escape
and expansion limits, truncated images, command-space failure, and dSYM virtual
sections. The optional real-package test downloads nothing and commits no Apple
files.
