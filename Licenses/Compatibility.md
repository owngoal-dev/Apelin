# Dependency license review

Scope: everything `Apelin.app`, `apelind` and the workers link. This is a
source and notice audit, not legal certification.

apelind and apelin-log-reader are libSystem and Foundation
(`Scripts/check-system-only.py`). The app links the UI packages below
(owner, 2026-10-17), all statically; the other third-party code reaches
only the mobile workers, through `Packages/ApelinKit`.
Of them, apelin-diagnostics links icli (and through it
libarchive.xcframework), apelin-agent links kwwk and its tree, and
apelin-environment libgit2 and libarchive. The app ships every notice in
`Licenses.json`, since it is the one place a user reads them.

Rules for what comes next:

- MIT, BSD, ISC, zlib and Apache-2.0 are accepted; the notice ships whole.
- MPL-2.0 is accepted for unmodified files linked into the app; it stays
  file-level copyleft.
- GPL and LGPL are refused, and the refusal is written here. LGPL's
  relinking condition cannot be met by a statically linked, ad-hoc signed
  iOS binary. The collector fails the build on GPL-family text.
- The one way past that rule is a reviewed exception: an entry in
  `review.json` ▸ `gplExceptions` keyed by the notice's id, holding the
  exact text hash the owner read, the package identity and revision for a
  package notice, and who accepted it. A changed text, a moved pin or an
  exception for a notice no longer collected fails the build. Each one has
  a row below saying why.
- Vendored source keeps its upstream `LICENSE` beside it and gets a
  `Licenses/` folder with the same text.
- A prebuilt binary (an XCFramework) is reviewed component by component:
  each component it hides gets a folder under `Licenses/` or a section of
  the package's own `LICENSE`, and the wrapper's revision goes into
  `review.json`'s `binaryRevisions`.
- Nothing third-party links into apelind.

| Component | Finding and distribution action |
| --- | --- |
| Apelin | MIT, `LICENSE`. |
| IrisinExternalClient | MIT (OwnGoal Studio), Irisin 4.7.0's client for irisind, vendored as source in `Apelind/Vendor/IrisinExternalClient/` with its `LICENSE` beside it. System libraries only (XPC, CryptoKit); the one outside source apelind compiles, for the session host's install bridge. |
| Irisin signing (`Licenses/IrisinCodeSign`) | MIT (OwnGoal Studio), Irisin's `LdidStyleSignature` and `LdidEntitlements` (revision `a0bd81d5`), vendored as source in `Packages/ApelinFormats/Sources/ApelinCodeSign/` with its `LICENSE` beside it. CryptoKit only. The one signer: linked into apelin-build (product signing) and, through ApelinToolchain, into apelin-environment (the toolchain retarget). |
| libarchive.xcframework 1.0.0 (`ArchiveKit`) | MIT packaging; the static archive holds libarchive (BSD-2-Clause), xz/liblzma (0BSD), zstd's library (BSD-3-Clause) and lz4's library (BSD-2-Clause), all four notices in the package `LICENSE`; zlib, bzip2, iconv and libxml2 come from the SDK. Linked into apelin-environment (SDK archives) through ApelinEnvironment and ApelinFormats, and into apelin-build (the deb writer) through ApelinBuild and ApelinFormats' ApelinDebArchive. The same pin ApelinFormats resolves. |
| libgit2.xcframework 1.0.0 (`GitKit`) | MIT packaging; the static archive is libgit2 1.9.7 (`49e408b3`), **GPLv2 with the linking exception**, with its bundled xdiff (**LGPL-2.1-or-later**), llhttp and sha1dc (MIT) and the rest of libgit2's `COPYING`. HTTPS through the SDK's SecureTransport; SSH runs an `ssh` binary (none is spawned on the device, so HTTPS is the path). **Owner decision 2026-10-17: accepted as a reviewed exception** (`gplExceptions`): the linking exception permits linking the unmodified library into a program distributed under its own terms, and xdiff is recorded as a known, accepted item. Linked only into apelin-environment, a separate mobile process, never into the app or apelind. The notice ships whole twice: the package `LICENSE` and `Licenses/libgit2/` (upstream `COPYING` at the pinned commit). Distributing libgit2 modified, or on its own, would follow the GPLv2 — Apelin does neither. |
| icli 1.0.0 | MIT. Linked into apelin-diagnostics only, with libarchive.xcframework (row above) statically inside IcliKit. Carries the ios-mcp MIT notice (`Licenses/ios-mcp`). |
| kwwk (e01122a) | MIT. Linked into apelin-agent only. |
| swift-nio 2.104.0, swift-nio-http2 1.46.0, swift-nio-ssl 2.37.5 | Apache-2.0 with NOTICE files; llhttp MIT inside swift-nio. |
| BoringSSL (swift-nio-ssl, 817ab07) | OpenSSL and SSLeay licences with ISC for new code, MIT for fiat; `Licenses/BoringSSL`. Compiled into apelin-agent. |
| swift-crypto 4.5.2 | Apache-2.0 with NOTICE. On Apple platforms it is CryptoKit; its own BoringSSL and XKCP copies are not built. |
| swift-asn1, swift-atomics, swift-collections, swift-system, swift-argument-parser | Apache-2.0 (Swift's with the Runtime Library Exception). Argument Parser is a pin only, for icli's CLI target; nothing Apelin builds links it. |
| libwebp 1.4.1, libpng 1.6.45, zlib 1.3.2, Cstb 1.0.6 | BSD-3-Clause, libpng licence v2, Zlib, MIT or public domain. libpng's `contrib/gregbook` is GPL-licensed and not compiled (manifest excludes `contrib`); `excludedPaths` keeps it out of the list. |
| DisplayLink 3.0.1, ListViewKit 4.6.0, Litext 3.6.4 (Litext, LitextAnimation), LRUCache 1.3.0 | MIT. App only. |
| MarkdownView 4.8.3 (MarkdownView, MarkdownParser) | MIT; its `LICENSE` also carries swift-markdown-ui's MIT notice. App only. |
| SwiftMath 1.7.3 | MIT (Computer Inspirations), and MathChat's MIT for the font metric plists. App only, through MarkdownView. Its twelve math fonts ship whole, each with a `Licenses/font-*` folder: the copyright from the font's own name table, then the license. Asana, Euler, Fira, Garamond, KpMath Light and Sans, Lete Sans, Libertinus and Noto Sans Math are OFL-1.1. XITS is the STIX OFL-1.1 licence. Latin Modern Math and TeX Gyre Termes Math are the GUST Font License (LPPL-1.3c with a renaming request, which shipping them unmodified meets). |
| swift-cmark 0.9.0 (cmark-gfm) | BSD-2-Clause, with MIT for houdini, buffer and the utf8proc-derived utf8.c; the whole `COPYING` ships. Its CC-BY-SA spec and BSD-2-Clause tests are not compiled. App only, through MarkdownView. |
| Runestone (vendored, `Packages/Runestone`) | MIT. simonbs/Runestone 0.5.2 (`Licenses/Runestone`, the package's `LICENSE`), the Tree-sitter runtime (`Licenses/tree-sitter`) and TreeSitterLanguages' queries and indentation rules (`Licenses/TreeSitterLanguages`), from source, by way of Irisin's vendored copy; README.md there names every origin and change. Owner decision 2026-10-17: only the grammars Apelin highlights are kept, every other one Runestone.xcframework carried is dropped, and the xcframework with them. App only. |
| tree-sitter grammars in Runestone | MIT, each with its upstream `LICENSE` beside its source and a `Licenses/tree-sitter-<name>` folder holding the same text (`make check` compares them). From Runestone.xcframework 2688e46's vendored set: Bash, C, C++, JSON, Markdown and Markdown inline, Python, Ruby, Swift and YAML, each checked against its upstream's licence history. Added: Objective-C (tree-sitter-grammars/tree-sitter-objc 3.0.2), XML (tree-sitter-grammars/tree-sitter-xml 0.7.0) and Make (tree-sitter-grammars/tree-sitter-make 1.1.1), MIT since each one's first commit. Dropped with the xcframework (2026-10-17), and their folders with them: Astro, Comment, C#, CSS, Elixir (Apache-2.0, and its NOTICE), Elm, Go, Haskell (and nvim-treesitter's Apache-2.0 query header), HTML, Java, JavaScript, JSDoc, JSON5, Julia, LaTeX, Lua, OCaml, Perl, PHP, R, Regex, Rust, SCSS, SQL, Svelte, TOML, TypeScript and TSX. Lua's missing licence is no longer a question: it is not shipped. |
| libghostty-spm 2.2.2026101502 (GhosttyTerminal, GhosttyTheme; 42bacd1) | MIT packaging; bash-preexec MIT and the iTerm2 colour schemes MIT, both in the checkout. Its shell integration is the package's own MIT rewrite, not Ghostty's GPLv3 scripts, and its own `check-licenses.sh` guards that. GhosttyKit.xcframework is a static `libghostty.a`, built from ghostty 1e9e14af5df1. Its members and strings were read, and it holds Ghostty (MIT, the same notice iGhostVT reviewed) plus FreeType 2.13.2, under the **FTL** chosen from FTL-or-GPLv2 (the credit line heads its notice, and `LICENSE.TXT`, the chooser that names the GPL, is not shipped). It also holds Oniguruma 6.9.9 (BSD-2-Clause), libpng 1.6.43, zlib 1.3.1, wuffs 0.4 (Apache-2.0 or MIT), simdutf 9.0.0 (Apache-2.0 or MIT), Highway 1.2.0 (Apache-2.0 or BSD-3-Clause), stb_image (MIT or Unlicense), libxev, zig-objc and uucode (MIT; Unicode-3.0 data), JetBrains Mono (OFL-1.1), Symbols Nerd Font 3.4.0 (MIT), the Zig 0.16 runtime (MIT) and libc++ headers (Apache-2.0 with the LLVM exception). Each has a `Licenses/ghostty-*` folder. **z2d (0.12.1, 7dbae85c8178) is MPL-2.0. Owner decision 2026-10-17: accepted as a reviewed exception** (`gplExceptions`, bound to its text hash and libghostty-spm's revision). It is unmodified and statically linked into the app only. Its GPL-family wording is only MPL-2.0 §1.12's definition of "Secondary License". Its notice names the upstream repository and commit as the source location, per §3.2. The Nerd Font's glyph sets, as Nerd Fonts 3.4.0's `license-audit.md` lists them, each have a `Licenses/ghostty-nerd-fonts-*` folder. Under CC-BY-4.0: Codicons. Under OFL-1.1: Font Awesome (the font files), Pomicons and Weather Icons. Under Apache-2.0: Material Design Icons. Under MIT: Devicons, Font Awesome Extension, IEC Power Symbols, Seti-UI and the Nerd Fonts originals, Octicons, Powerline Extra Symbols and Powerline Symbols. Under the Unlicense: Font Logos. Revision in `binaryRevisions`. App only. |
| SPIndicator 1.6.5, AlertController 3.0.0, Then 3.0.0, SnapKit 6.0.0, SwifterSwift 8.0.0, Dog 0.1.2 | MIT. The wheels the sibling apps share (owner, 2026-10-17). App only, static; SnapKit's `SnapKit-Dynamic` product is not linked. |

| ScrubberKit 0.2.0 (b69932d), SwiftSoup 2.14.3, Turndown | MIT, each full notice bundled. App only. ScrubberKit is FlowDown's webpage importer; it replaces a new, handwritten HTML extraction and conversion pipeline. Its SwiftSoup parser and bundled Turndown scripts preserve that import behavior. No dependency is added to the daemon or workers. |
