# Device-side CLT retarget validation — 2026-10-17

The standalone `Packages/ApelinToolchain` base pipeline downloaded Apple's CLT,
extracted it, adapted and signed it **on both devices as uid/gid 501**. C, C++
and Objective-C compiled, linked and ran for arm64 and arm64e; every executable's
UUID matched its dSYM. This is the package on its own, driven by its probe;
the same pipeline run as `toolchainSetup` through Apelin, installed by irisind
and registered, is in `Device-Validation.md`.

## Tested combination

| Item | Identity |
|---|---|
| Device A | iPad vphone, iOS 27.0.1, roothide |
| Device B | iPhone vphone, iOS 26.6.2, roothide |
| Apple source | Command Line Tools 27.0, product `082-83364`, `CLTools_Executables.pkg` |
| Package size | 350,457,031 bytes |
| Catalog digest | `xar-toc-sha1`: `910fb71482f4d044112c226b03e33122c17920ce` |
| Local package SHA256 | `d1a517e663d7ba169296683255bcf5b498802b843603cee40ec4b6fb7c991bea` |
| Retarget scheme / target floor | 1 / iOS 16.0 (the floor was not runtime-tested; scheme 2 since 2026-10-19, below) |
| Toolchain ID | `4d6b25eba45adc2bf317de90`, base component, 319 manifest files |
| SDK | `xybp888/iOS-SDKs`, revision `ad607cb07fe4ad1c9b91cf970bd228c2a9253207`, `iPhoneOS27.0.sdk` |

The source URL, version, product ID, upstream digest, local SHA256 and per-file
output hashes are retained in each installed `manifest.json`. Both devices
fetched the SDK themselves with git partial clone and sparse checkout. No Apple
tool, package or SDK is committed in this repository. The probe alone was
cross-compiled on the Mac, using buildlock, then ad-hoc signed with
`platform-application` and `com.apple.private.security.no-sandbox`.

## Pipeline and resource measurements

The first uninterrupted cold runs passed on both devices: 126.36 s on A and
132.04 s on B, with about 1.72 GiB probe peak RSS. Inspection found Foundation
file-read intermediates surviving too long during synchronous work inside an
async task. Bounded autorelease pools around reads and each image reduced final
setup peak RSS to roughly 160 MiB without changing the output manifest.

A fresh download with the improved library completed on B in **102.38 s**,
with **171,212,800 bytes** peak probe RSS. On A, the validation terminal lost its
session after committing **150,994,944 bytes**; no new crash report was found.
The cause of that terminal interruption is unconfirmed. Restart verified the
prefix and the first new checkpoint was 159,383,552 bytes, then setup completed
in **55.82 s** (including catalog lookup), with **170,098,688 bytes** peak RSS.
This is a resumed run, not a second uninterrupted cold-run measurement.

Final stage measurements are recorded below from rebuilding into a new output
using each device's verified cached package. Download time in this table is
cache/prefix/upstream verification, not network acquisition. Extraction includes
payload verification and locating the CLT root up to the adapting event;
adaptation includes dependency closure, retargeting, copying and signing.
Packaging includes manifest hashing, final move and intermediate-tree cleanup.

| Stage | Device A (s) | Device B (s) |
|---|---:|---:|
| Catalog / probe overhead | 6.477 | 6.643 |
| Downloading (cached verification) | 0.533 | 0.500 |
| Extracting | 10.804 | 10.847 |
| Adapting / signing | 0.272 | 0.285 |
| Packaging / cleanup | 0.329 | 0.284 |
| Setup API total | 11.939 | 11.915 |
| Probe total including catalog | 18.416 | 18.558 |
| Validating (six cases) | 2.491 | 2.460 |

Final cached rebuild peak RSS: A **165494784 bytes**, B **165855232 bytes**. Self-test probe peak RSS: A **5799936 bytes**, B **5881856 bytes**; child max-RSS fields: A **93044736 bytes**, B **92848128 bytes**. Installation was a separately performed file-copy validation step; it was not timed.

Disk usage was sampled once per second with `du -sk` over the active staging and
new output only. The largest observed cold-run sample was **2,291,792 KiB
(2.19 GiB)** on B; A's resumed run reached **2,092,340 KiB (2.00 GiB)**. Sampling
can miss a shorter peak. The installed tree is **270,704 KiB (264.36 MiB)** and
the SDK **389,628 KiB (380.50 MiB)** on each device. These numbers exclude old
versions, other test staging, a future deb, Irisin's unpack/rollback copies and
filesystem safety margin. They are evidence for the host's space policy, not a
complete installation-space threshold.

Peak RSS comes from Darwin `getrusage`. Setup has no subprocesses. Self-test
reports the probe and `RUSAGE_CHILDREN.ru_maxrss` separately; these are not a
simultaneous whole-system peak or a jetsam pressure test.

## Language and architecture results

| Language | Target | Device A | Device B |
|---|---|---|---|
| C | arm64 | Pass (0.243 s) | Pass (0.242 s) |
| C++ | arm64 | Pass (0.566 s) | Pass (0.578 s) |
| ObjC | arm64 | Pass (0.401 s) | Pass (0.396 s) |
| C | arm64e | Pass (0.235 s) | Pass (0.230 s) |
| C++ | arm64e | Pass (0.419 s) | Pass (0.397 s) |
| ObjC | arm64e | Pass (0.357 s) | Pass (0.349 s) |

Each pass requires an explicit object compile, link against the physical SDK
path, dsymutil while the object still exists, matching LC_UUID values, Swift
ad-hoc signing, and execution printing `apelin-ok`. C++ uses vector/iostream;
Objective-C uses Foundation collections and ARC. The six checks were repeated
after the installed tree was made root-owned. The probe runs as mobile.

| Language / target | Device A executable = dSYM UUID | Device B executable = dSYM UUID |
|---|---|---|
| C / arm64 | `e881677a50693893b3a9d270bd227013` | `c772910e7bf33f189db34dee4bd3628f` |
| C++ / arm64 | `08c998fbc5513f3f9952540365290436` | `08c998fbc5513f3f9952540365290436` |
| ObjC / arm64 | `9e990355ce8c3876a7358b07ab146590` | `9e990355ce8c3876a7358b07ab146590` |
| C / arm64e | `ebcaaab5590c3e8ebbd317b9ac106037` | `ebcaaab5590c3e8ebbd317b9ac106037` |
| C++ / arm64e | `b7d7503cbdda3d28adf5446d627bcf0b` | `b7d7503cbdda3d28adf5446d627bcf0b` |
| ObjC / arm64e | `56124d680cf43a339737fa2f3ac11a3f` | `56124d680cf43a339737fa2f3ac11a3f` |

## Findings and fixes

- Apple's catalog `Digest` is SHA-1 of the **compressed xar TOC**, not the whole
  package. The downloader verifies it, then extraction verifies the Payload's
  archived checksum from that TOC. Local whole-package SHA256 remains a separate
  consistency hash. HTTPS authenticates catalog/transport; xar RSA certificate
  chain verification is not implemented.
- Apple's archive contains an in-tree dangling crashlog symlink into a separate
  package. Extraction validates complete link chains before creating links;
  such dangling links may stay in staging but cannot enter the selected closure.
- Compiler target runtimes are resources. Fat static archives in `usr/lib/clang`
  must not be parsed as host executables. Only iOS target runtime libraries are
  retained; the base host closure contains 14 Mach-O images, including both
  `otool` and its `llvm-otool` implementation.
- The initial self-test parser rejected dSYM virtual sections as file extents.
  Corrected specifically for MH_DSYM zero-file-size segments, with a regression
  fixture. Final tests all pass. No probe crash required symbolication.
- In-tree signed output is deterministic across the tested probe revisions:
  freshly produced manifests byte-match each device's installed manifest.
- A prior ready journal cannot prove that a newly supplied SDK is unchanged.
  `installAndValidate` therefore rechecks installed bytes and reruns validation
  for each invocation, while skipping an already-completed installation.

## Other Command Line Tools releases (2026-10-19)

Every `CLTools_Executables.pkg` Apple's catalog listed on 2026-10-19 was set
up by the probe **on the iOS 26.6.2 iPhone vphone, as uid 501, from Apple's
download**, and self-tested there against the iPhoneOS SDK its own Xcode
shipped with. The same setups on the Mac produced byte-identical manifests
(every file digest and the toolchain ID). The table is the second survey,
under retarget scheme 2 (▸ Retarget scheme 2), whose C case also calls
`__builtin_available`; the first, under scheme 1, passed the same way with
one file fewer per tree and other IDs. The reviewed list is
`CommandLineToolsSupport.releases` in `Packages/ApelinToolchain`; anything
else is refused with a sentence naming the version and the reason.

| CLT | Product | Toolchain ID | Files | Setup on the vphone | Self-test SDK | Six cases | Weak-loaded system library |
|---|---|---|---:|---:|---|---|---|
| 16.4 | `082-41241` | `67525fd44741f8a0f7d7b2e7` | 274 | 65.7 s | 18.5 | pass | — |
| 16.2 | `072-44426` | `23b8628e7dad50e991fa19ff` | 260 | 50.0 s | 18.2.1 | pass | — |
| 15.3 | `052-59890` | `f88a63eda7caa77b5dc1f336` | 217 | 39.5 s | 17.4 | pass | `libcodedirectory.dylib` |
| 15.0 | `042-32697` | `c2c9f8294b9d54ed586d08d0` | 216 | 47.8 s | 17.0 | pass | `libcodedirectory.dylib` |
| 14.3 | `032-84673` | `0538963dd72ff61d4209d42a` | 214 | 44.6 s | 16.4 | pass | `libxar.1.dylib` |
| 14.2 | `012-92431` | `a15849bf4f115489fd9bd9ae` | 207 | 49.2 s | 16.2 | pass | `libxar.1.dylib` |
| 13.4 | `002-83793` | `83dcf67697190b8842379e73` | 206 | 35.7 s | 15.5 | pass | `libxar.1.dylib` |
| 13.2 | `002-41708` | `dc9cd1774eb64a5ee1964bc2` | 201 | 91.7 s | 15.2 | pass | `libxar.1.dylib` |
| 12.5 | `071-54303` | `0ce57dded2817f00d2aa7a75` | 194 | 28.6 s | 14.5 | pass | `libxar.1.dylib` |
| 12.5 | `071-29699` | `42a4beb2ef86e96900293faf` | 194 | 33.1 s | 14.5 | pass | `libxar.1.dylib` |
| 12.4 | `001-89745` | — | — | refused | 14.4 | C++/arm64e killed | `libxar.1.dylib` |

Setup times include the download. Peak setup RSS was 125–172 MB; the
self-tests took about 2 s each. The SDKs were `xybp888/iOS-SDKs` revision
`ad607cb07fe4ad1c9b91cf970bd228c2a9253207`, copied to the device by hand
for this survey (only 18.5 went through `sdkImport`, below).

What the releases needed, and why:

- **A linker reads only SDKs up to its own Xcode's.** CLT 16.4's ld stops
  on the iOS 27.0 SDK's text stubs (`unknown architecture arm64e.x1`), and
  CLT 14.x's clang cannot read the iOS 18.5 SDK's libc++ and Foundation
  headers. Each release therefore records the newest SDK its Xcode shipped
  with (`newestSDK`, compared by major.minor, so 18.2.1 passes for 18.2).
  Setup self-tests against the newest registered SDK the release reads and
  refuses with the limit when none is registered; the toolchain record
  keeps the limit, `projectCreate` binds the newest SDK the toolchain
  reads, and `projectCheck` reports `environment.sdk.tooNewForToolchain`.
- **ld loads a macOS system library iOS does not have.** CLT 12.5–14.3's
  ld64 loads `/usr/lib/libxar.1.dylib` (bitcode bundles), CLT 15.x's
  `/usr/lib/libcodedirectory.dylib` (its linker ad-hoc signature, written
  for macOS and simulator outputs). CLT 16 and 27 ship their own
  `libcodedirectory.dylib`. The retarget turns that one load into a weak
  load and marks every launch-time bind from it weak (chained-fixup imports
  and the classic bind stream; lazy binds resolve only on first call). An
  iOS link never calls either library. Asking for those paths on purpose,
  `-fembed-bitcode` with 14.3 or `-Wl,-adhoc_codesign` with 15.3, gets
  ld killed (`linker command failed due to signal`); Apelin passes neither.
- **The self-test's dSYM reader** rejected CLT 13–15's C++ dSYMs: their
  dsymutil copies `__eh_frame` into the dSYM, so `__TEXT` has file bytes
  while its other sections stay virtual at offset 0. Fixed in the reader,
  with a regression test.
- **CLT 12.4 is refused.** Its SDK (14.4) has no libc++ headers; with the
  CLT's own `usr/include/c++` added, C++ compiled and linked for both
  architectures, but the arm64e program was killed (SIGKILL, no crash
  report) as soon as it wrote to `std::cout`, while the same program from
  12.5, which compiles against the SDK's libc++ headers, runs. No crash
  report was produced to symbolicate, so the cause is unconfirmed; an older
  libc++ inline ABI against the system's arm64e libc++ is the likely one.

Through Apelin (`t3-toolchain-side-by-side.json`, 2026-10-19, build 19,
scheme 1, so 16.4's ID there is scheme 1's):
`sdkImport` of the 18.5 SDK from the inbox (3.3 s); `toolchainSetup` of
12.4 failed at once with that refusal, before any download; 16.4 set up
through irisind beside the registered 27.0 in 73.6 s with all six cases
passing against 18.5, as `wiki.qaq.apelin.toolchain.159586e1bcf6f5b76d3272da`
under its own path, the default staying 27.0; removing 16.4 left 27.0
registered and the default, and `project-build-install.json` then built,
installed and removed a project with 27.0.

## Retarget scheme 2: the iOS builtins (2026-10-19)

Scheme 1 dropped `usr/lib/clang/<v>/lib/darwin/libclang_rt.ios.a` (its name
has `.ios.`, the filter wanted `_ios`). That archive is compiler-rt's iOS
builtins, where `@available` and `__builtin_available` find
`__isPlatformVersionAtLeast`; without it any C or Objective-C using them
fails to link (`Undefined symbols … ___isPlatformVersionAtLeast`, shown on
the iOS 26.6.2 vphone with the installed scheme 1 27.0 toolchain), and so
does any Swift executable, whose standard library inlines
`_stdlib_isOSVersionAtLeast_AEIC`. Scheme 2 keeps it, and the C self-test
case now calls `__builtin_available(iOS 13.0, *)`. The scheme is part of
the toolchain ID, so every release has a new ID under scheme 2; a scheme 1
toolchain stays installed and registered under its own until removed.

## Swift (2026-10-19)

`toolchainSetup` with `components: ["c", "swift"]` sets CLT 27.0 up with
Swift. Everything Swift needs comes from Apple's own CLT package, retargeted
like the C tools; nothing is invented or built from source.

- **The tools.** `swift-frontend` (173 MB) and `swift-driver`, with the
  closure their load commands name: the compiler's swift-syntax libraries
  (`usr/lib/swift/host/compiler`, which find each other through
  swift-frontend's run path — the closure now inherits run paths from the
  loading image, as dyld does), `libSwiftToolsSupport` and llbuild for the
  driver. `swiftc` and `swift` stay links to `swift-frontend`, which picks
  its mode by `argv[0]`; `usr/lib/swift/clang` stays a link to the clang
  resource folder. The manifest records links (`links`), and `verify`
  checks each target. Resources: `usr/lib/swift/host` (the in-process plugin
  server and the macro plugins, which resolve `@rpath` through the host
  folder) and `usr/lib/swift/apinotes`. libSwiftScan (170 MB, explicit
  module builds only) is left out; Apelin passes `-nonlib-dependency-scanner`
  so the driver does not warn about it. An empty `usr/lib/swift/iphoneos`
  keeps ld from warning about the search path swiftc adds. The tree is
  364 files, 478 MB; setup peaked at 526 MB RSS on the Mac.
- **One import iOS does not export.** Every iOS symbol the closure imports
  was checked against the iPhoneOS 27.1 SDK stubs and, where a stub lacked
  it, with `dlsym` on the iOS 26.6.2 vphone. One is missing from iOS:
  `_stdlib_isOSVersionAtLeastOrVariantVersion`, macOS's zippered
  `#available` check, imported by swift-driver, libSwiftToolsSupport and two
  syntax libraries. The retarget rebinds it, in the chained-fixup symbol
  pool, to `_stdlib_isOSVersionAtLeast`, which takes the same first three
  registers and compares them with the running OS. The first triple is a
  macOS version; from iOS 26 macOS and iOS share their numbering, and every
  earlier macOS version is older than any iOS 26 on both scales, so the
  answer is the same for every argument on an iOS 26 or later host. Setup
  therefore refuses Swift on a host older than iOS 26
  (`CommandLineToolsSupport.swiftMinimumHostMajor`).
- **The SDK.** The iOS 27 SDK carries Swift interfaces for arm64e (and
  arm64e.x1) only, so Swift cases run for the architectures the SDK has
  interfaces for; `projectCheck` warns (`environment.sdk.noSwiftArchitecture`)
  for a Swift project that asks for another. With Swift, the self-test SDK
  must be of the release's own iOS major (27): the compiler's `@Observable`
  plugin expands to members the iOS 18.5 SDK's macro declaration does not
  cover (`declaration name 'shouldNotifyObservers' is not covered by macro
  'Observable'`), so setup refuses Swift without an iOS 27 SDK and
  `projectCheck` warns (`environment.sdk.swiftMacros`) for a Swift project
  bound to an older one.
- **Back-deployment.** The CLT carries no iphoneos compatibility libraries.
  For the iOS 16.0 floor only `libswiftCompatibilityPacks` matters (50, 51,
  56, Concurrency and DynamicReplacements serve iOS 15 and earlier). Every
  object autolinks it; ld notes it is missing and links on. Code whose
  parameter packs need runtime metadata (a pack captured by an escaping
  closure or across `await`) then binds `swift_allocateMetadataPack` from
  the system's libswiftCore — shown on the vphone with a deployment target
  of 16.0 — which iOS has from 17.0, so such a binary does not load on iOS
  16. Everything else targets 16.0 as Xcode would. The macOS archive's
  objects were not retargeted in: they are compiled for the M1 baseline
  (`ldapr`, LSE atomics) where Xcode's iphoneos build of the same source is
  not, and no iOS 16 device was available to run them. `Span`'s
  back-deployment dylib is absent too: code using `Span` needs iOS 26 at
  run time.

On the iOS 26.6.2 iPhone vphone, by the probe against the registered iOS
27.0 SDK: the six C-family cases and Swift, Swift dylib, Swift async and
Swift macro on arm64e all passed (Swift 10.9 s, building the SDK's module
interfaces into the self-test's cache; the others about 1 s each; the
compiler peaked at 1.15 GB). Against the iOS 18.5 SDK, which has arm64
interfaces too, Swift, Swift dylib and Swift async passed on arm64 and
arm64e, and Swift macro failed on both as described above. A Swift program
using `@Observable` (deployment target 17.0) and parameter packs in
closures and async functions also compiled and ran by hand.

Through Apelin (`t4-toolchain-swift.json`, twice): `toolchainSetup` of 27.0
with Swift beside the registered scheme 1 27.0 toolchain, installed by
irisind as `wiki.qaq.apelin.toolchain.b7c9ecde91f0cca89ea0594f` (364 files,
`newestSDK` 27.0), both components `selfCheckPassed`, self-tested against
the iOS 27.0 SDK; the `uikit-swift` app template created against it,
checked, built debug and release, installed through irisind and removed.
The first run (an earlier build, before the macro case) set up in 80.6 s
with the download and passed nine cases; the app's first debug build took
23.6 s with a cold module cache (UIKit's interfaces), the release build
2.2 s. The second (build 20), after that toolchain was removed through
`toolchainRemove`, set up in 49.4 s and passed all ten: C, C++, ObjC on
arm64 and arm64e, then Swift 12.5 s, Swift dylib 1.2 s, Swift async 1.3 s
and Swift macro 1.1 s on arm64e; the builds took under a second each with
the module cache the first run left. That toolchain stays installed on
the vphone.

## Which SDKs a toolchain reads

Each release reads SDKs up to `newestSDK`, the one its Xcode shipped with,
compared by major.minor; a major alone takes that major's point releases,
and is written only once one of them passed. CLT 27.0's is `27`: its tools
and the Xcode 27.1 SDK's Swift interfaces carry the same compiler
(`swiftlang-6.4.0.31.4 clang-2100.3.31.1`), and on the iOS 26.6.2 vphone the
Swift toolchain self-tested against the 27.1 SDK passed all ten cases and
the `uikit-swift` template built against it ran. Setup writes the limit into
the toolchain's own `manifest.json` and its registry record
(`ToolchainRecord.newestSDK`), with the SDK the self-test used
(`selfTestSDK`); project checks read the record.

When no registered SDK fits, setup reads the enabled SDK sources and imports
the newest compatible branch before downloading the toolchain. Swift keeps
the same-major requirement. Branch names select a candidate; the imported
tree's `SDKSettings.json` determines its identity, and compatibility is checked
again after registration. An interrupted setup reuses a registered SDK rather
than fetching it again. SDK fetching and inspection appear under `Getting SDK`
in the same task; cancellation is shared with the import and clears its staging
directory. A successfully registered SDK stays available if toolchain setup
later fails.

The default source is `owngoal-dev/iOS-SDKs`, with one independent branch per
SDK, starting at 14.5. The 13.0–14.4 trees lack C++ standard library headers
and are excluded from this source. A configured source list, including an empty
list or a disabled source, replaces that default. Source failures and a source
with no compatible version are reported before installing a toolchain package. A release the catalog marks
as unavailable for Swift is refused before resolving or downloading an SDK.

## Runtime branding on real RootHide hosts

Repeated verification on the iOS 17.3.1 and 26.0.1 real devices exposed a
signature change after the tools had run. Comparing their installed files
with the same releases on a vphone found only the jbrand in the unused
eight bytes of `__text`'s segment name, `CS_ADHOC`, and the first code-page
hash. The instructions and other data were identical. Dopamine's
[signature handling](https://github.com/roothide/Dopamine-roothide/blob/3.x/BaseBin/libjailbreak/src/signatures.c)
also documents adding `CS_ADHOC` when a signature has neither it nor a team ID.

Verification first checks the original full-file SHA-256. For this specific
runtime form, it validates the brand checksum and current first-page hash,
restores those metadata bytes in memory, and requires the reconstructed
**whole file** to match the original manifest digest. It writes neither the
tool nor its manifest. Changes to code, dependency paths, entitlements,
other signature data, or malformed fields still fail. Checked-in tests cover
these refusals and fixed-width Mach-O names without a NUL, using synthetic
brands. Local replay checks on both real-file samples also passed.

## Older CPUs (2026-10-19)

The retarget keeps the tools' machine code, and Apple builds it for the M1
only: CLT 27.0's host tools (and Xcode 27.1's, byte for byte in `__text`)
are single arm64 slices, so there is no other slice to take. Every Mach-O
in the tree was disassembled against `apple-a11` and `apple-a12` and
compared with a full decode. Beyond the A12 there are two instructions:

- `eor3` (FEAT_SHA3): clang 42, libLTO 42, swift-frontend 5, nm 4,
  dsymutil 4, libtapi 1. Four in each are LLVM's `XXH3_hashLong_64b`, run
  for inputs of 1025 bytes or more, which `ODRHash::CalculateHash` reaches
  whenever clang writes a module (a large record's ODR data); clang's and
  libLTO's others are in BoringSSL code compiling never runs.
- `udot` (FEAT_DotProd): swift-frontend 3730 in 268 functions (wide
  popcounts, hit by IRGen on large multi-payload enums), clang and libLTO
  10, nm 10.

The A11 also lacks `ldapr` (FEAT_LRCPC), which clang's and libLTO's static
initialisers run, so no tool starts there. ld, lipo, libtool, strip, ar,
otool, swift-driver, the swift-syntax and host libraries and the macro
plugins have none of these.

On an A12Z iPad (iPadOS 26.0.1, roothide: FEAT_LRCPC 1, FEAT_SHA3 0,
FEAT_DotProd 0, FEAT_LRCPC2 0), through `toolchainSetup` of 27.0 with Swift:
the six C-family cases passed and all four Swift cases stopped on
`EXC_BAD_INSTRUCTION` at the first `eor3` in `XXH3_hashLong_64b`
(`ODRHash::CalculateHash` ← `ASTDeclWriter::VisitRecordDecl`), building the
SDK's clang modules; the setup was rolled back. By hand, C, C++ and ObjC
without modules compiled at `-O2` for arm64 and arm64e and ran; ObjC, C and
C++ with `-fmodules`, an identifier over 1 KB and `asm("sdot …")` trapped
the same way.

Supporting these CPUs would mean rewriting machine code (each `udot` has an
equal-length `uaddlp` pair; each `eor3` needs a branch out), which the
retarget does not do. Instead `HostCPU` (ApelinCore) reads the kernel's
`hw.optional.arm.FEAT_*`: without FEAT_LRCPC no toolchain is set up or
offered; without FEAT_SHA3 and FEAT_DotProd the catalog offers no Swift,
setup refuses it, and `projectCheck` reports `environment.device.swift` for
a Swift project and `environment.device.clangModules` for `-fmodules` or
`-fcxx-modules` in a configuration's `cFlags`. Whether CLT 12.5–16.4 were
built for a lower baseline was not checked.

## Legacy Swift research (2026-10-19)

Older Swift compilers do not inherently need iOS 26. An opt-in test fixture
(`LegacySwiftInvestigationTests`) prepares isolated, unregistered trees for
CLT 14.2 (Swift 5.7.2) and 15.0 (Swift 5.9), without the CLT 27 Swift import
rename or instruction patches. After completing the device probes below,
ordinary setup now accepts these Swift components with their own host and
CPU requirements. `DependencyClosure` recognizes their integrated driver and,
where present, `swift-plugin-server`. Self-tests omit macros and the newer
dependency-scanner flag for pre-5.9 compilers, and emit a dylib's module
and object separately because the 14.2 driver otherwise emits no object.

| CLT / product | Download bytes | SHA-256 of Apple package |
|---|---|---|
| 14.2 / 012-92431 | 507485226 | `81c4ed35ac9a2dcce106c9d26696653ceb9337b949206802886e25d13f9b3f1a` |
| 15.0 / 042-32697 | 574900109 | `a5ec585bf89ce2e43aca1583b8a315b88725d53bc66dd0f2ba3fcf4580ec7b8f` |

`Scripts/inspect-toolchain-imports.py` inventories host-image system
imports without executing them; `--instructions` adds a selected-feature
scan using Apple LLVM. The scan covered 14 images in 14.2 and 29 in 15.0.
14.2 contains LRCPC (`ldapr` 6,224; `ldaprb` 5,764) but no selected
SHA3/DotProd instructions. 15.0 contains 112 `eor3` instructions (clang
55, libLTO 55, swift-frontend two), so it was not executed on A12Z. This
is a selected-feature inventory, not exhaustive instruction validation or
a reachability proof. `Scripts/CheckSwiftImports.m` checks strong imports
against fixed Apple system images on the host without loading a compiler:
949 ordinary imports for 14.2 were present on A12Z, and 1,682 for 15.0 on
iOS 17.3.1. `dyld_stub_binder` is dyld-managed and listed separately.

Both vphones (26.6.2 and 27.0.1) passed the full research probes: 14.2 with
SDK 16.2, 12/12; 15.0 with SDK 17.0, 14/14. The initial physical-device
probes stopped at a dylib-client launch denial (`file system sandbox
blocked mmap()`), confirmed in both launch reports. A bounded `dlopen`
probe isolated it to the self-test executable's signature: the ordinary
`get-task-allow` debug entitlement permits the private test dylib to load.
Only temporary Swift test executables now carry it; compiler and library
signatures are unchanged. No security setting or system policy is changed.

The full rerun passed 14.2's 12 cases on both the iOS 17.3.1 15 Pro and
26.0.1 A12Z, and 15.0's 14 cases on the 15 Pro. Both vphones repeated
both full suites with the same signer. No new compiler SIGILL occurred.
The legacy host floor offered is 17.3.1, the oldest host actually tested;
14.2 requires LRCPC and 15.0 requires LRCPC/SHA3. CLT 27.0 retains its
26.0 floor and LRCPC/SHA3/DotProd requirement. Requirements are carried in
manifests and records; project checks use the bound toolchain's metadata.
The build pipeline omits the unsupported dependency-scanner option for
14.2. The download picker's Compatibility page and
[`Documents/Compatibility.md`](../Compatibility.md) explain the choices.
Per-device production-flow results remain in `Device-Validation.md`.

To reproduce preparation, set `APELIN_LEGACY_SWIFT_VERSION` to `14.2` or
`15.0`, and `APELIN_LEGACY_SWIFT_WORKSPACE` to a new absolute scratch
directory, then run the matching Swift Testing fixture on macOS. It
uses the ordinary reviewed setup to download Apple's package and verify
the resulting tree, but never installs it. The research helper and compiler binaries are not shipped.

## Integration boundary and remaining work

`ToolchainCatalog.list`, `ToolchainSetup.run`, `ToolchainSetup.verify`,
`ToolchainSetup.installAndValidate` and `ToolchainSelfTest.run` are documented in
[the package README](../../Packages/ApelinToolchain/README.md). Progress stages
are downloading → extracting → adapting → packaging → installing → validating
→ ready. Setup returns a signed installable tree at packaging. The authenticated
Irisin transaction is supplied by the environment host; this package adds no
alternate installer or public daemon CLI.

For this validation only, each device's prepared tree was copied into its
installation location by hand and made root-owned; it was not an Irisin
transaction. The product path has since replaced that: apelin-environment
packages the tree as `wiki.qaq.apelin.toolchain.<id>`, the session host
installs it through irisind, and only a tree whose installed bytes pass the
self-test is registered (`AGENTS.md` ▸ The environment worker).

Swift is set up for CLT 27.0 only (▸ Swift, below); any other release with
Swift is refused. CLT versions outside the reviewed list (above) are listed
but refused with their reason. Base success does not establish rootless, real-device, iOS 16,
arm64e.x1, sanitizer runtime, injection, respring, or memory-pressure behavior.
Network loss and disk exhaustion were not fault injected; device download
interruption and host HTTP-prefix recovery were tested here, and a session-host
restart during setup in `Device-Validation.md`.

## Verification

- SwiftPM tests passed with the opt-in real Apple package test enabled;
  ordinary runs skip that one external-input test. Seven upstream Irisin
  signing fixtures match byte for byte, including XML/DER and embedded
  Info.plist hashes.
- Host HTTP fixture: correct Range/If-Range resume, completed receipt/hash,
  and corrupt-prefix restart passed. Archive escape, device entry, expansion
  limit, binary truncation, dSYM layout and insufficient command room tests
  passed.

`<install-root>` is the daemon's runtime hello root. Consumers must
canonicalize the SDK URL and pass that physical path to `-isysroot`; a
bootstrap-visible alias is insufficient. Toolchain entries are root-owned;
the SDK remains mobile-owned.


## Installation compatibility catalog (2026-10-19)

The compatibility catalog now carries the CPU requirements independently of
SDK recommendations and verified hosts. `CommandLineToolsSupport.releases`
is the maintained table, including exact Apple product IDs; a repackaged
product with an existing version is not automatically approved. The same
`compatibility` snapshot is returned before setup and stored in the resulting
toolchain manifest and registry. No app interface was changed.

The CPU scope includes the A9/A9X and A10/A10X iPads supported by iPadOS 16,
not just the A11 and later iPhones. Those three older groups lack LRCPC and
cannot start the reviewed Apple Silicon compiler tools without changing
machine code. A12/A12X/A12Z provide LRCPC but lack SHA3 and DotProd. A13 and
later, and M-series iPads, provide all three. The runtime decision uses the
kernel's feature flags, not the explanatory chip names. See
[Compatibility](../Compatibility.md) for recommendations and primary sources.

A fresh, non-executing import audit also compared the legacy host images
against the iPhoneOS 16.1 SDK's arm64/arm64e exports, resolving re-exported
libraries and symbols. CLT 14.2's 949 ordinary strong imports and CLT 15.0's
1,682 all have declarations there. `libxar` (14.2) and `libcodedirectory`
(15.0) are excluded because the existing retarget explicitly weakens those
loads; `dyld_stub_binder` is a dyld-managed binding, not a `dlsym` export.
The SDK is from `owngoal-dev/iOS-SDKs` branch `sdk/iPhoneOS16.1`, commit
`65a3b4ef04809872d0cde0604f217fed2a90a547`. The audit is evidence about
imports, not a device launch or proof of iOS 16.0 compatibility. The 17.3.1
legacy Swift floor remains a labeled support policy based on the oldest
actual run, rather than being presented as a CPU instruction requirement.

`StaticInventoryTests` prepares only the host images selected by Apelin's
real dependency closure, using downloaded Apple packages. Images are
thinned to arm64 without modifying their instructions. A local C helper uses
Xcode's LLVM decoder API on every instruction in every executable section,
without executing the inspected image. The inspector checks
their SHA-256 values, inventories ISA features, and can compare full LLVM
decodes for each requested CPU. Its synthetic regression includes LRCPC,
SHA3 and DotProd, and confirms that A9/A10/A11, A12 and A13 are distinguished
without ever executing the sample instructions. The expanded package is
removed after inventory; source packages and generated host-image evidence
remain local, outside version control.

### Static inventory of all offered Apple products

These 12 exact source packages were inspected on the Mac without executing
their host tools. The compact, hashed record is
[`compatibility-audit.json`](../../Packages/ApelinToolchain/Tests/ApelinToolchainTests/Fixtures/compatibility-audit.json).
Counts include repeated files when the installed tree contains aliases.

| CLT | Apple product | Host images | LRCPC words | SHA3 words | DotProd words | Unclassified words |
|---|---|---:|---:|---:|---:|---:|
| 12.5 | 071-29699 | 14 | 8490 | 0 | 0 | 80 |
| 12.5 | 071-54303 | 14 | 8490 | 0 | 0 | 80 |
| 13.2 | 002-41708 | 14 | 8885 | 0 | 0 | 861 |
| 13.4 | 002-83793 | 14 | 8077 | 0 | 0 | 0 |
| 14.2 | 012-92431 | 14 | 11988 | 0 | 0 | 0 |
| 14.3 | 032-84673 | 23 | 16291 | 55 | 0 | 150 |
| 15.0 | 042-32697 | 29 | 20446 | 112 | 0 | 4036 |
| 15.3 | 052-59890 | 29 | 21920 | 112 | 0 | 5705 |
| 16.2 | 072-44426 | 34 | 20873 | 86 | 0 | 7733 |
| 16.4 | 082-41241 | 48 | 20761 | 86 | 3772 | 9130 |
| 27.0 | 082-83364 | 51 | 11914 | 98 | 3760 | 4680 |
| 27.2 | 142-50405 | 51 | 11882 | 97 | 4734 | 0 |

Every instruction that the reference decoder classified was also accepted
by the A13 decoder. A12 rejects the recorded SHA3/DotProd instructions. The
14.2 tree was additionally compared against A9/A10/A11; their rejected
LRCPC instructions are recorded in the fixture.

Unclassified words are retained as an explicit limitation, not silently
counted as compatible instructions. For example, 13.2’s `swift-frontend`
contains repeated `0x00045fb0` words in an inline jump table after a return
in `ARMGenSubtargetInfo::resolveSchedClass`; the Mach-O has no corresponding
`LC_DATA_IN_CODE` entries. A linear decoder cannot establish reachability
of such data. This is why whole-image inventory, component CPU requirements
and actual runtime evidence remain separate.

The newly completed inventories found no SHA3 or DotProd instruction in
12.5 (both products), 13.2, 13.4 or 14.2. Those releases no longer inherit a
blanket SHA3 requirement for Clang modules. 14.3 and later retain it. Swift
remains offered only for the adapted 14.2, 15.0 and 27.0 releases; a matching
instruction set alone does not adapt their drivers, dependencies or plugins.


### Base tools also have a C++ runtime requirement

CLT 16.4 and 27.0 import `std::__1::__libcpp_verbose_abort` from the system
C++ runtime in base tools including clang, ld, dsymutil and libLTO. The
linker name `__ZNSt3__122__libcpp_verbose_abortEPKcz` is absent from the
16.1 and 16.2 SDK export lists, and present in 16.4. This is independent of
CPU instructions and independent of the SDK chosen for the user's project.
The catalog now records this dependency as `requiredLibcxxSymbols`. Before
download, both the backend and direct setup check its actual presence with
`dlsym` in the fixed system `/usr/lib/libc++.1.dylib`; no compiler is loaded.
The build worker checks the stored requirement too. We deliberately do not
infer the status of iOS 16.3 from neighboring SDKs. An older system without
this symbol can select 16.2 or earlier instead.
