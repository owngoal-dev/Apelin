# Handoff: starting the UI

Milestone 1's data layer is done: every operation exists, is tested on the
Mac and is driven headless through the console. The UI is Irisin's split
navigation with the project's conversations in the sidebar (`AGENTS.md` ▸
The root). This page is where the UI phase starts. The plan is `Milestone-1.md` (§10 for the UI); process
layout, wire and rules are in `AGENTS.md` ▸ Decisions, which wins when this
page and it disagree.

## What the UI calls

**`ApelinService`** (`Packages/ApelinKit/Sources/ApelinProtocol/Service/`)
is the only surface: one typed `async throws` method per `AppOperation`,
defined beside its request and response types in `Operations/<Domain>.swift`.
The app's binding is `ApelinService.app` (`Apelin/Service/ApelinService.swift`,
over `DaemonClient`); the console and the agent's tools call the same
methods, so whatever the console scripts do, the UI can do the same way.
Failures are `ApelinError` {code, message, reason?}: show `message` to
people, branch on `code` and `reason`, never on the text.

Operations by area (the full list is `AGENTS.md` ▸ The wire):

| Area | Operations | Screen it feeds |
|---|---|---|
| Connection | `hello` (install root, protocol, operation list) | the *Connecting…* state; no error while apelind starts |
| Environment | `toolchainStatus/Catalog/Setup/Remove`, `sdkList/Import/Remove`, `environmentAttach/Cancel` | Settings ▸ Toolchain, SDKs |
| Projects | `extensionList`, `projectCreate`, `projectCheck` | new project from a template; project problems |
| Build and install | `buildStart/Attach/Cancel`, `installPackage`, `removePackage`, `installationList`, `respring`, `approvalDigestState` | build log, diagnostics, install |
| Files | `fileRead`, `protectedEditOpen/Commit` | editor; protected edit with confirmation |
| Terminal | `ptyOpen/Attach/Resize/Close` (`ptyAttach{wantsDescriptor}` hands over a live socket) | terminal |
| Logs and crashes | `logStream`, `crashList`, `crashOpen` (descriptor), `crashSymbolicate` | logs, crash list and detail |
| Diagnostics | `confirmLoaded`, `confirmLoadedAttach`, `confirmLoadedCancel`, `captureScreen`, `readUITree`, `uiAction` | "is it loaded", manual UI check |
| Agent | `agentOpen/Prompt/Steer/Abort/Approve/Attach/List/Close`, `agentCredentialImport`, `agentAccountList`, `agentSignIn/SignInRespond/SignInCancel/SignOut` | agent panel, approvals, Settings ▸ Model Providers |
| Tool extensions | `toolHostOpen/Call/Close` | (agent-side; the UI lists extensions) |
| Git | `gitStatus/Diff/Stage/Unstage/Commit/Clone` | git |

## The UI dependencies are linked

The app target (and only it: never apelind or a worker) links every UI
package the owner chose on 2026-10-17. Package size was not a constraint:
`DisplayLink`, `ListViewKit`, `Litext` and `LitextAnimation`,
`MarkdownView` and `MarkdownParser`, `Runestone`, `GhosttyTerminal` and
`GhosttyTheme`. They bring SwiftMath (all twelve math fonts), swift-cmark,
LRUCache and the shared swift-collections pin with them. `import` them and
use them; no source in the app imports any of them yet. Things to know:

- **Runestone** is vendored from source in `Packages/Runestone` with only
  the grammars Apelin highlights (`AGENTS.md` ▸ Runestone is vendored and
  trimmed; the package's README.md). `import Runestone` for the text view,
  `RunestoneLanguageSupport` for the languages and
  `RunestoneThemeSupport` for Tomorrow and One Dark. Open a file with
  `RunestoneLanguage(fileName:)` (nil is plain text), build its
  `treeSitterLanguage` once per language, and hand
  `TreeSitterLanguageMode` a `RunestoneLanguageProvider` so Markdown fences
  and Makefile recipes are coloured. Runestone's resources are
  `Runestone_Runestone.bundle` beside the executable, which the packager
  requires. After changing the package, put the app on a vphone (`make
  vphone-app`) and open a file of each language it touched to see it
  coloured.
- **GhosttyTerminal** is libghostty (static) with its resource bundle
  (`GhosttyKit_GhosttyTerminal.bundle`: the MIT shell integration, terminfo,
  strings). The PTY is the session host's (`ptyOpen`, then `ptyAttach
  {wantsDescriptor}`), not GhosttyTerminal's own process code.
- New code that uses an iOS 17+ API is guarded with `#available`. The
  packages' own weak imports (UIKit traits, the Swift 6.2 iteration
  protocols) are theirs to guard.

## The sibling wheels are linked too

Also app only, at Irisin's pins (`AGENTS.md` ▸ The sibling wheels, one
reason each): `SPIndicator`, `AlertController`, `Then`, `SnapKit`,
`SwifterSwift` and `Dog`. All static, no new dylib; SnapKit, SwifterSwift
and AlertController add their resource bundles (privacy manifests, the
alert's strings) to `Apelin.app`. Nothing imports them yet. Not taken:
SDWebImage, ScribbleLetterView and GlyphixTextFx (Litext animates text
the same way).

- **Dog** is not wired up. When it is: `Dog.shared.initialization(writableDir:
  DataFolder(home: NSHomeDirectory()).root)` once in `didFinishLaunching`,
  which writes `~/Documents/wiki.qaq.apelin/Journal/`; never the no-argument
  call, which writes mobile's shared `~/Documents/Journal`.
- **AlertController** localizes what it is given: pass catalogue keys
  (`String.LocalizationValue`), as Irisin's `UIViewController+Alert` does.
- **With** has no licence; the decision is the owner's
  (`Licenses/Compatibility.md`).

### To port when the screen needs it

The siblings' own helpers, not copied yet. Paths are in the sibling
repositories under `owngoal-dev/`.

- `Irisin/Irisin/Interface/InterfaceHostController.swift` — root container that swaps split and compact layouts as the window resizes, without a tab bar controller. (The split, its column host and the detail navigator are ported, in `Apelin/Interface/Split/`; the compact layout is not.)
- `Irisin/Irisin/Interface/Components/Settings/SettingsController.swift`, `SettingsCell.swift` — inset grouped Settings driven by `SettingsItem` rows with live closures, and the build footer.
- `Irisin/Irisin/Interface/Components/Settings/LicenseController.swift` — the Licenses screen over `Licenses.json`, the same file our collector writes.
- `Irisin/Irisin/Interface/Components/LogViewerController/` — Dog's current journal as filterable rows, with a share menu.
- `Irisin/Irisin/Interface/Components/TextReaderController.swift` — read-only Runestone text view with line numbers, wrap toggle and Share.
- `Irisin/Irisin/Interface/Components/EmptyStateView.swift` — icon and one line in place of rows, usable as a `backgroundView`.
- `Irisin/Irisin/Interface/Components/ListContentCell.swift`, `ListFootnoteView.swift` — a content-configuration row that resets cleanly on reuse; a list's closing centred line.
- `Irisin/Irisin/Interface/Components/ProgressRing.swift` — the App Store download ring without a stop square.
- `Irisin/Irisin/Interface/Components/SettlingRefreshControl.swift` — a refresh control that closes over a short list without a jump.
- `Irisin/Irisin/Interface/Components/ShareSheet/ShareSheet.swift`, `ExportFile.swift` — share sheet with a weakly held iPad popover anchor; stamped export file names.
- `Irisin/Irisin/Interface/DesignTokens/` — UIKit design tokens: `TypeSize` (the Dynamic Type ramp), `UIColor+Content/Status/Surfaces` (accent, state and surface colours), `UIColor` (light/dark and hex initialisers), `Motion` (progress easing).
- `iGhostVT/iGhostVT/Interface/Support/DesignSystem.swift` — iGhostVT's tokens (`DS.Padding`, `Radius`, `Font`); SwiftUI, so the scales come across, not the code.
- `Irisin/Irisin/Extension/UIViewController+Alert.swift` — the AlertController wrapper: `presentNotice` and `presentConfirmation` (destructive accent swapped only while the sheet is built).
- `Fila/Fila/Interface/Shared/AlertInputViewController+Literal.swift` — `typingLiterally()`: an AlertController input field with no smart quotes, dashes or autocorrection, for names, paths and URLs.
- `Fila/Fila/Interface/Feedback/Toast.swift` — the SPIndicator wrapper: queued one-line toasts in a pass-through window that survives navigation and sheets.
- `iGhostVT/iGhostVT/Interface/Support/CopiedIndicator.swift` — SPIndicator "Copied", presented on the window the command came from (two iPad windows).
- `Fila/Fila/Interface/Feedback/UIViewController+Report.swift` — the one place a failure becomes a readable alert; a cancel shows nothing.
- `Irisin/Irisin/Extension/UIViewController.swift` — form-sheet content size on the navigator, `hideKeyboardWhenTappedAround`, `present(next:)`, `UINavigationController.halfSheet(root:)`.
- `Irisin/Irisin/Extension/UIView.swift`, `UILabel.swift` — nearest view controller up the responder chain; search-term highlighting in a label.
- `Irisin/Irisin/Extension/DiffableDataSource.swift` — diffable snapshots that keep surviving items' cells, an editable table data source, windowed list updates.
- `Irisin/Irisin/Extension/LockedState.swift` — a value behind an `os_unfair_lock` in its own allocation.
- `Irisin/Irisin/Extension/Task.swift` — `Task.sleep(seconds:)`, a sleep that counts while the device sleeps, and `wait(upTo:)` on a task.
- `Irisin/Irisin/Extension/String.swift` — `String(resolving:)`, a `String.LocalizationValue` parameter resolved without the catalogue sync warning.

## Tasks and attach

Long work answers a `TaskHandle` {taskID, kind}, not a result. The session
host owns the task: it outlives the app, a respring and a host restart
(builds, environment tasks and installs resume; see `AGENTS.md` ▸
Lifecycle). Read it with the kind's attach operation, or simply:

```swift
for try await event in ApelinService.app.events(of: handle, afterSeq: lastSeen) { … }
```

Events are numbered from 1 with no gaps. Keep the last `seq` per task;
after a dropped connection or a relaunch, call again with it and nothing is
lost or repeated. A task ends with a `state` event whose state is terminal
(`succeeded`, `failed`, `cancelled`, `interrupted`); `waitingForApproval`
is not terminal. Cancel with the domain's cancel operation.

Events the UI renders (payloads in `AGENTS.md`):

- **Environment**: `stage`, `progress`, `warning`, `result` (the SDK,
  the toolchain, the removed id or the clone), then `state`; a resumed
  task shows `resumed` {resumes} and starts its work over.
- **Build**: `stage {stage, product?}`, `log {line}`, `diagnostic` (file,
  line, column, severity — jump to the line), `artifact`, final `state`
  with `artifactID`, `digest`, `buildID`.
- **Install**: `irisin` (irisind's progress), then `result`; a removal
  ends with `removed`.
- **Terminal**: `started`, `output` {base64, text}, `exit`.
- **Log stream**: `log` {time, process, pid, subsystem, category, level,
  message}; may end `truncated`.
- **Load check**: `stage` {`listening`, `trigger`}, then `state` carrying
  `result` {loaded, evidence}. Evidence is `log` (the marker), `image`
  (always `notRead`) and `filter`. A `trigger: respring` takes the app
  down; reattach to the task at the next launch and the answer is there.
- **Agent**: `prompt`, `steer`, `messageStarted`, `text` and `thinking`
  (coalesced), `message`, `toolCall`, `toolResult`, `approvalRequested`
  then `state waitingForApproval`, `approvalResolved`, `error`,
  `finished {reason}`. Nothing approves by default: an approval waits
  until the app answers.

New since the last UI-facing change:

- **`agentApprove` takes `scope`**: `once` (the default) or `session`, only
  where the `approvalRequested` event says `allowsSessionScope`. For
  `run_code` a session approval covers that command in that working
  directory for the rest of the session.
- **`unreadable` events**: when a task's log has a line the host cannot
  read, the number is kept and filled with an event of kind `unreadable`.
  Show it like any other event (a muted "an event could not be read" row);
  do not stop reading.
- **`reason: notAPreset`**: the host refused a `run_code` the agent
  claimed was a read-only preset. It is `denied` with that reason, and it
  is the agent's to handle by asking the user, which arrives as an ordinary
  `approvalRequested`. The UI shows no error for it.

## Working without a device: the replay

A vphone or device without the package has no apelind, so every screen
above would show only *Connecting…* and then the unprivileged fallback.
**`ApelinReplay`** (`Packages/ApelinKit/Sources/ApelinReplay`) fills that
gap: `ReplayTransport` is an `ApelinTransport` that answers from real event
streams captured by the console on the iOS 26.4 roothide vphone, and
`ApelinService.replay(try ReplayFixtures.bundled())` is an `ApelinService`
over it. It depends on ApelinCore and ApelinProtocol only and is linked into
nothing yet.

What it holds (`Fixtures/`, about 110 KB; `replies.json` and one
`tasks/<name>.json` per task):

| Recording | What it shows |
|---|---|
| `d1-tweak-build`, `d1-app-build`, `d1-cli-build` | three successful builds: stages, clang command lines, artifact, final state |
| `d2-build` | a failed build with two `diagnostic` events (file, line, column) |
| `d1-install` | an install through irisind: `stage`, 23 `irisin` progress events, `result` |
| `d1-loaded` | a load check across a respring: `listening`, `trigger`, `state` with evidence |
| `d1-logs` | a log stream (trimmed to 20 entries) ending `truncated` |
| `d1-pty` | a terminal: `started`, eight `output` events with ANSI colour; still open |
| `a1-agent` | a Relaxed agent session (openAICompatible, deepseek-chat): text, tool calls, a build, the report |
| `c1-agent` | a Confirm session: `approvalRequested` for `run_code`, held until `agentApprove`, then its result |
| `s1-abort`, `s1-steer` | a session aborted mid-run and closed; one steered mid-run, with streamed text |
| replies | `hello`, `extensionList`, `toolchainStatus`, `sdkList`, six `projectCreate`, `projectCheck`, `agentList`, `agentCredentialImport`, `agentApprove`, `agentAbort`, `agentSteer`, `agentClose`, `ptyClose` |

How it answers: a plain operation gets the latest recorded reply whose
request is the same, else the latest of that operation, else `unavailable`
(nothing recorded: the toolchain and SDK setup, git, files, crashes,
screenshots, the UI tree, tool extensions). A starting operation
(`buildStart`, `agentOpen`, `logStream` with a filter, …) picks its
recording the same way and starts that task's clock; attaches are real long
polls (`afterSeq`, `waitMilliseconds`, `finished`). `.recorded` pacing
releases events as far apart as recorded (gaps capped at 1.5 s, at least
50 ms apart, so streamed text streams); `.immediate` releases everything.
An agent session stops after each `waitingForApproval` until `agentApprove`
names it. IDs and times are the recorded ones; nothing changes state (a
`projectCreate` adds no project to the next answer); no descriptor is ever
returned.

**Selecting it at runtime** — left for the UI phase, and never by build
flag (`AGENTS.md` ▸ Hard rules: the backend is resolved at runtime):

1. Link `ApelinReplay` into the app target in every configuration; Xcode
   embeds its resource bundle (`ApelinKit_ApelinReplay.bundle`) beside the
   other package bundles. The fixtures then ship in the app; check that
   `make deb` still passes the packager's repository-path grep.
2. Where the app binds `ApelinService.app`, check one launch argument before
   the first `hello`: with `-apelin-replay` (or `-apelin-replay immediate`),
   bind `ApelinService.replay(try ReplayFixtures.bundled(), pacing: …)`
   instead of `DaemonClient`. Its `hello` answers at once with the recorded
   install root, so the app takes the privileged path.
3. Show that it is a replay (a badge in the connection state), so a
   screenshot is never mistaken for a device.
4. Pass the argument from the scheme (Run ▸ Arguments) when Xcode runs the
   app on a device. `Scripts/device.py open` launches the vphone's copy
   with no arguments, so a vphone run needs it to pass one first.

**New captures**: run the scripts in `Documents/Console/demo/` on a device
(`Documents/Console.md` ▸ Demo captures), copy `console/out/*.jsonl` into
`<folder>/out/` and the scripts into `<folder>/scripts/`, run
`Documents/Console/demo/make-replay-fixtures.py <folder>`, then `make
harness`: `ApelinReplayTests` reads every fixture strictly through the
protocol types, so a fixture and the protocol cannot drift apart unnoticed.
Read the diff before committing it.

## What is proven, and where

`Documents/Research/Device-Validation.md` is the record: every console
script passed on the iOS 26.4 and iOS 27.0.1 roothide iPhone vphones,
including the whole chain (toolchain setup, SDK, project, build, install
through irisind, respring, load confirmed by its marker) and resume after a
killed session host. The Mac harness covers the rest (`make harness`).
Nothing has run on rootless, real hardware, iOS 16 or an iPad; the agent
has only been run up to its refusals (no credential on the devices). The
owner-device checklist is at the end of that record.

## Open items and known limitations

1. **The UI** (this phase): standard sidebar split view on iPad, collapsing
   to navigation on iPhone (`AGENTS.md` ▸ The root); the accessibility rules
   apply from the first screen.
2. **A live agent run** with an `openai-compatible` credential (DeepSeek)
   is what the replay fixtures captured — Relaxed, Confirm with an
   approval, abort and steer; Copilot and Anthropic still need their
   credential dropped in `~/Documents/wiki.qaq.apelin/console/inbox/credentials/`
   on a device.
3. **The owner's devices**: rootless, real hardware, iOS 16, iPad, the
   Swift toolchain component (refused today), slow network, HTTPS SDK
   sources.
4. **The image list is never read** and cannot be: it panicked the iOS 27
   kernel three times. Only the marker decides `loaded`; the marker is seen
   only with `trigger: respring` or a target relaunched during the window.
5. **`owngoal-dev/iOS-SDKs`** is the enabled default source (owner,
   2026-10-19), one SDK per branch from 14.5 onward, credited to
   `xybp888/iOS-SDKs`. Versions 13.0–14.4 lack C++ standard library headers
   and were removed from the source after validation. A
   toolchain setup imports the newest compatible SDK when none registered
   fits; Swift also requires the SDK major its macro plugins match. The
   source branches name versions; the imported SDK's metadata decides its
   actual identity. An explicit source list replaces the default.
6. **owngoal-packages** keeps one deb per architecture per release, so the
   extension packages are not indexed until it matches assets per package
   id.
7. **Left as known, not fixed** (no failing case worth the change): one
   event feed for all workers; attachment copies inside the tool-host
   actor; each long `run_code` holds a GCD thread; two git spawns per
   preset check; a `run_code` descendant that leaves its process group
   with `setsid` is not killed (its pipes close after a 2 s drain, so the
   call ends, marked `truncated`); the run_code pipe readers wake every
   100 ms; an interrupted toolchain setup leaves its job record until the
   next setup of that source.
8. `Localizable.xcstrings` has no entries yet: the scaffold's English
   strings are their own keys.

## How to verify

- `make check` — checklist, project, packaging, strings, accessibility and
  floor gates.
- `make harness` — the Mac host tests, including every console script
  decoded and every operation called by one. Run it first.
- `make deb-all` — every package, verified; `make vphone` (the running
  vphone, or `VPHONE=<name>`) or `make install` to put one on a device, then
  `make device-test` to run the console scripts on it (`SUITE=regression`
  for all of them; `Documents/Console.md` ▸ From the Mac).
- **CI** runs on every push to main and every pull request. `release.yml`
  waits for a passing CI run of the tagged commit, so let it pass before
  any release tag.
