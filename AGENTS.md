# Apelin — Agent Notes

An on-device IDE where an agent writes, builds and installs tweaks, for
jailbroken iOS 16.0+ — roothide and rootless bootstraps both. **iOS only**: there is no Mac Catalyst build and no
macOS product. The app runs as `mobile`; with the privileged backend, the
bundled `apelind` LaunchDaemon does the privileged half as root. Without that
backend, the app still works under its own OS permissions.

The single idea the design hangs off: **apelind is a session host** — the
launchd job is a thin, authenticated proxy that launchd starts on demand, whatever
must outlive the app with unbounded memory lives in a child launchd never
sized, and nothing on the wire is a command. The child is `apelind-session`,
the same executable in session mode; the workers are its children.

## Hard rules

- **The checklist comes before the code.** `CHECKLIST.md` is every one-time
  decision this repo has to make. No code is written until every box is
  ticked and `make check` passes `Scripts/check-checklist.sh`, which runs
  first and lists what is still open. An agent starting here works through
  it top to bottom and ticks a box only after doing or deciding the thing;
  one that does not apply is ticked with the reason beside it. The file
  stays, ticked: it is the record of what was decided.
- **One app, several wrappers, and the backend is resolved at runtime.** Never a
  build flag, never a compilation condition, never a per-packaging source
  variant. The handshake with the daemon is the only honest answer to "am I
  privileged", and it carries the install root rather than a boolean beside it.
- **The daemon's absence is never surfaced as an error.** A miss means launchd
  has not started it yet. Keep retrying, keep saying *Connecting…*, and fall
  back only after a grace period measured as a duration from the first miss —
  not a timeout, not a count of attempts. apelind is on-demand, never
  `KeepAlive` or `RunAtLoad`: it stays up while it has work — a build, an
  environment task, a PTY, an agent session, an install, a connected app —
  and exits only after it has been idle with none of them. Task records are
  on disk before it exits; the next launch resumes them.
- **Peer authentication happens before the first request is decoded.** Audit
  token, euid 0 or 501, the client entitlement and `no-sandbox`, then the
  executable on disk (root-owned, not group/world writable). Require
  `platform-application` only if the app actually carries it — match both
  sides.
- **No install prefix is written in Swift.** Derive it from the daemon's own
  `proc_pidpath`; anything that needs it asks the daemon. Packaging fails on
  `libvroot` in the app, daemon or helper.
- **roothide is recognised by the process's own path** (`RoothideRoot`,
  libroothide's own name rule), never by loading libroothide through the
  `.jbroot` link, which is not promised, and never by falling back to
  "`/var/jb`, so rootless". The daemon's `hello` stays the authority on the
  install root.
- **Every path is canonicalised before a decision is made about it.**
  `realpath(3)` first, then compare components; reject an embedded NUL first.
- **A recursive `rm` never runs on an unchecked variable.** An empty one
  makes the path `/`, which on roothide is the bootstrap's root, and a
  maintainer script runs as root. Apelin's scripts, the
  `update-repository.sh` it writes into a user's package repository and the
  scripts the agent's skills hand out spell each variable in a recursive
  `rm` `${name:?}` (`$${name:?}` in a Makefile), so the shell stops before
  the command runs; `make check` runs `Scripts/check-shell-deletes.py`. The
  agent is told the same in the prompt's `# Working`, and the
  apelin-external-build skill's script starts by checking every variable
  Apelin sets (`$APELIN_PREFIX` set and empty on roothide), which
  `EmptyVariableGuardTests` runs with them missing, empty and set.
- **Start `ExecutableWatch` once, early in `didFinishLaunching`.** When the
  opened executable loses its last hard link, offer Later or Quit with wording
  covering both update and removal. Keep the registration-time check and the
  cancellation guard; the callback runs once on the main queue. Do not watch
  daemons: postinst restarts them after unpacking finishes. Omit this watch
  for a self-updating installer whose helper owns completion and exit.
- **The app never calls `exit` from the foreground.** A screen that vanishes
  reads as a crash. Quit, and any other exit the app chooses, is
  `QuietExit.run`: leave for the home screen, wait for the animation, run the
  cleanup `exit` would skip, then exit.
- **The app's data folder is `~/Documents/wiki.qaq.apelin`, and the package
  makes it.** The app has no container, so its home is mobile's —
  `<jbroot>/var/mobile` on roothide, `/var/mobile` on rootless — shared with
  every other app without one. Anything it keeps there goes in a folder named
  for its bundle id, the isolation a container would give, inside a
  `Documents` mobile owns, which a container would have had too. The postinst
  (dpkg, as root) makes each missing level — home, `Documents`, the folder —
  and hands it to mobile on its own, leaves a level that exists alone, and
  never follows a symlink. Never `mkdir -p` as root: it leaves every level
  above the last one root's, and Irisin 4.3.4–4.5.25 left a roothide
  bootstrap's `Documents` root's that way, so no other app without a
  container could make anything there.
- **A cold launch starts with no saved scenes.** `main.swift` deletes this
  bundle's `Library/Saved Application State/<id>.savedState` before
  `UIApplicationMain`. UIKit reads that archive before any scene delegate
  runs; leftover sessions from a previous UI framework or Info.plist restore
  the old delegate. Background resumes do not run `main`. Preferences stay.
  The app delegate is not `@main`.
- **The app icon is never looked up by name.** An Icon Composer icon leaves
  `AppIcon` in the catalogue as an image stack with no bitmap, and on iOS 26
  `UIImage(named: "AppIcon")` aborts inside UIKit rather than returning nil.
  In-app uses draw the `AppIconMark` image set. Another app's icon comes
  from IconServices, then from its `CFBundleIconFiles` names read as files
  with `UIImage(contentsOfFile:)`, never `UIImage(named:in:)`.
- **The app icon is three JPEGs in `AppIcon.appiconset`.** An Icon Composer
  `.icon` compiles to six 1024×1024 lossless renders (any, dark, tinted, for
  phone and again for pad) — megabytes no build setting removes. The `.icon`
  is the source, in `Documents/Icon/` and in no target; the skill's
  `scripts/render-app-icon.py` writes the icon set from it, and runs again
  after every edit. `AppIconMark` is the any and dark renders scaled to
  88 pt (JPEG, 1x–3x, `sips -Z`), made again with them. Test a changed icon on a device with the package removed
  first: installing over it can leave IconServices drawing the cached icon.
  Opaque image sets may be JPEG too; transparent ones stay PNG. Never reduce
  colours to save space.
- **A control with no text has no name.** Every icon-only button, bar button
  item and invisible button over a row gets an `accessibilityLabel` when it
  is written, not in a pass afterwards. The trait already says "button".
  Set the label beside the state it describes, or it goes stale: a
  pause/resume button labelled once at construction lies for half its life.
- **A label on a container UIKit does not treat as an element is never
  read.** A `UIView`, `UITableViewCell` or `UICollectionViewCell` with
  subviews is not an accessibility element, so the sentence `configure`
  assembles is walked past and the subviews are read instead, one stop each,
  with the drawn separators spoken. Set `isAccessibilityElement = true` on
  any cell or view that labels itself; `make check` runs
  `Scripts/check-accessibility.py`, which fails on a label that nothing can
  reach. A row that joins several labels puts the figure that changes in
  `accessibilityValue`, so a live sample re-announces the number without
  repeating the name. Setting the flag hides the subviews, so a row that
  owns a button — menu accessory, disclosure, checkbox — gives each one an
  `accessibilityCustomAction` or keeps the flag off and labels the subviews
  instead. Decide which before setting it; do not copy the neighbouring
  cell, which may be unreachable itself.
- **State that is only drawn is not spoken.** A checkmark, a tick, a
  selected card, a progress fill: `accessibilityValue` or a trait
  (`.selected`, `.isHeader`), never prose bolted onto the label. And a label
  that repeats what VoiceOver already reads is a regression — a
  `UIListContentConfiguration` row reads "title, value" already, a `UISwitch`
  supplies its own on/off, and a titled `UIAction` is already named.
- **Accessibility is semantics, never behaviour.** No
  `UIAccessibility.post(.layoutChanged)` on a routine view swap: it steals
  focus, and on a live-sampling screen it does so on every sample. No custom
  action that duplicates one the rotor already offers. Announce an event the
  user cannot see; nothing else.
- **Reading another app's bundle or container takes
  `com.apple.private.security.storage.AppBundles` and `.AppDataContainers`
  beside `no-sandbox`**, on the app and on the daemon; `no-sandbox` alone
  does not open them on every platform.
- **CI builds; Release publishes what CI built.** `ci.yml` compiles, packages
  and verifies on every push and pull request, and keeps `build/Packages/` as
  the artifact `<app>-<sha>` for thirty days. `release.yml` runs on the tag,
  compiles nothing, waits for that commit's CI run, refuses to publish unless
  it passed, and ships the bytes CI verified. Never rebuild at tag time: a
  second build is a different build number, a different runner image and
  bytes no test ever ran against. The workflow stays named `Release` —
  `pages.yml` watches for it. Tag a commit only after its CI run passed.
- **The release notes are a file in the repo**, `<docs>/Releases/<version>.md`,
  written before the tag. One headline sentence saying what this release
  does, one bullet per user-visible change in the user's words with the
  symptom first, and a closing line naming the package to choose and
  `SHA256SUMS`. No commit shas, no internal names, no `--generate-notes`
  compare link — that tells a user nothing they could not already read.
- **A crash is read before anything is changed.** Keep the dSYM of every
  build installed on a device, match it to the report's image UUID
  (`dwarfdump --uuid`), and symbolicate with `atos -o <dSYM DWARF> -l
  0x100000000 <0x100000000 + imageOffset>` before guessing at a cause.
- **Every path launchd opens names its root.** Roothide's launchctl puts the
  bootstrap root in front of the program, `WatchPaths`, `QueueDirectories`,
  `Standard*Path` and the other paths launchd reads, unless one starts with
  `/rootfs/`; rootless's passes them through. A bootstrap path is spelled
  `@PREFIX@/…`, a system one `@ROOTFS@/…` (the packager writes `/rootfs` for
  roothide, nothing for rootless). `Scripts/check-launchd-paths.py` fails
  `make check` on a bare one; a plist without such keys needs neither.
- **Versions and the deployment target live in `Configuration/*.xcconfig`
  only.** `make check` rejects either in `project.pbxproj`.
- **No project generators.** `project.pbxproj` is hand-written; `objectVersion`
  is pinned and `make check` fails when Xcode rewrites it.
- **Name no specific package manager.** README, these notes and script
  messages say "your preferred package manager".
- **No Swift file names the SDK's XPC constant macros.** They come from
  `Shared/XPCShim` through `AppXPC`; naming them in Swift links a dylib that
  iOS 15 does not have. `make check` greps for them.
- **No SF Symbol newer than `IPHONEOS_DEPLOYMENT_TARGET`.** It draws nothing on
  the floor and warns nowhere. `make check` checks it against CoreGlyphs.
- **No new dependency without a reason that survives the ladder**: what it
  replaces, and why the hand-written version would be worse rather than merely
  longer. Nothing third-party links into the daemon.
- **The Licenses screen is generated, not written.** The app target's
  **Collect Licenses** build phase runs `Scripts/collect-licenses.py`, which
  writes `Licenses.json` into the app bundle from the repository `LICENSE`,
  every pin in `Package.resolved` (checkouts and binary artifacts, nested
  notices included) and any vendored source. A pin with no notice or
  GPL-family text fails the build. Vendored code keeps its upstream `LICENSE`
  beside it and its header on each file; MIT / BSD / Apache only. `make check`
  requires the phase, the packager requires the file. Read the generated list
  after adding a dependency.
- **No absolute build path in a shipped binary.** `#file` is concise
  (`SWIFT_UPCOMING_FEATURE_CONCISE_MAGIC_FILE`, prefix maps in `Base.xcconfig`);
  the packager greps every binary for the repository root and fails on a hit.
- **User-facing text is a `String.LocalizationValue` spelled out in English**,
  resolved against `Localizable.xcstrings`. No `NSLocalizedString`, no
  `SHOUTING_KEY` identifiers; `make check` greps for both. Pick one catalogue
  discipline and keep it: compiler `.stringsdata` with no `extractionState`,
  or unseen keys kept as `manual` and pruned by hand.
- **No key Xcode marked stale survives a build.** `make check` runs
  `Scripts/check-stale-strings.py`, which refuses `extractionState: stale` and
  ignores `manual`. The marker is written during an ordinary build, into a
  file too large to read, and otherwise rides into a commit as one green line.
- **Stale does not mean dead — never bulk-delete a stale key.** The extractor
  reports on the target it just built, so an iOS build marks every
  macOS-only and visionOS-only string stale while all of them are live; so is
  a key reached by interpolation or named in a xib. `Scripts/prune-xcstrings.py`
  therefore keeps what it cannot find, as `manual`, and prints it as an orphan
  candidate. Pass every target's sources. `--delete-orphans` is opt-in and is
  for a single-target app only: with a root missing it takes live strings and
  all of their translations out in one commit.

## Decisions

What `CHECKLIST.md` asked to be written down, and where the answer lives.

- **The wire** (`Packages/ApelinKit/Sources/ApelinProtocol`) is a closed
  list of operations, `AppOperation`, and none of them is `exec(path, argv)`:
  `hello` (answered by apelind itself with the install root it derived from
  its own path, its protocol version and the operation list);
  `toolchainStatus`, `toolchainCatalog`, `toolchainSetup`, `toolchainRemove`,
  `toolchainSelfTest`, `toolchainSetDefault`; `sdkList`,
  `sdkImport`, `sdkRemove`; `environmentAttach`, `environmentCancel`;
  `extensionList`, `projectCreate`, `projectCheck`, `projectRename`,
  `projectDelete`; `buildStart`,
  `buildAttach`, `buildCancel`; `installPackage`, `removePackage`,
  `installationList`, `respring`, `approvalDigestState`;
  `fileRead`, `protectedEditOpen`, `protectedEditCommit`; `ptyOpen`,
  `ptyAttach`, `ptyResize`, `ptyClose`; `logStream`, `crashList`,
  `crashOpen`, `crashSymbolicate`; `confirmLoaded`, `confirmLoadedAttach`, `captureScreen`,
  `readUITree`, `uiAction`; `agentOpen`, `agentPrompt`, `agentSteer`,
  `agentAbort`, `agentCompact`, `agentApprove`, `agentAttach`, `agentList`, `agentClose`,
  `agentRunCode`, `agentCredentialImport`, `agentAccountList`, `agentSkillList`, `agentAPIConfiguration`, `agentModelList`, `agentModelActivate`, `agentSignIn`,
  `agentSignInRespond`, `agentSignInCancel`, `agentSignOut`; `toolHostOpen`, `toolHostClose`,
  `toolHostCall`;
  `gitStatus`, `gitDiff`, `gitStage`, `gitUnstage`, `gitCommit`, `gitInit`,
  `gitClone`, `gitCloneInto`, `gitFetch`, `gitPull`, `gitPush`, `gitSettings`,
  `gitAuthorSet`, `gitCredentialSet`, `gitCredentialRemove`,
  `gitRepositoryCreate`, `gitIssueCreate`, `gitSquash`, `gitRemoteList`,
  `gitRemoteSet`, `gitRemoteRemove`, `gitResetPreview`, `gitResetToRemote`;
  `distributionRepositoryList`, `distributionRepositoryCreate`,
  `distributionRepositoryLink`, `distributionRepositoryUnlink`,
  `distributionPublish`, `feedbackSend`, `feedbackRead`, `feedbackEdit`,
  `feedbackStarState`, `feedbackStar`;
  `transferExport`, `transferInspect`, `transferImport`. Every one is
  in the list today; most answer `unimplemented` until their domain lands.
  The envelope (protocol version 2) carries `op`, `protocolVersion`,
  `requestID` and a JSON `payload`, with descriptors beside it by index
  (`DescriptorSlot`); a reply is `ok` with a JSON payload or `error{code,
  message, reason?}` (`reason` an open-ended name a caller acts on, absent
  when unset). Between the app and apelind it is an XPC dictionary
  (`Shared/Protocol/XPCEnvelope.swift`, descriptors as XPC fd objects); between
  apelind, its session host and the workers it is a `WorkerChannel` frame
  (length-prefixed JSON over a socketpair, descriptors by `SCM_RIGHTS`).
  Long work is a task: `TaskID`, events numbered by `EventSeq` from 1 with no
  gaps, read by a long-poll attach with `afterSeq` (replay is a lower
  `afterSeq`), ended by a `state` event, stopped by a cancel.
  An operation is added in four places together: its case in
  `AppOperation.swift` (`domain`, `requestType`); its request/response types
  and `ApelinService` method in `Operations/<Domain>.swift`; its case in
  `Apelind/Dispatch/<Domain>Handler.swift` (and `CallerPolicy` if a worker may
  call it); and this list. A worker-served operation is then a case in that
  worker's handler.
- **The authenticator** (`Apelind/PeerAuthenticator.swift`) decides before a
  request field is decoded, in this order: the kernel audit token; pid > 1;
  euid 0 or 501; the entitlements `wiki.qaq.apelin.client`,
  `com.apple.private.security.no-sandbox` and `platform-application`, each
  strictly true (the app carries `platform-application`, so it is required;
  drop it from both or neither); `proc_pidpath` realpath-equal to
  `<install root>/Applications/Apelin.app/Apelin`; that file regular,
  root-owned, owner-executable and not group- or world-writable.
- **No CLI.** The app is the only peer. A CLI would be a second one, added to
  `clientPaths`, signed with its own entitlements, and written down here.
  The console (below) is the app itself, and the workers reach the session
  host only through the socketpair it made for them, so neither is a peer.
- **Process layout.** `apelind` (root, the launchd job, on demand) is the
  proxy: it authenticates the peer, answers `hello`, forwards everything else
  unread, and exits 30 s after its last connection, request and session-host
  work (`Apelind/Proxy/WorkLedger.swift`) — past launchd's ten-second respawn
  throttle. `apelind-session` (root) is the same executable with
  `--session` and a socketpair as descriptor 3, the proxy's child — that
  name is only its `argv[0]`: the kernel names both processes `apelind`, so
  `killall` cannot tell them apart, and the host writes its pid to
  `<install root>/var/lib/apelin/session.pid` for a restart test to kill
  (`Documents/Console.md`). It holds the task
  registry (records and events in `<install root>/var/lib/apelin/tasks/`, an
  unfinished task resumed or `interrupted` on relaunch, an event line a crash
  cut short — a last fragment with no newline — cut off the file at load; a
  whole line that does not read stays in the file, is read past, and its
  number is an `unreadable` event, so the events after it and the final
  `state` survive with no gap), the worker supervisor and the
  per-domain dispatch (`Apelind/Dispatch/<Domain>Handler.swift`). Workers are
  spawned from `<install root>/usr/libexec/apelin/<name>` only if root-owned
  and writable by root alone, with `POSIX_SPAWN_CLOEXEC_DEFAULT`, the channel
  as descriptor 3, and — for mobile roles — uid, gid and groups 501 set by
  `posix_spawnattr_set_*_np` before exec; `WorkerMain` refuses an assignment
  for another role and drops to mobile itself if it is still root. The host
  records each worker's role at spawn and ignores what a worker says it is;
  `CallerPolicy` lets the agent call task-level operations (and
  `agentRunCode`; conversations, its project's or another's: `agentOpen`,
  `agentPrompt`, `agentList`, `agentAttach`, `agentAbort`, `agentClose`,
  each narrowed by AgentHandler; the device's toolchains and SDKs:
  `toolchainStatus`, `toolchainCatalog`, `toolchainSetup`,
  `toolchainSelfTest`, `sdkList`, `sdkImport`, a setup or import narrowed
  by `AgentEnvironmentRules`, and `environmentAttach` for the tasks its own
  session started — its git tasks too; never a removal or a cancel;
  `projectRename`, narrowed by `AgentProjectRenameRules`; `projectDelete`,
  narrowed by `AgentProjectDeleteRules`; `installationList`,
  every project's; `feedbackSend` and `feedbackEdit`, narrowed by
  `AgentFeedbackRules`, and `feedbackRead`;
  `gitRepositoryCreate`, narrowed by `AgentRepositoryCreateRules`;
  `gitIssueCreate`, narrowed by `AgentIssueCreateRules`;
  `gitResetToRemote`, narrowed in every mode by `AgentResetToRemoteRules`,
  with `gitResetPreview`;
  `distributionPublish`, narrowed by `AgentPublishRules`, the rest of the
  package repository's operations staying the app's), the
  environment worker `installPackage`, `removePackage`
  and `buildAttach` (its local toolchain package, through the same bridge),
  the diagnostics worker `crashOpen` and `respring`, and nothing else call
  anything. Workers: `apelin-environment` (toolchain, SDKs, git, transfer
  files; ApelinEnvironment, ApelinGit, ApelinProject, Packages/ApelinToolchain,
  which brings ApelinFormats' ApelinCodeSign),
  `apelin-build` (extensions, projects, builds; ApelinProject, ApelinBuild,
  Packages/ApelinFormats), `apelin-agent` (one per session; ApelinProject,
  Packages/ApelinAgent), `apelin-diagnostics` (icli, crashes, UI;
  Packages/ApelinDiagnostics), all mobile; `apelin-log-reader` (root,
  ApelinCore, ApelinProtocol and ApelinLogReaderWorker only). apelin-log-reader
  adds to ApelinCore and ApelinProtocol only ApelinLogReaderWorker, whose
  closure is ApelinLogReader, its Objective-C shim and the shared request
  types; apelind links those two, ApelinToolHost and ApelinToolCore
  (Packages/ApelinToolHost) and compiles the vendored IrisinExternalClient
  (`Apelind/Vendor/`, MIT, Irisin 4.7.0, its LICENSE beside it) — every one
  of them system code that depends on nothing else. `make harness` checks
  all of it (`Scripts/check-system-only.py`). The agent, diagnostics and
  log-reader workers' `main.swift` is one call into a package library
  (`ApelinAgentWorker`, `ApelinDiagnosticsWorker`, `ApelinLogReaderWorker`),
  so the logic is tested by `make harness`.
  Each worker's entitlements are `Packaging/Workers/<name>.entitlements`,
  never the client key.
- **The session host's own work** (`Apelind/Session/`), all of it state in
  `<install root>/var/lib/apelin/`, root's and 0700:
  - *Lifecycle.* `TaskRegistry.load` hands back every task the last host left
    running — the event log, not the record, says how far a task got and in
    what state, so one whose last `state` event is final is written back
    finished and never resumed, and only forward: a record already final
    keeps its state whatever the last readable line says, and when no final
    `state` line reads at all, the lines past the last that read become
    `unreadable` events and a closing `state` with the record's state and a
    note that its line could not be read is appended to the log, so an
    attach still ends on one —; the resumer registered for its kind
    (`registerResumer`) keeps it, the rest end `interrupted`. The record
    is written when the task is made, when its state moves, and for a
    resume plan or a cancel, never for an ordinary event (a reopened
    conversation relays tens of thousands), so `load` takes `lastSeq` and
    `updatedAt` from the last event that reads, the time only forward. Installs resume: a staged one is
    submitted again under its own transaction ID (irisind answers `dup`), a
    submitted one is followed again from the last event relayed. Builds and
    environment tasks resume (`Session/TaskResume.swift`): `startTask(…,
    resumable: true)` writes the operation, its payload and the calling
    worker into `resume` before the worker sees it; on relaunch, after the
    workers are configured, the host appends `resumed` {resumes} (numbering
    goes on from the last event) and sends the same request to a new worker
    under the same task ID with `resumed` in the frame header — a build keeps
    its build ID, and passes the host's checks again first. The worker starts
    over: apelin-build removes the build's artifact record and
    `Builds/<projectID>/<buildID>/`, apelin-environment's start clears
    staging and every project folder named in `Environment/clones/<taskID>`
    (still a repository or empty), a clone that had ended (its folder
    unmarked, a repository of the request's URL and branch whose
    `.git/config` names the task as `apelin.cloneTask`, written before the
    marker goes) answers that folder, an import answers an SDK already registered as that record,
    toolchain setup goes on from its job record, a `transferExport` writes
    its file again.
    Ended instead, with the reason: a task an agent session started (the
    session ended with the old host, so nothing would read it), a task
    started with a descriptor, a request whose URL has a user, password,
    query or fragment (credentials are never written down), `toolchainRemove`
    (its removal is an install task that resumes itself), `transferImport`
    (a project it placed would be placed twice; a toolchain install it made
    is in its job record for the same import run again), a cancel asked for
    before the stop (`cancelled`), and a task already resumed twice
    (`TaskResume.maximumResumes`), so a crash loop cannot keep apelind up.
    apelin-build kills its tools when the host's channel closes. A session
    host that exits while it reported work is started again by the proxy
    1.5 s later, so its tasks resume without waiting for the app. The work
    report counts tasks by kind (build, environment, terminal, agent,
    install, load check, sign-in) — resumed ones included —, live workers and tool
    extensions; the proxy counts the app.
  - *Install bridge* (`Session/Install/`). The host is irisind's client:
    apelind carries `wiki.qaq.irisin.client` (with `platform-application` and
    `no-sandbox`; the app and the workers never do), the main package
    depends on `wiki.qaq.irisin (>= 4.7.3)` — from 4.7.3 irisind takes an external client only at euid 0, which the session host is; nothing running as mobile may call it. `installPackage{artifactID,
    digest}` takes a build's artifact — recorded by the host from the build
    worker's own `artifact` event (`path` inside the data folder, `digest`,
    `packageID`, `version`, `projectID`, `packagingDigest`, `packageFiles`) —, a toolchain
    package `toolchain-<id>` from apelin-environment:
    `Environment/Artifacts/<artifactID>.deb`, which must be
    `wiki.qaq.apelin.toolchain.<id>` (the one Apelin-prefixed family a
    non-IDE source may install, and only that source; the environment
    worker removes only its own records) — or, from the app only,
    `file:<path inside ~/Documents/wiki.qaq.apelin>`. A writer for the
    bridge sets `DebPackageWriter.controlCompression = .gzip`: a zstd
    control member is judged by the ID its source promised and failed
    loudly if irisind reports another. The host
    copies it into `staging/` while hashing, refuses a digest that is not
    the request's and the build's, reads the control file itself (gzip, xz
    or plain control members), applies the managed-package rules, writes
    the installation record (`installations/<id>.json`: project and build,
    artifact digest, package, version, the lowercase-UUID transaction ID it
    chose, then irisind's receipt) and submits the staged copy by
    descriptor. When irisind refuses it, and only then, the host names who
    is in the way (`InstallConflicts`): each installed package whose
    `var/lib/dpkg/info/<package>.list` lists a file the build recorded
    (unless the deb Replaces it), or that the deb's unversioned Conflicts
    or Breaks names (the host compares no versions), as a `conflict` event
    (`InstallConflict`, with the installation `removePackage` takes when
    Apelin made it); the failure says who and how to clear it before
    irisind's own words, which stand alone when nothing is found. irisind
    decided already, and nothing is removed. `removePackage{installationID}`
    acts only on a record whose install succeeded and whose package is
    still installed at that version, with no newer record of the package
    (whose ID the refusal names);
    bootstrap core, Irisin, Apelin and essential or required packages are
    refused both ways, and so is installing over a package Apelin did not
    install (`ManagedPackagePolicy`). The agent removes only what a build
    installed, never a toolchain's record or a file's; apelin-environment
    only its toolchains'.
    `installationList{packageID?, projectID?}` is the read side, the app's
    and the agent's: per package still installed, its newest record
    (installation ID, package, version, project and build; a removal under
    way counts), newest first, with `removable` and the refusal
    `removePackage` from that caller would give as `reason`; the records
    themselves stay root's. The installed state is read from
    `var/lib/dpkg/status`, never through a package manager's binary.
    After a toolchain package's removal, and at start (before anything is
    resumed) for each `usr/lib/apelin/toolchains/<id>` whose package dpkg
    does not list and no install or removal still handles, the host takes
    away the folders roothide's `.jbroot` links kept (`ToolchainTreePruner`):
    only when every entry is a folder or a `.jbroot` link, the links
    unlinked without being followed and the folders removed bottom up; a
    file or any other link keeps the whole tree. `respring` is irisind's.
  - *Approvals* (`Session/Approval/`). The host keeps the Confirm-mode ledger:
    per project the template's build and packaging digests (recorded from
    `projectCreate`'s `descriptionDigests`) and every digest the user
    approved; per agent session its mode (default Confirm) and single-use
    removal approvals. An agent's `buildStart` under Confirm is checked
    against the build digest apelin-build's `projectCheck` reports
    (`descriptionDigests.build`) and forwarded with it as
    `approvedBuildDigest` (any the agent sent is dropped), which
    apelin-build's own check must find before a step runs; its install
    against the artifact's `packagingDigest`, its removal against a
    removal approval; a digest the host cannot get is a change.
    AgentHandler calls `approvals.setMode` on `agentOpen` and
    `recordApproval` / `allowRemoval` when it relays an approval, and
    takes what it added back (`withdrawApproval`,
    `takeRemoval`) when the session's worker does not accept the relay
    (`AgentApprovals.relay`). A description grant stays pending, in memory,
    until its worker accepts it (`confirmApproval`): a digest several
    sessions' relays hold goes only with the last pending grant and never
    once one was accepted, and a withdrawn grant puts back the approval it
    pushed out at the 64-entry cap — unless that one was itself still
    pending, which no worker accepted — in its own place in age order (an
    in-memory stamp per entry, given in file order on load), whatever
    order the grants are withdrawn in. The file's format is unchanged.
    Nothing on the wire writes the ledger, and
    `approvalDigestState` is its read side for the agent.
    The screen (owner, 2026-10-30; `Session/Agent/AgentScreenRules.swift`,
    ApelinProtocol's `ScreenConsent`): the session table keeps each
    session's Ask Before Using the Screen (`asksBeforeScreen`), the app's
    from every `agentOpen` and from an `agentPrompt` that carries it, an
    agent-opened session its opener's. While it is on, in every mode, an
    agent's `readUITree` and `uiAction` (DiagnosticsHandler, before
    `AgentUIActionRules`) each spend one approval the app gave this session
    whose own `approvalRequested` names exactly it — `detail.screenControl`
    {operation, request}, the target and action as the host is asked for
    them —, and `AgentApprovals.authorize` runs an `agentRunCode` whose argv
    word or script names one of `ScreenConsent.programs` (icli, `uiopen`,
    `uishoot`) as a word only on its `.user` approval of a card marked
    `screenControl` with exactly that `command`, or `rootCommand` as root
    (owner checked, Full included), in that directory. A preset, a
    `.relaxed` claim and a session grant run none of them; `agentClose`
    forgets what is left. The app's and the console's calls are untouched.
    Device setups and other projects (2026-10-22, in memory, per session,
    `Session/Agent/AgentEnvironmentRules.swift`, `AgentConversationRules`):
    in every mode an agent's `toolchainSetup` names an Apple catalog product
    and carries no package file, and its `sdkImport` is one branch of an
    HTTPS repository with no user, password, query or fragment and no
    descriptor — never a URL archive, the inbox or a file. Under Confirm
    each one also spends an approval the app gave this session whose own
    `approvalRequested` names exactly it (`detail.toolchainSetup`
    {productID, components} or `detail.sdkImport` {url, branch};
    `AgentApprovals.spend`), so one approval sets up one thing once and
    nothing is granted for the session. Likewise an `agentOpen` or
    `agentPrompt` that reaches another project spends one naming its
    project and its exact prompt or text (`detail.otherProject`), and a
    relayed approval of any call naming another project lets the session
    list and attach to that project's conversations
    (`AgentSessionTable.reachableProjects`, taken back with the relay,
    forgotten on `agentClose`); a temporary chat is never reached. An
    agent's `projectDelete` (2026-10-29, `AgentProjectDeleteRules`) never
    takes its own session's project, in any mode, and under Confirm spends
    one naming the project's id and folder (`detail.projectDelete`
    {projectID, folder, displayName}) after the host resolved it again.
    An agent's `distributionPublish` (owner, 2026-10-29; `AgentPublishRules`)
    names, in every mode, the repository and one digest per file, and each
    file must be an artifact a build reported to this host
    (`ArtifactRegistry.artifact(path:)`) with that digest: only what Apelin
    built, as it built it. Under Confirm it spends one approval naming
    exactly that repository and those files and digests, in order
    (`detail.packagePublish` {repository, sourceURL?, packages: [{buildID,
    packageID, version, architecture, bootstrap, file, digest}]}).
    An agent's forced push (owner, 2026-10-31, issue #29;
    `AgentForcePushRules`, GitHandler) goes, in every mode — Strict,
    Relaxed and Full alike, since Full lifts root commands, not this —,
    only by spending one approval the app gave this session whose own
    `approvalRequested` names exactly it (`detail.forcePush` {projectID,
    remote, url?, branch, expectedCommit, localCommit, localSubject,
    overwritten, overwrittenCount}): the request's remote, branch, url and
    lease must be the card's, the branch and the local commit named, so
    what reaches apelin-environment is the lease the user saw; never for
    the session. A push without a lease asks the host nothing.
    An agent's squash (owner, 2026-10-31; `AgentSquashRules`) under Confirm
    spends one approval naming exactly it (`detail.squash` {projectID,
    branch, base, expectedHead, message, commits, count, upstream?,
    published}), the request's base, expected head and message the card's;
    never for the session. Relaxed and Full squash as they commit, and a
    preview passes in every mode.
    `environmentAttach` reads only the tasks the session started
    (`startedTasks`, recorded by `startTask`).
    A reset to a remote (owner, 2026-10-31, issue #32;
    `Session/Agent/AgentResetToRemoteRules.swift`) discards local work, so
    an agent's `gitResetToRemote` spends, in every mode, Full included, one
    approval the app gave this session whose own `approvalRequested` names
    exactly it (`detail.resetToRemote` {projectID, remote, url, branch,
    remoteCommit, head?}, with what is lost beside it for the card), never
    for the session; the request must carry that commit, HEAD and address,
    which apelin-environment holds the project to again.
  - *Files* (`Session/Files/`). `fileRead` scopes: a project ID or
    `project:<name>`, `sdk:<id>`, `extension:<id>`, `agent-tools:<id>`,
    `grant:<id>` (app only); canonical paths, checked again on the opened
    descriptor (`F_GETPATH`). The protected edit is `protectedEditOpen{path}`
    → a 15-minute single-use grant bound to the file's identity and SHA-256,
    then `protectedEditCommit{grantID, contents | contentsBase64,
    expectedVersion, confirmed}`: existing regular files inside the install
    root only; no symlink, hard link, execute bit, Mach-O, package-manager
    or Apelin record; a LaunchDaemons plist needs `confirmed`; the old
    contents are backed up to `~/Documents/wiki.qaq.apelin/backups/` (every
    level opened `O_NOFOLLOW`, the file handed to mobile, the newest ten
    per file) and replaced through `AtomicReplace` (Fila's AtomicSave:
    temporary beside it, owner, group, mode, ACLs, xattrs and creation time
    kept, fsync, rename, identity checked again right before).
  - *Terminals* (`Session/Terminal/`, after iGhostVT's PTYSession).
    `forkpty`; the child hands the tty to mobile, sets groups, gid and uid,
    proves it cannot regain root, enters the project or home, closes every
    descriptor above 2 and execs the bootstrap's shell with a login
    environment — which also sets `safe.bareRepository=explicit` through
    `GIT_CONFIG_COUNT=1` and `GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0`,
    protected config a repository cannot turn off, so the user's git takes no bare
    layout it finds by walking up and runs none of its pagers or hooks —, and
    the development environment of the terminal's project (none: the
    defaults), the one shell_run gets (Agent sessions ▸ `agentRunCode`). A login
    shell's `/etc/profile` sets `PATH` anew, so the package ships
    `etc/profile.d/wiki.qaq.apelin.sh` (`Packaging/profile.d/`), which puts
    `APELIN_TOOLCHAIN_BIN` back in front when it is set and does nothing
    anywhere else;
    the host then reads the shell's credentials from the kernel
    and kills it unless all six ids are mobile's. Output is numbered into the
    `terminal` task (`started`, `output` {base64, text}, `exit`), so a
    reattach replays it; `ptyAttach{wantsDescriptor}` hands the app a socket
    to the live terminal. `ptyOpen{initialInput}` types once, for the console.
  - *Agent tools* (`Session/ToolHost/`): `toolHostOpen{id}` validates the
    manifest under `usr/share/apelin/agent-tools/<id>/` and starts the
    extension through `ToolHostClient` as mobile (`runAs`, checked in the
    kernel after spawn); `toolHostCall{sessionID, tool, arguments,
    attachments}` calls a tool the manifest declares; a session is its
    opener's, and an agent's close with it. Files go both ways as
    descriptors beside the envelope (`DescriptorSlot`), never paths: the
    host copies each into an unlinked file in `var/lib/apelin/attachments`
    (≤ 8 per call, ≤ 32 MB each) and passes a read-only descriptor, to the
    extension over its SCM_RIGHTS socket and back to the caller in the
    reply, with `byteCount` and `sha256` (`AttachmentCopies`). The
    extension inherits the host's working directory, never the project's.
    An agent session's caller is apelin-agent (2026-10-29; Agent
    sessions ▸ Agent tool extensions): its gate decides whether a call
    runs, and the host, holding the call to the manifest (the tool, its
    arguments to the schema), decides nothing again, since the extension
    runs as mobile as the worker does.
  - *Notifications* (`Session/Notice/`, after Xrash's). The host posts as
    the app (`NoticePoster`: `UNUserNotificationCenter` through the private
    `initWithBundleIdentifier:`, looked up at run time) when an agent
    session relays `approvalRequested` (title the conversation, subtitle
    "Approval Required", body the call's `reason` from its `toolCall`, else
    the gate's) or `finished` with `completed` (body the turn's last
    `message` with text, its first paragraph as plain text in at most 180
    characters, else "Done") or `failed` (subtitle "Failed", body the last
    `error`), and for the agent's own `notice` {title?, body} (2026-10-24:
    its `apelin_notification_send` tool, for something the reader would want to know
    while away — a long build, install or setup that ended, something to
    do on the device —; subtitle its title, body its body, each one plain
    line, cut to 40 and 180 characters; at most three between two of the
    session's prompts or turn ends, an empty one none; no operation
    carries it, the event is data the host reads by these rules,
    `AgentNoticeRules` in ApelinProtocol). Never for `aborted`, nor for a
    session opened with `closeWhenFinished`. The title is the session's
    latest `title`, else its first message's opening, else "New Chat"; keys
    are `localizedUserNotificationString` keys the app also spells.
    `AgentNoticeTrack` (tested in `Tests/SessionHost/`) decides; a reopened
    session relays its whole log again, so turns, approvals and notices are
    counted per session and their counts kept in `notices.json` (a count it
    lacks is none), and one already counted posts nothing. Identifiers are
    `<session>.turn.<n>`, `<session>.approval.<n>` and
    `<session>.notice.<n>`, the thread is the session, and `userInfo`
    `link` is `apelin://conversation/<session>`, which a tap hands to
    `UIApplication.open` (`ConversationNotices`). Banners are for a reader
    elsewhere: `willPresent` shows nothing while the app is active, opening
    a conversation (or coming back to it) removes its delivered ones, so
    does deleting it or its project (a banner left behind would open
    nothing), and the app asks for authorization when the reader first
    sends a message.
    Two declarations, or authorization stays false with no error but the
    device log's: `com.apple.private.usernotifications.bundle-identifiers`
    naming `wiki.qaq.apelin` on apelind and on the app, and
    `SBAppUsesLocalNotifications` in the app's Info.plist; the packager
    requires all three. A tap in Notification Center or on the Lock Screen
    that only slides the row aside to show Open is SpringBoard's rule for
    every app, not a fault in the request: on an iPhone with no Face ID or
    Touch ID unlock and `SBAlwaysAllowDefaultAction` unset (CoverSheet's
    `shouldHintForDefault`, logged `notCape - doesn'tForceDefault`), it
    hints instead of running the default action, and Open or a swipe runs
    it. A banner tap is never hinted, nor any tap on an iPad. Every iPhone
    vphone hints; to test one tap, write `SBAlwaysAllowDefaultAction`
    (bool, true) to `com.apple.springboard` (`allowsDefault`, live, no
    respring) and delete it afterwards.
  - Every spawn to mobile (workers, shells, extensions) is checked after
    the fact with `proc_pidinfo`: effective, real and saved uid and gid all
    501, or the process is killed (`verifyDropped`, `Spawn.swift`).
  `Scripts/test-session-host.sh`, in `make harness`, runs the macOS half
  (`Tests/SessionHost/`): record persistence and resume (a build restarted
  over a real channel, the refusals, the cancel, the retry bound), CallerPolicy, the
  edit rules on a temporary root, the managed-package rules, the bridge
  against a fake irisind, the folders a removed toolchain leaves, the
  ledger, the control reader, the attachment
  copies, ordinary events leaving the record alone and its number and time
  read back from the log, one `agentOpen` of a session at a time, Ask
  Before Using the Screen's refusals and spends in every mode
  (`ScreenConsentChecks.swift`), a reset to a remote only on the approval
  of exactly it, in every mode (`ResetToRemoteChecks.swift`), and a real
  PTY.
  `Documents/Console/scripts/i1-smoke.json` drives it on a device;
  `r1-resume-build.json`, `r1-resume-sdk-import.json` and
  `r2-resume-toolchain.json` check a resume, killing the host by its
  `session.pid` (steps in `Documents/Console.md`).
- **The environment worker** (`Packages/ApelinKit/Sources/ApelinEnvironment`,
  `EnvironmentWorker`; layout in `EnvironmentLayout`). A task-starting
  operation is checked before it is accepted — a bad request is the reply,
  not a failed task — then runs in `Environment/staging/<taskID>/` and ends
  with `state`.
  *SDKs*: imported from an HTTPS archive, a descriptor, a folder or archive
  in `~/Documents/wiki.qaq.apelin/inbox/`, or one branch of a
  one-SDK-per-branch repository (shallow clone, HTTPS only); archives are
  unpacked entry by entry through libarchive (no `..`, absolute or repeated
  names, no directory through a link, no special files, bounded); identity
  only from `SDKSettings.json`, `Foundation.tbd` and the Swift interfaces;
  every link must resolve inside; Mach-O judged by header type through
  ApelinMachO — `MH_DYLIB`, `MH_DYLIB_STUB`, `MH_OBJECT` pass, `MH_EXECUTE`
  in any slice or static-archive member, `MH_BUNDLE` and the rest are
  refused; each file's check and digest run on up to four cores, and the
  digest and a refusal are the ones walk order gives. Registered as
  `SDKs/<CanonicalName>-<sha8>/` by one rename, then
  `SDKs/.registry/<id>.json` (the commit point); a tree without a record is
  swept at worker start. Removal refuses an SDK a project binds. Sources live
  in `Environment/sdk-sources.json`; without that file the default source is
  `owngoal-dev/iOS-SDKs`, enabled by the owner on 2026-10-19. It credits
  `xybp888/iOS-SDKs` and keeps one SDK per branch, starting at 14.5. The
  13.0–14.4 trees lack C++ standard library headers and are excluded.
  All 23 branches it keeps (14.5 to 27.1) are offered, with no filter: on
  an iPhone 15 Pro running iOS 17.3.1 each was imported again and built,
  with CLT 27.0, a C++, an Objective-C CLI and the tweak template's dylib
  that ran and loaded there, and 14.5–17.0 also Swift with CLT 15.0
  (2026-10-21, `Documents/Research/Device-Validation.md` ▸ Real devices). An
  explicit list, including an empty one, replaces the default. SDKs stay
  Apple's under Apple's terms.
  *Git*: libgit2 in `ApelinGit`, no libgit2 type public. A project is named
  by its `projectID` or, before it has a description, its folder name, and
  resolved to exactly one component below the realpath of `Projects/`;
  every path is plain, literal (never a pathspec glob) and resolves inside.
  A commit's author is the request's, else `Settings/git.json`, else the
  repository's config; `gitCommit{all: true}` stages every change first,
  as `git add --all` does (ignored files left out). Every project Apelin
  makes starts as a repository on `main` with no commit (owner,
  2026-10-25): apelin-build, which has no libgit2, writes what
  `git init -b main` leaves into the staging folder (`EmptyRepository`
  in ApelinProject), so project and repository arrive together; `gitInit`
  makes one on `main` for a project that has none (`conflict` when it has
  a `.git`; any other call on one without is `notFound`, reason
  `notARepository`). Both write `.git/info/exclude`, never `.gitignore`,
  with what Apelin writes into a project that is not the project's
  (`ProjectExcludes.apelinFiles`: the agent's `Attachments/`, the metadata
  writer's and the file tools' temporary files); a repository made
  without it is given it by its next git call once the project has an
  `Attachments` folder. SSH would exec `ssh`; HTTPS is the only transport.
  Remotes (2026-10-22): `gitFetch`, `gitPull` (fetch, then a fast-forward
  only: a diverged branch or a worktree change it would overwrite is
  `conflict` and nothing changes) and `gitPush` (one branch to the branch
  of the same name, recorded as its upstream, never forced without a
  lease; with `url`, a
  remote it names that the repository lacks is added first, HTTPS as a
  clone's, and taken away again when the push is refused before it
  starts; one it has must have that URL, else `conflict`, reason
  `remoteURLDiffers`; a missing one without `url` is `notFound`, reason
  `noSuchRemote`) are tasks that are not resumed; `gitFetch {branch}`
  also answers that local branch beside the branch of that name the
  remote advertised to the fetch (`comparison`, `GitBranchComparison`:
  both commits, the push URL, the remote's commits the local branch
  lacks, newest first, the first ten with their subjects and all of them
  counted), and the push result names `from`, the commit the remote's
  branch was at. A forced push (owner, 2026-10-31, issue #29;
  `Operations/GitHistory.swift`) is `gitPush {forceWithLease:
  {expectedCommit, localCommit?}}`, full commit IDs checked before the
  task is accepted, a local branch that is not at `localCommit` refused
  there too (`conflict`, reason `localChanged`): libgit2 pushes
  `+refs/heads/<branch>` on one connection, and its `push_negotiation`
  callback, which gets the commit the remote advertised on that very
  connection as each update's old value, stops it before anything is sent
  unless that is `expectedCommit` (`conflict`, reason `remoteChanged`, a
  branch the remote lacks too: nothing to overwrite, an ordinary push
  makes it). The update goes to the remote as `<expectedCommit> <local>
  <ref>`, so git's receive-pack or GitHub refuse it as well when the
  branch moved after the check, in their own words (`rejected`); libgit2's
  local transport writes the branch without that check, so
  `GitLeaseTests` proves it through `git daemon`. A `lease` event
  {branch, expectedCommit, localCommit?, found?, held} records what the
  remote said, and the result `forced`. A squash (owner, 2026-10-31;
  `GitSquashRequest`, `ApelinGit/GitSquash.swift`) is `gitSquash {base,
  message, expectedHead}`, one request, not a task: the commits after
  `base` on the checked-out branch become one commit on `base` with HEAD's
  tree, the message and the author `gitCommit` would take; the branch
  moves from `expectedHead` alone (`git_reference_create_matching`), the
  work tree, the index and every remote are left as they are, nothing is
  pushed, and the branch's reflog keeps `previousHead`. Refused with
  nothing changed: HEAD not at `expectedHead` (`conflict`, reason
  `headChanged`), a base that is no ancestor of HEAD, fewer than two
  commits after it, a tracked change in the work tree or the index
  (`conflict`; untracked files are left alone), HEAD not on a branch.
  `preview: true` changes nothing and answers what it would combine — by
  `base` (seven digits or more) or `count` back along first parents —:
  the commits, newest first, the first fifty, and how many of them the
  branch's upstream has as last fetched (`published`), when publishing it
  would take a forced push; `gitCloneInto` imports a
  repository into an existing workspace project — the repository
  initialised in the folder, `origin`
  fetched in full, the branch checked out without overwriting a file
  already there (a clash fails and leaves the folder as it was), Apelin's
  own files kept out through `.git/info/exclude`. The untouched repository
  a new workspace starts with (`GitRepository.isUntouched`: HEAD unborn, no
  reference, remote or staged entry) is replaced, and put back on its
  branch when the import fails; any other `.git` is `conflict`.
  A project's own remotes (owner, 2026-10-31, issue #32;
  `GitService+Remotes.swift`): `gitRemoteList` names each remote and its
  address, never a user, token, query or fragment in it
  (`GitRemoteURL.shown`, `hidesCredential` when one was left out);
  `gitRemoteSet {name, url}` adds one, or points one at another address
  for fetch and push alike (its own `pushurl` taken away), fetching
  nothing; `gitRemoteRemove` takes one away with its tracking branches
  and any upstream record of it (`notFound`, reason `noSuchRemote`, when
  there is none). A name is `GitRemoteName`'s (letters, digits, `.`, `_`
  and `-`, at most 64, a letter or digit first, no `..`: never a path, an
  option or an address), an address `GitRemoteURL`'s (HTTPS with a host,
  no user, password, query, fragment or white space). A fetch, pull or
  push given an address where a remote's name goes is `badRequest`
  saying to add a remote at it first, never `noSuchRemote`.
  "Remote wins" (owner, 2026-10-31, issue #32; `GitService+Reset.swift`,
  ApelinGit's `GitReset.swift`): `gitResetPreview {projectID, remote,
  branch?}` fetches that branch alone (nil: the one the remote's HEAD
  names) into its remote-tracking branch, whatever refspecs the remote
  has, and answers what a reset would do (`GitResetPreview`: the remote's
  commit, HEAD, whether the histories are unrelated, the commits that
  leave the branch, the tracked files whose uncommitted changes go, the
  untracked or ignored files the remote's tree replaces, each list's count
  and its first 50, and what `apelin-project.json` becomes);
  `gitResetToRemote {projectID, remote, branch, expectedRemoteCommit,
  expectedHead, expectedURL?}` fetches again and, only while the remote is
  at that commit and address and HEAD at that commit (nil: none), else
  `conflict` with nothing changed, does what `git checkout -f -B <branch>
  <remote>/<branch>` does: the local branch of that name moved there and
  checked out, the index and tracked files the remote's, untracked and
  ignored files it lacks left alone, upstream recorded; it works as well
  on a history unrelated to the remote's. First it saves what it would
  lose on a new branch `apelin-backup/<yyyyMMdd-HHmmss>` (a number after
  it when taken), named in its result: HEAD's commit, with a commit on top
  holding the tracked files as they are and the files it replaces when
  anything is uncommitted or replaced. A local branch of that name that is
  not checked out and has commits the remote lacks is `conflict`. The
  project keeps its identity: the remote's `apelin-project.json` with this
  project's `projectID` in its one quoted place (`RepositoryManifest`,
  refused when it does not read), or this project's own, kept out through
  `.git/info/exclude`, when the remote has none; the icon likewise. Both
  are tasks that are not resumed.
  A repository's own `apelin-project.json` coming into a new workspace
  (owner, 2026-10-31, issue #32; `RepositoryManifest`): while the
  workspace's manifest holds nothing but its identity
  (`ProjectManifestIdentity.isBareWorkspace`, what `createEmpty` writes),
  the repository's file takes its place instead of clashing
  (`GitClone.Replacement`: settled before anything is checked out, the
  workspace's set aside and put back when the import fails), and the
  display name follows it. It keeps its `projectID` when that is a
  lowercase UUID no other project, conversation (`sessions/*/session.json`),
  build (`Builds/<id>/`) or memory record names, and nothing names the
  workspace's ID yet (`ProjectReferences`); otherwise the workspace's ID
  goes in its one quoted place (`ProjectManifestIdentity.replacing`, the
  transfer import's rule) and the file shows as changed in git. A
  conversation names its workspace from the moment it opens (its session
  reopens only on the ID it was made with), so the agent's git_clone
  always keeps the workspace's ID; an import the app runs before any
  conversation can take the repository's. The result says which
  (`projectFile`, `GitProjectFile`) and the ID the project has
  (`projectID`). A file that is not a JSON object with a `projectID`, or
  one whose ID appears twice where it must be replaced, is `badRequest`,
  the workspace left as it was; a file only in a subfolder is any file;
  a workspace whose manifest holds more (a declared build) clashes as
  before. Nothing in it runs and nothing is recorded as approved: the
  host's ledger holds no digest for an imported description, so a Strict
  build of it asks. Credentials are one per
  host (lowercased, with `:port` when named): a username and a token
  (`GitCredentialStore`, keychain service and access group
  `wiki.qaq.apelin.git`, `keychain-access-groups` on apelin-environment
  only, after first unlock, this device only, never synchronised), offered
  through libgit2's credential callback only to an HTTPS remote whose host
  is exactly that one, once per operation; an authentication failure is
  `denied` with reason `authenticationRequired`. `gitSettings`,
  `gitAuthorSet`, `gitCredentialSet` and `gitCredentialRemove` are the
  app's and the agent's (Settings ▸ Git, `Apelin/Interface/Settings/Git/`): the list names
  hosts and usernames, never a token, and the console refuses
  `gitCredentialSet` before sending it. github.com is signed in to with a
  code, the device flow `gh auth login` runs (owner, 2026-10-25;
  `GitHubDeviceFlow`, after cli/cli `internal/authflow` and cli/oauth
  `device`, tested in `Tests/GitHubDeviceFlow`): in the app, which has the
  network, with GitHub CLI's OAuth app (`178c6fc778ccc68e1d6a`, public in
  gh's source, no secret needed; GitHub's page asks to authorize GitHub
  CLI, which the page says first) and scopes `repo` and `workflow`; each
  poll waits a fifth longer than GitHub's interval, a `slow_down` takes its
  new one with two fifths; the token is gh's non-expiring kind, saved with
  the account's login (`GET /user`) through `gitCredentialSet`, never kept
  by the app. There is no token form any more: Settings ▸ Git ▸ GitHub
  signs in and out, another host's credential is one an agent saved
  (apelin_git_save_credential, which refuses github.com), listed under
  Other Hosts for removal. Sign In with GitHub is also a welcome page, after
  Model Providers (`WelcomeGitHubPage`), with the package repository's
  Create and Link under it. An agent's git call is checked by
  `GitHandler` to name its own session's project before it is forwarded.
  A repository on GitHub (owner, 2026-10-29; `GitHubRepositoryService` in
  `ApelinEnvironment/Git/`): `gitRepositoryCreate {name, visibility,
  owner?, description?}` makes an empty one — `auto_init` off, so no
  README, licence or `.gitignore`, and GitHub's defaults for the rest —
  with the github.com sign-in, on the account or in the organization
  `owner` names (the account's own login, however spelt, is the account:
  `GET /user` tells them apart); `visibility` is `public` or `private` and
  has no default. One request, not a task, answering `fullName`,
  `cloneURL` and `url`. The request is checked before the sign-in is read
  (`GitRepositoryCreateRequest.problem`: `GitHubName`'s name and login
  shapes, which the package repository's create reads too, and a
  one-line description of at most 350 characters); without a sign-in,
  `denied` with reason `authenticationRequired`. GitHub's refusals keep
  its words: a name the owner has is `conflict`, an organization the
  account may not create in `denied`, one it cannot see `notFound` naming
  it. `GitHandler` checks no project for it, as for the settings; an
  agent's passes `AgentRepositoryCreateRules` first. Tested by
  `GitHubRepositoryTests` (a fake GitHub); `i2-git-remote.json` sends a
  name GitHub would refuse, answered before anything reaches GitHub.
  An issue on a repository the user chose (owner, 2026-10-30;
  `GitHubIssueService` beside it): `gitIssueCreate {repository, title,
  body}` opens one on `owner/name` (`GitHubName.isFullName`) with the same
  sign-in, `POST /repos/<owner>/<name>/issues`, answering `{number, url,
  repository}`. The title and body pass `FeedbackRules.problem` with this
  device's paths and host name (`IssueReport`, which feedback's checks and
  footer are too) before the sign-in is read, `badRequest` naming the
  kind, and below the body goes feedback's footer. GitHub's refusals keep
  its words and say what blocks it (`GitHubAPI.createIssue`): a repository
  the account cannot see `notFound`, issues turned off there (410) or no
  permission (403) `denied`, GitHub's validation (422) `conflict`; without
  a sign-in, `denied` with reason `authenticationRequired`. Only the
  repository named is asked, never Apelin's in its place. Unscoped in
  `GitHandler`; an agent's passes `AgentIssueCreateRules` first. Tested by
  `GitHubIssueTests`; `i2-git-remote.json` names a repository with no
  owner, refused before GitHub.
  An empty workspace's manifest says `"buildSystem": "external"` (one
  without the key is read the same way): Apelin has no build description
  for it, so the agent builds with the project's own tools through
  `shell_run` and writes down how in the project's `AGENTS.md`; a package
  it installs comes from the workspace's own build script (Workspace
  builds, below). New Project
  takes an optional repository address for the empty workspace and sends
  it to the project's first conversation, where the agent's `git_clone`
  imports it; the app does nothing more.
  *Toolchains*: `ToolchainBackend`, implemented by `Packages/ApelinToolchain`
  through `RetargetToolchainBackend`, compiled only when that package is
  linked (`#if canImport`); without it setup answers `unavailable`. Setup
  keeps `Toolchains/jobs/<key>/job.json` (§3.4 stage, the task, a failure,
  and the installation ID of an install not yet registered or rolled back)
  per source and components and resumes from it; one setup per key runs at
  a time. The retargeted tree becomes `Environment/Artifacts/toolchain-<id>.deb`
  (`wiki.qaq.apelin.toolchain.<id>`, the bootstrap's architecture and
  layout, no Depends, no maintainer scripts, `control.tar.gz`; every entry
  root's, folders and executables 0755, other files 0644, links relative and
  inside the tree), handed to the host's `installPackage` as artifact
  `toolchain-<id>` with its SHA-256 and followed to the task's final `state`,
  never to apt or dpkg; the deb is deleted once the host has its copy. An
  install is reused only when the bridge has a record of it (job.json, or
  the registered toolchain of that ID): matching bytes without one go
  through the bridge again, so removal always has an installation to act
  on. `matchesToolchainDigest` also recognises RootHide's runtime branding:
  after validating its mark and page hash, it restores only that padding,
  CS_ADHOC and the first-page hash in memory, then requires the original
  whole-file SHA-256. Code, dependencies and entitlements remain covered;
  neither the installed tool nor its manifest is rewritten. The install is
  never abandoned: a cancel waits for irisind's answer.
  job.json holds the host's install task from `installPackage`'s answer to
  its end, so a setup resumed past it — re-run, or re-sent by the host under
  the same task ID — follows that task (`buildAttach`) instead of handing
  the package over twice; a task that ended without installing, or is gone,
  is submitted afresh.
  Setup takes the CLT releases `CommandLineToolsSupport.releases` lists —
  27.0, 16.4, 15.3, 15.0 and 14.2 (owner, 2026-10-21; each set up and
  self-tested on a device) — and refuses any other, before downloading,
  with the catalog's `unsupportedReason`: 12.4 for its arm64e C++, and
  16.2, 14.3, 13.4, 13.2 and 12.5, which passed but were dropped, as
  releases Apelin no longer sets up. `toolchainCatalog` lists only the kept
  releases (a product Apple lists that Apelin has not reviewed is left
  out, `ToolchainProduct.reviewed`); a kept one this device cannot run
  stays, with its reason.
  Each release reads SDKs up to its Xcode's (`newestSDK`, major.minor),
  which the record keeps: the self-test compiles against the newest
  registered SDK the release reads. When none fits, the same setup task
  imports the newest compatible SDK from an enabled source first (`sdk`
  stage, import progress relayed with `phase`); with Swift it must also
  match the release's SDK major. Its actual identity is checked again after
  import. A resumed setup reuses the registered SDK, and cancelling cleans
  unfinished SDK staging. `projectCreate` binds a compatible SDK, and
  `projectCheck` fails a newer one (`environment.sdk.tooNewForToolchain`).
  Several toolchains live side by side, each under its own ID and package.
  Swift (`components: ["c", "swift"]`) is reviewed for CLT 14.2 (Swift 5.7.2,
  iOS 17.3.1+, LRCPC), 15.0 (Swift 5.9) and 15.3 (Swift 5.10), both iOS
  17.3.1+ and LRCPC — swift-frontend's two SHA3 sites, BLAKE3 hash_many and
  the symbol-graph edge set, are off Apelin's build path, and an A12Z ran
  every Swift case of both —, and 27.0 (Swift 6.4, iOS 26+,
  LRCPC/SHA3/DotProd). 16.4 ships Swift 6.1.2 and does not offer it
  (`swiftUnavailable`): its swift-driver imports macOS's zippered
  availability check, which no iOS runtime exports (dyld stops it on iOS
  17.3.1 and iPadOS 26.0.1), the 27.0 rename is right only from iOS 26,
  and its swift-frontend needs DotProd and SHA3 (XXH3), so it could only
  serve where 27.0's Swift already does. Each self-tests against
  an SDK of its own major: Swift, Swift dylib, Swift async and, from
  Swift 5.9, Swift macro for
  each architecture the SDK has Swift interfaces for (arm64e only in the
  iOS 27 SDK). apelin-build hands Swift 5.9+ `swiftc` `-nonlib-dependency-scanner` (the
  tree has no libSwiftScan) and one module cache per toolchain and SDK,
  `Builds/.swift-module-cache/<toolchain>-<sdk>`. The retarget scheme (2)
  is part of the ID; scheme 2 keeps `libclang_rt.ios.a`, which `@available`
  links against. Per-release Swift requirements and clang-module CPU
  requirements are carried in the manifest, catalog and registered record.
  The release table in `ApelinToolchain/Support.swift` also records the
  reviewed Apple product IDs and package SHA-256 values, recommended SDK and
  actual verified SDKs. Changed source bytes are refused before extraction.
  The package comes down as 8 MB ranges, four in flight, each checked as
  before and checkpointed in order; its pbzx payload is decoded four
  chunks at a time and handed out in order, and file digests (packaging,
  the installed-tree check) run on up to four cores — about half the
  download and extract time on an iPhone 15 Pro and an A12Z.
  An unknown product ID is not accepted just because its version matches.
  `ReleaseCompatibility` turns that table into the `compatibility` snapshot
  returned in `toolchainCatalog`, stored in the toolchain manifest and
  `ToolchainRecord`, and read by the build worker. Older records still decode.
  CLT 16.4 and 27.0 also record their required C++ runtime symbol,
  `std::__1::__libcpp_verbose_abort`. Catalog, setup and project checks look
  for the symbol in the fixed system C++ library before any tool is run,
  rather than guessing an OS floor from SDK versions.
  SDK imports do not consult it: a valid SDK may be stored without a compatible
  toolchain. Setup prefers the recommended SDK when available, then falls back
  to the newest compatible one. Legacy Swift's 17.3.1 bound is explicitly a
  verified-host policy, not an instruction-set requirement; CLT 27.0's 26.0
  bound follows the semantics of its retargeted OS-version query. CPU features
  are evaluated independently. `cpuProfiles` covers A9/A9X and A10/A10X iPads,
  A11 iPhones, A12/A12X/A12Z, A13 and later, and M-series iPads, for explanation
  only; the kernel's feature flags remain the decision source. Static inventory
  and full decoder comparisons run without executing the inspected compilers
  (`StaticInventoryTests`, `Scripts/inspect-toolchain-imports.py`). Instructions
  in guarded paths are recorded separately from per-capability requirements.
  Only temporary Swift self-test executables carry `get-task-allow`, so
  iOS permits their private test dylibs in writable app data; compiler
  binaries and their libraries do not gain it. The download picker shows a
  release's requirements, from the same catalog fields, when its row is
  picked, before anything downloads.
  The self-test runs as mobile on the installed tree, the install root and
  the SDK by their `realpath`; only a toolchain whose installed bytes
  passed the C self-test is written to `Toolchains/registry.json`, with the
  bridge's installation ID and its physical path. A failed or cancelled
  setup removes what it installed through `removePackage` (or hands it to
  the registered toolchain of the same ID); a cancel also deletes its job.
  `toolchainRemove` goes through `removePackage` for the record's
  installation; when the bridge refuses because the package is gone and the
  tree is gone too, only the record is dropped; a tree with no regular file
  left is gone (roothide's package removal leaves every folder with its
  `.jbroot` link, which the session host then removes).
  `toolchainSelfTest` (Self-Tests ▸ Run Again) runs the installed tree's
  self-test again as mobile against the SDK setup used — removed since,
  the one setup would pick — and the registry keeps the
  new results, passed or not; a failure is a warning, never an
  unregistration; it is not resumed. Proven on the Mac by
  `ToolchainTests` and the session host's end-to-end test
  (`Tests/SessionHost/ToolchainEndToEnd.swift`: `apelin-environment-harness`,
  the real worker with a fake backend, against the install bridge and a fake
  irisind); on a device by `Documents/Console/scripts/t1-toolchain-setup.json`,
  `t2-toolchain-remove.json` and `t3-toolchain-side-by-side.json`.
- **Transfer files** (2026-10-21; `Operations/Transfer.swift`,
  `ApelinEnvironment/Transfer/`, `Apelind/Dispatch/TransferHandler.swift`,
  `Apelin/Interface/Transfer/`). A registered toolchain (`.apetc`), a
  registered SDK (`.apesdk`) or a project (`.apeproj`) goes from one device
  to another as one file, user to own device: nothing is uploaded, and the
  export's confirmation says so in a line. The app declares the exported
  types `wiki.qaq.apelin.toolchain-package`, `…sdk-package` and
  `…project-package` (conforming to `public.data` and `public.archive`, by
  extension) and owns them in `CFBundleDocumentTypes`, in the partial
  `Apelin/Resources/Info.plist` merged with the generated one (kept out of
  the target's resources by the synced folder's exception set), with
  `LSSupportsOpeningDocumentsInPlace`; no document icon, the system draws
  one from the app's. *The format*: a pax tar through zstd whose first
  member is `manifest.json` (`TransferManifest`: `formatVersion` 1, `kind`,
  `id`, `name`, `createdBy`, `created`, every payload member with its kind,
  size, SHA-256, execute bit or link target, and the kind's facts), every
  other member `payload/<path>`. A toolchain's payload is its retargeted
  tree as setup packaged it (its own `manifest.json` at the top), never a
  deb: export copies the installed tree back to those bytes
  (`ToolchainTransfer.exportCopy` in Packages/ApelinToolchain: every file
  checked against the toolchain manifest's digest, RootHide's runtime brand
  undone, folders and links as they are), and the importing device packages
  it for its own bootstrap with `ToolchainPackager`, so what irisind gets is
  always built on that device from checked bytes, never a deb's data member
  from elsewhere, and a toolchain moves between rootless and roothide (the
  file records the bootstrap and architecture it came from; the inspection
  says it is packaged again). Its facts are the record without its path or
  installation, the retarget scheme, the product, Apple's package digest
  and the minimum OS. An SDK's payload is its registered tree, with its
  record (no path); a project's is its folder: every tracked file and every
  untracked one its ignore rules do not name (an uncommitted new file is
  work, not junk). libgit2 applies nested `.gitignore` rules, negations and
  `.git/info/exclude` one path at a time; tracked files and their parent
  folders survive later ignore rules. Without a repository, an empty
  temporary repository in task staging reads the same `.gitignore` rules
  without changing the project. `apelin-project.json` always travels so
  the result remains importable. It carries `.git` without `hooks/`, `config`, `modules/`,
  `worktrees/`, `commondir` or locks; no `.DS_Store`, no repository nested
  inside, nothing from `Builds/`; with its identity (project ID, template,
  description digests for information only, the toolchain and SDK it binds,
  an HTTPS origin). *Export* (`transferExport{kind, id, createdBy}`, a task:
  `collecting` (items scanned), `hashing`, `packing`, `verifying` (each with
  its own measured byte total)) writes `Exports/<kind>-<id>/<name>.<ext>` in the
  data folder, replacing the item's earlier export, through a `.partial`
  swept at worker start. File hashing and writing check cancellation in
  1 MiB chunks; final archive hashing happens before the rename, inside the
  same failure/cancellation cleanup. Its `result` {export: TransferExport} is in the
  final `state` too. The app shares it with the share sheet anchored to the
  `…` item and deletes the folder once a share completes. *Inspect*
  (`transferInspect{source, fileName}`) reads the manifest alone and answers
  the summary, the file's size, `problems` (which make it not importable),
  `notes`, `existingID`, a project's `suggestedName`. *Import*
  (`transferImport{source, fileName, kind?, projectName?}`, a task) checks
  the same before it is accepted, then reads the whole file into its
  staging (`TransferArchiveReader`: the first member must be the manifest,
  ≤ 64 MB; every member listed once, of its kind, no NUL, absolute name,
  `..` or depth past 64, names folded for APFS; folders made and checked
  with `lstat`, files `O_EXCL | O_NOFOLLOW`, 0755 or 0644; each size and
  SHA-256 the manifest's; links relative and staying inside; no hard link
  or special file; nothing missing; ≤ 32 GB and 1,000,000 members) and only
  then runs the kind's path. A toolchain: `importTree` verifies its own
  manifest (identity, the ID setup derives from source, scheme, minimum OS
  and components, a release `CommandLineToolsSupport` still lists from a
  source it reviewed, host and Swift requirements, exactly the files and
  links it lists, each matching), the record's `contentDigest` must match,
  a registered one of that ID is refused (`conflict`); then setup's path —
  the self-test's SDK (fetched from an enabled source when none fits),
  `ToolchainPackager`, the bridge, the self-test on this device, the
  registry only if it passed, removal through the bridge otherwise — under
  the job record `Toolchains/jobs/import-<id>/`. An SDK: its tree must have
  `SDKSettings.json` at the top, is inspected by `SDKInspector` like any
  import, must be the ID and digest the file names, a registered one is
  refused, and it is registered with origin `transfer <file>`. A project:
  no `.git` anywhere but the top (compared without case); a new project ID
  written into `apelin-project.json` by replacing its one quoted
  occurrence, nothing else changed (so the Confirm ledger has nothing
  approved under it and two folders never share an ID), the file then in
  its written form (`ProjectManifestFormat`); `.git` given a
  fresh minimal `config` (the HTTPS origin kept) and dropped with a warning
  if it does not open; moved into `Projects/<name>/` by
  `renamex_np(RENAME_EXCL)` — `projectName` taken is `conflict`, absent the
  first free `<name> <n>`. Nothing in it runs and nothing is recorded as
  approved. A `source` is the app's descriptor (`file`, rewound before each
  read), or a file in `inbox/` or `Exports/` (an export's folder names its
  one file), canonicalised; a named file's extension must be its kind.
  The app's flows: Open in Apelin and launch URLs (`SceneDelegate`) and the
  pickers (Toolchains ▸ + ▸ From File…, SDKs ▸ + ▸ From Files… for an
  `.apesdk`) open the file read-only under its security scope and keep only
  the descriptor; `TransferImportController` shows what it is and what it
  needs, then follows the import on `EnvironmentTaskController` (whose `…`
  menu has Show Log, every event). Export… is in the Toolchain and SDK
  pages' `…` menu; project export has no page yet (the project list is a
  stand-in), so it is the operation and `TransferExporter`'s project case.
  Tested by `TransferTests` (round trips of each kind across two homes, a
  failed self-test removed, the other bootstrap, an unsupported release, a
  tampered member, members leading out, extra and missing members, a newer
  format, a nested repository, name collisions) and
  `ToolchainTransferTests`; on a device by `transfer` and
  `transfer-project` (regression) and `transfer-toolchain` (manual: a GB
  file).
- **The console** (format in `Documents/Console.md`) runs the app headless
  from a JSON script: `-apelin-console <path>`, or
  `~/Documents/wiki.qaq.apelin/console/inbox/*.json` at launch and on every
  foreground; results as JSON lines in `console/out/<runID>.jsonl` and the
  unified log (`wiki.qaq.apelin`, `console`). It calls `ApelinService`, the
  one typed surface — one async method per operation — that the UI and the
  agent's tools (over `ChannelTransport`) call too; `ApelinService.app`
  (`Apelin/Service/`) binds it to `DaemonClient`. The runner is the
  `ApelinConsole` library (ApelinCore and ApelinProtocol only), given an
  `ApelinService`, a `DataFolder` and a log sink; the app keeps the binding
  and the launch and foreground hooks (`Apelin/Console/`). A step answering
  a task handle, or an attach answering an unfinished batch, follows the
  task to its end (an attach by ID reads a task an earlier run started). A followed task
  is announced by a `step.task` line, so a launch after the app died
  mid-follow re-attaches to that task after the last event written and
  finishes the run; after a successful `respring` the run waits up to
  15 s for the app to go before the next step starts (a `step.note` if it
  survives), so a run that stops right after it goes on at the next step;
  anything else left running is
  `run.interrupted`. `make harness` tests it against a fake transport
  (`Packages/ApelinKit/Tests/ApelinConsoleTests`): every typed `ApelinService` method once,
  from a switch over `AppOperation` with no default, so an operation added
  without a method does not build; the runner; and every script in
  `Documents/Console/scripts/` — one per domain, which together must call
  every operation. A new operation gets its row there and a step in its
  domain's script. `Scripts/device.py` runs them on a vphone or device from
  the Mac (`Documents/Console.md` ▸ From the Mac): it drops a script, quits
  an idle app and launches it (never through another app: on an iPad that
  app keeps the focus), follows the output, opens the app again after a
  respring, and keeps the lines in `build/Device/<target>/`. What a script
  needs, sets up, does while it runs (a session host or app killed by a
  watcher on the device), checks and cleans up is its entry in
  `Documents/Console/device-harness.json`, beside the suites; every script
  has one, a script that cannot run unattended says why under `manual`, and
  every other one is in `regression` (`make check` runs `device.py lint`).
- **The replay** (`Packages/ApelinKit/Sources/ApelinReplay`, ApelinCore and
  ApelinProtocol only) is how the UI works where no apelind runs:
  `ReplayTransport` answers `ApelinService` from event streams the console
  captured on a device — the latest reply whose request matches, else the
  latest of that operation, else `unavailable`; a task's start, then its
  events by long-poll attach, paced as recorded or at once; an agent
  session held at each `waitingForApproval` until `agentApprove`; no
  descriptor, no state that changes. Its `Fixtures/` resource (`replies.json`,
  `tasks/<name>.json`) is written only by
  `Documents/Console/demo/make-replay-fixtures.py <capture>` from the demo
  scripts' output beside it: the bootstrap folder, hostnames, model and
  kernel build scrubbed, logs trimmed, seq renumbered without gaps, and
  nothing written if a key, a Mac path or a device identifier survives.
  `ApelinReplayTests` (`make harness`) reads every fixture strictly through
  the protocol types — a field a type does not know fails — with a shape
  table for the event payloads ApelinProtocol has no type for, checks seq
  from 1 to a final `state`, and replays tasks through `ApelinService`. A
  protocol change that breaks a fixture means a new capture, not a hand
  edit. It is linked into nothing; the app selects it by a launch argument
  (`Documents/Plan/Handoff.md` ▸ the replay), never by build flag, and it
  never links into apelind or a worker.
- **Agent sessions** (`Apelind/Dispatch/AgentHandler.swift`,
  `Packages/ApelinAgent/Sources/ApelinAgentWorker`). `agentOpen` comes
  from the app, or from an agent for its own project (Conversations,
  below): the host resolves the project by `projectID` or `projectName`
  (canonical `Projects/<name>`, its `apelin-project.json` id), makes the
  `agent` task, spawns `apelin-agent` with the session id as its instance and
  hands it the request with the project filled in — one open of a session
  at a time (`Session/Agent/AgentOpenTurns.swift`): an `agentOpen` of a
  session already being opened waits for that one to answer, in the order
  they came, then makes every check of its own and answers the live task
  it registered; another session's open never waits, a failed open frees
  the session for the next, and a waiter whose request is cancelled leaves
  the line and opens nothing (`cancelled`); provider (`githubCopilot`
  default, model default `claude-sonnet-5.5`), reasoning effort, service
  tier, approval mode, Ask Before Using the Screen (`asksBeforeScreen`,
  absent read as on, so an older caller cannot turn it off; an agent's
  open takes its opener's, an agent's message changes none), an optional
  first `prompt` and `closeWhenFinished` (the task ends with the first run,
  for headless runs) ride on it. So does `hostRestarted`, the host's alone
  (owner, 2026-10-29; `Session/Agent/AgentHostRun.swift`): what a caller
  sends is dropped, and the host sets it on the app's open of a
  conversation it names by `sessionID` that no message has reached in
  this host's run — an in-memory set, empty whenever the host starts,
  marked once the open's own prompt or an `agentPrompt` the worker took
  has reached the session, so Compact…'s open alone, or a worker that died
  before the user's message, leaves it due. The worker, when the
  transcript it read back is not empty, tells the model once, in the next
  message's `<system-state>` (below); a new conversation and one an agent
  opened are told nothing (`Tests/SessionHost/AgentHostRunChecks.swift`,
  `HostRestartNoteTests`). The tier last chosen is kwwk's
  `AgentState.serviceTier` (kwwk 0.1.100), which its loop sends with every
  turn. The agent wraps kwwk's own stream in `NetworkRecovery` (2026-10-29);
  native compaction stays on, since the session names it itself
  (`NativeCompactionFallback.configuration`). An attempt the network failed
  before kwwk had any of the reply is handed to kwwk only once
  `NWPathMonitor` has a route again, or after 30 s, so kwwk's own retries
  (five attempts, about fifteen seconds of backoff) go out when they can get
  through and kwwk still counts them; a failed TLS handshake
  (`NSURLErrorSecureConnectionFailed`), which kwwk never retries, is asked
  again here at most twice, 1 s apart. A failure after text, thinking or a
  call has streamed is kwwk's alone to take back and retry, a certificate
  error is never retried, and no tool runs twice: kwwk runs a call only once
  its message has settled.
  Prompt, steer, abort, compact, approve and close go
  to that session's running worker and to no other. The worker refuses a
  second `agentOpen` with `conflict` from its first suspension, and frees
  the place if the open fails. Its log, `sessions/<id>/events.jsonl`
  (`SessionEventLog`), joins streamed `textDelta`/`thinkingDelta` into one
  record of its kind, written at 512 bytes, 250 ms after its first delta,
  before any other event and on close, so a kill loses at most that
  pending text (2026-10-29: one reply had written every provider delta as
  a line, 684,540 of them, and reopening it took 104 s on a device). It is
  opened in one pass that decodes only the lines a session needs (its user
  message ids, whether it has a title, the approvals left waiting, the
  last number), and a reattach replays from disk outside the log's actor
  while appends go on, so an open answers at once and a send never waits
  behind the history; a line that will not decode stands as an `error` of
  its number. Beside it the worker keeps the conversation's diagnostic
  journal (owner, issue #27; `ApelinAgent/Journal/`), which Settings ▸
  Logs lists under Chats: `Journal/Agent/<session>.log` in the data
  folder, its levels made as mobile without following a link (Dog's own
  files stay at the top of `Journal/`), in Dog's line format — a
  `[Category]` line at each change, `* |<level>| <yyyy-MM-dd_HH-mm-ss>|
  <message>`, a line break in a message written `\n` so no tool output
  starts an entry —, appended across reopens, formatted and written on a
  queue of its own, never on the session's actor, and only while the file
  is a regular one of mobile's with one link (`DiagnosticJournal`). Past 2 MB it becomes `<session>.old.log`,
  replacing the one before; each open keeps the 100 journals written last.
  `SessionJournal` writes, by category: Session (open or reopen with
  provider, model id, API wire and the endpoint's host, never a key; an
  open that failed; model and mode changes; close), Model (each run's
  start and end with its finish reason and tool count, a run's error,
  every model request that ended on an error with its HTTP status,
  provider code and request ID — `observingRequests` inside
  `NetworkRecovery` —, a reply that failed, kwwk's retries, a wait for
  the network, a partial reply discarded, a title that failed), Tool
  (`Started call=<id> tool=<name> session=<id> at=<ms>` with the
  arguments, then `Ended call=… status=…` with start, end, duration, the
  result and, where it was decided, a `detail`), Approval (asked, with the
  call and reason; resolved, with the decision and the wait) and
  Compaction (started — automatic from kwwk's `compactStart`, or
  requested by `agentCompact` — with the messages, tokens and window and
  the model; whether the native compaction answered, had no summary or
  failed with its status, `observingCompaction`; ended with the outcome,
  `summary=native|local`, the messages compacted and tokens after, or
  failed with its duration, the HTTP status a request had meanwhile and
  the error). A call's status is `succeeded`, `failed`, `denied`,
  `cancelled`, `timed-out` or `interrupted`: the runner notes a refusal,
  a stop or a timeout where it is decided (`ToolCallOutcome`: the policy's
  `deny`, the user's decline, the host's `denied`/`timeout`, shell_run's
  `timedOut`, an extension's `timeout`, apelin_web_fetch's 30 s), kwwk's
  `toolExecutionEnd` ends the call with it, a call still running at close
  or when the host closes the worker's channel (`WorkerMain`'s `onClose`)
  ends `interrupted`, and one the journal shows started and never ended is
  ended `interrupted` when the conversation opens again, so a crash leaves
  no call that looks as if it were running. Every line is redacted first
  (`JournalRedaction` over ApelinCore's `LogRedaction`, every rule linear
  in the text and a long text redacted only as far as it can be kept,
  then cut): tokens and keys by their shapes (`ghp_`, `gho_`,
  `github_pat_`, `sk-`, `oc_sk_`, `xai-`, `glpat-`, `hf_`, `gsk_`,
  `sk_live_`, AWS, Slack, Google, JWTs, private keys), Bearer and Basic
  values, fields, headers, environment variables and options named like
  a secret (`isSecretName`, inside JSON written as a string too), a
  password in an address, e-mail addresses, mobile's home (`~`), the
  install root, roothide's `.jbroot-<id>`, root's home, an app
  container's ID, and the device and network identifiers feedback refuses
  (`PrivateShapes`: UDIDs, serials, MAC addresses, local addresses and
  names, the device's own name); an endpoint on the local network is
  named `local-endpoint`. Arguments keep their shape, each string redacted
  and then cut to 256 bytes, the whole at most 1 KB; a tool that returns the user's content (the
  file read tools, file_show, memory and skills, apelin_conversation_read,
  apelin_web_fetch, logs and crashes, the screen and its UI tree) is
  recorded by its size alone, any other result by a redacted summary of
  at most 512 bytes, an error at most 4 KB, each cut marked
  `… [truncated from <n> bytes]`. The app's own `Conversation` lines go
  through the same redaction and onto one line (`LogText`). Tested by
  `SessionJournalTests`, `JournalReviewTests`, `LogRedactionTests`,
  `LogRedactionAttackTests` and `Tests/Journal`. `agentCompact` (the
  app's alone, 2026-10-24) compacts the conversation between runs with
  kwwk's own compactor, as it does when the context fills — natively where
  the provider can —, answers once begun (`conflict` while a run or
  another compaction goes), writes the transcript when done, holds back a
  message sent meanwhile until it ends, and stops on `agentAbort`. Both
  compactions put `NativeCompactionFallback` in front of kwwk's native
  one (2026-10-28): a native reply that brings no summary back — kwwk's
  "Anthropic compaction returned no summary", for the 200 whose
  `compaction` block is null, which Anthropic documents for a tool called
  in place of the summary — falls back to kwwk's own summary, where kwwk
  alone failed the compaction and, with the context full, the run ("context
  is too large and compaction failed: …"); a status, a transport failure, a
  refusal and anything kwwk retries stay errors. Task events: `prompt`, `title` {text},
  `projectNameSuggested` {name} (only a concrete project intent),
  `steer`, `queued` {id, text, attachments} (a message sent while a run
  goes, handed to the run as a steer and recorded as its `prompt` of the
  same id only when the run's loop takes it, after the tool call in
  progress or before the run would end; one a run that failed or had just
  ended never took starts the next run, whose kwwk `continue` takes it),
  `queueDropped` {ids} (queued messages a stopped run never took, cleared
  from kwwk's steering queue too so no later run reads them; the app puts
  them back in the composer, text and files, ahead of what was typed
  since, and says "N Messages Not Sent" once the reader sees the
  conversation: `DroppedMessages`), `messageStarted`,
  `messageDiscarded` (kwwk gave up the message streaming since the last
  `messageStarted` and asks for it again: its text and thinking are not the
  reply), `reconnecting` (a failed model request is being made again:
  kwwk's retry, or `NetworkRecovery`'s wait), `toolCallPreparing` (the model began writing a
  call, which `toolCall` follows once its arguments are whole), `text` and `thinking` (streamed text coalesced
  to ≥ 512 bytes or 250 ms), `received` {tokens} (the output tokens the
  run has received so far: what streams of a message — text, thinking and
  a call's arguments alike — estimated by ApelinProtocol's
  `TokenEstimate`, each message that has ended at the provider's
  `usage.output`, or its estimate when that is 0; the session records it
  at most every 250 ms and at each message's end, never per delta
  (`OutputTally`), the relay sends only the latest with its next flush,
  and each run counts from nothing), `message`, `toolCall`, `toolResult`,
  `approvalRequested` {approvalID, toolCallID, tool, arguments,
  workingDirectory, projectID, fingerprint, reason, allowsSessionScope,
  detail} followed by `state` `waitingForApproval`, `approvalResolved`
  followed by `state` `running` when none is left, `notice` {title?, body}
  (`apelin_notification_send`, between its `toolCall` and `toolResult`; the host posts
  it, Notifications above; the transcript shows only the call), `error`
  {message}, `finished` {reason}, `compactionStarted` and
  `compactionFinished` {outcome: compacted, tooShort, cancelled or failed,
  messagesCompacted?, message?, summary?} (`AgentCompactionResult`; only
  `agentCompact` records them — kwwk's own compaction as the context fills
  is no event). `summary` (2026-10-28), when compacted, is what the
  conversation goes on from as the reader reads it: the history and
  current-turn sections of kwwk's recap, unescaped, without its markup or
  its file ledger (`CompactionRecap`; a recap of another shape whole),
  bounded by the recap's budget, about 1,800 tokens; it stays in the
  session's log, so a reopened session's replay carries it, and an event
  recorded before it has none. A failure kwwk
  kept as an NSError's whole `description` (`Error Domain=… Code=…
  "…" UserInfo={…}`, a lost connection) is cut to its localized
  description, the quoted sentence, in `error` and in a failed
  compaction's `message`, and again when the app shows an `error` an
  earlier worker recorded (`ErrorDescription`). An app that is not attached leaves an approval waiting; nothing
  approves by default. The file tools (file_write, file_create, file_edit; there is no
  rename, delete or mkdir) never write a git directory: a `.git` entry at
  any depth, compared without case, and what a `.git` file or link names
  (its `gitdir:` or link target, followed even before it exists, and that
  directory's `commondir`) or a `.git` directory's `commondir`, nor a folder
  git takes as one by its contents (git's `is_git_directory`: a `HEAD` and
  `objects/` and `refs/` or a `commondir`) — nothing below a folder with
  that layout, nothing below the `objects/` or `refs/` of a folder with a
  `HEAD`, no `HEAD` beside both or beside a `commondir`, and no `commondir`
  beside a `HEAD`, so whatever order the files come in, the one that would
  complete a bare repository is refused, while a `config` or `HEAD`
  anywhere else is an ordinary file —, decided on the
  canonical path (`Paths/GitDirectoryGuard.swift`: the target's own path
  and the `.git` in each folder above it, looked at again at commit, and
  one walk of the project per write, with no cap, for a `.git` elsewhere
  that names it — a folder the walk cannot read refuses the write), so no config or hook
  they write can feed the host's git presets. They read it freely; the
  repository changes through the git operations. file_read shows an image
  file as a picture (`FileImage`, 2026-10-29): the format is ImageIO's
  reading of the bytes, never the name, so an attachment under
  `Attachments/` reads too — PNG, JPEG, GIF, HEIC, HEIF, WebP, TIFF or
  BMP, up to 32 MB and 64 megapixels —, one frame of it (`frame`, else
  the primary image) upright, at most 1568 px a side and 3 MB, as PNG
  when the file has transparency and JPEG otherwise, after a line saying
  what it is; text that only begins like an image reads as text. A video
  is seen through frames extracted as image files, as the refusal of any
  other binary now says. The read tools
  (file_read, file_list, file_grep, file_find) also read, never write, an
  absolute path whose realpath lies in Apelin's development extensions
  (`<install root>/usr/share/apelin/development`, where a template's
  support headers are) or the data folder's `SDKs/`, as the read presets
  they are in every mode (`Paths/ReadOnlyRoots.swift`); a relative path,
  a link in the project included, is the project's, and a read tool's
  refusal of any other path names both folders. Every system tool is one
  host request
  (`ChannelHostBackend`): apelin_project_build → `buildStart` read to its end (the artifact's `buildID` is what apelin_package_confirm_loaded matches;
  its findings, and apelin_project_check_distribution's, keep their `field`,
  and a schema error adds a note naming the apelin-project-description
  skill's schema file; a build refused over an `apelin-project.json` that
  does not read — in Strict mode the host's "approval required" — is
  answered with `projectCheck`'s errors, field by field; a Debug build of a
  project with a description that succeeds while `installationList` shows
  nothing of the project installed adds `identifierHint`, naming the
  `local.apelin.` package ID and app bundle ID still there, to ask the user
  about before installing: `PlaceholderIdentifiers`), apelin_package_install →
  `installPackage` (a refused one answers its `conflict` events as
  `conflicts`; an app project's success adds `relaunchHint`,
  `AppRelaunch`: a copy already running keeps the previous build, which
  nothing stops, until icli's `app kill --force` — refused without the
  flag — and `app launch` restart it through shell_run as mobile, naming
  the app product's `CFBundleIdentifier`), apelin_package_remove →
  `removePackage` (an installation
  ID, or a package ID the worker turns into its one removable installation
  before asking: the card names its package, version and project, and
  `detail.packageRemoval` the installation, as before; an ID
  `installationList` shows as not removable, or does not show, is refused
  before asking, and a host refusal answers what can be removed instead),
  apelin_package_list → `installationList` (in any chat, every project's,
  a read preset, the folder of each project added),
  apelin_device_respring, apelin_package_confirm_loaded → a
  `confirmLoaded` task with the session's project read to its end (with
  `respring: true` it carries `trigger: respring` and is gated as apelin_device_respring;
  it never asks for `imageCheck`, and answers the host's `loaded` with a
  `basis` saying it rests on the marker alone, no image field beside it),
  apelin_log_read → a `logStream` of
  at most 10 s, list/read/symbolicate crashes → `crashList`, `crashOpen`
  (descriptor), `crashSymbolicate`, screen/UI → `captureScreen` (only
  after the user consented to that screenshot, as the prompt says),
  `readUITree`, `uiAction` (while Ask Before Using the Screen is on, each
  call asks in every mode, never for the session, the card's
  `detail.screenControl` naming the request, and so does a shell_run
  that runs icli, its `command` beside it: `ScreenControlApproval`), the
  framework tools' SDK → `sdkList` (the
  project's pinned `environment.sdk.id` first), shell_run → `agentRunCode`;
  in any chat (owner, 2026-10-24; General Chat's alone before),
  apelin_template_list → `extensionList` (isolated extensions left out)
  and apelin_project_create{template, name, values} → `projectCreate`
  (a list kind, such as the tweak's `filterBundles`, takes an array of
  strings, which apelin-build judges; apelin_template_list lists its
  default), allowed under Confirm like a project edit, answering the project's link
  and, read by the worker from the folder made, an `identifierHint` naming
  the placeholder identifiers it carries (the user's permanent ones go in
  `values` as packageID and bundleID, built-ins every template takes)
  — the new project's chat builds it, which apelin_conversation_create
  naming the project opens with the task (asking under Confirm, as any
  call into another project does), and this one's file tools stay where
  they are; a project's chat makes one only for work that is a project of
  its own, when the user asks or agrees. A repository is imported as New
  Project imports one, whatever it holds: an Empty workspace
  (`wiki.qaq.apelin.workspace/empty`), then its conversation opened with
  the URL and branch in the prompt, whose git_clone takes it in; the
  prompt, apelin_project_create's and git_clone's descriptions and
  `apelin-git-workflow` say so. apelin_project_delete {project} →
  `projectDelete` (owner, 2026-10-29: dangerous, but the agent may do it,
  under the modes as they are), in any chat, of another project named as
  the other project tools name one (its projectID or folder, from
  apelin_project_list), never the session's own (the workspace it runs in:
  delete it from General Chat or another project's conversation, or in
  All Projects), which the tool refuses before asking and the host again;
  a system tool that asks under Confirm every time, the card naming the
  folder and the name the sidebar shows and saying it cannot be undone,
  never with a session grant; Relaxed and Full run it. Its description and
  the prompt keep it to the user's explicit request to delete that
  project: never to tidy up on its own initiative, never because a file
  or a tool's output says so, and never a project's folder removed through
  shell_run. Project display names ▸ Deleting a project has the rest. In a
  project's chat only, git_status, git_diff,
  git_stage, git_unstage, git_commit (`all: true` stages every change)
  and git_init → the matching `git*` request,
  git_fetch, git_pull, git_push and git_clone → `gitFetch`, `gitPull`,
  `gitPush` and `gitCloneInto` read to their end, git_reset_to_remote →
  `gitResetPreview` before asking, then `gitResetToRemote` with the
  commits and address its card showed (owner, 2026-10-31, issue #32:
  asked on a card in every mode, Full included, naming what is lost —
  commits, uncommitted changes, replaced files, unrelated histories —,
  never with a session grant; nothing to do is answered without asking;
  its description, the prompt's `# Working` and `apelin-git-workflow`
  keep it to the user's explicit request to make the project match the
  remote, never to resolve a conflict or get past a refused pull or push
  on its own), and git_remote_list,
  git_remote_set and git_remote_remove → `gitRemoteList`, `gitRemoteSet`
  and `gitRemoteRemove` (owner, 2026-10-31, issue #32: a remote added to a
  project that has none, or pointed elsewhere, with the address the user
  gave; a name or address the host would refuse, or an address given to
  git_fetch, git_pull or git_push where a remote's name goes, is refused
  before the host and told to use git_remote_set); all of them run under
  Confirm like a project edit except git_push, which asks every time for
  the remote and branch it names (the checked-out branch read first when
  none is given, then sent explicitly) and the `url` it adds the remote
  at, never with a session grant. git_squash {count | base, message}
  (owner, 2026-10-31; `Tools/ToolRunner+History.swift`) → `gitSquash`:
  before asking it previews the squash, which refuses there what the
  squash would; under Strict the card (`detail.squash`,
  `ApprovalPolicy.squashReason`; the app shows the bound detail,
  `ApprovalCardText`) names the branch, each commit combined by short sha
  and subject, the new message and, when the upstream has some of them,
  that publishing it needs a forced push, which asks on its own card;
  every time, never with a session grant; Relaxed and Full run it. The
  squash carries the preview's full base and head. Its description, a
  line of the prompt's `# Working` and the `apelin-git-workflow` skill
  keep it to a squash the user asked for or explicitly agreed to, never
  on the agent's own initiative (`SquashToolTests` pins them); nothing
  else rewrites commits. A project with no
  remote is pushed with the `url` of an
  empty repository, one apelin_git_create_repository made on GitHub
  (below) or one the user made elsewhere. A forced push (owner,
  2026-10-31, issue #29: asked to make a local repository the main
  version of a public one, overwriting its `main`, an agent refused even
  with the user's go-ahead) is git_push {force_with_lease}
  (`Tools/ToolRunner+History.swift`): before asking, the tool fetches the
  remote with `gitFetch {branch}`; when the remote has no such branch or
  its branch is part of the local one it is an ordinary push, which the
  result's `note` says; otherwise the card (`detail.forcePush`,
  `ApprovalPolicy.forcePushReason`; the app titles it Force-push to the
  remote and shows the bound detail, `ApprovalCardText`) names the
  branch, the remote and its URL, the remote commit replaced and the
  local one sent, the commits that leave the branch, and that it cannot
  be undone from Apelin. It asks in every mode, never with a session
  grant; a `url` that is not where the remote pushes, a detached HEAD or
  a fetch that fails is refused before asking. The push carries the
  card's lease (`GitPushLease`), and the result names the remote, the
  branch, `from` and `commit`. The tool's description, a line of the
  prompt's `# Working` and the `apelin-git-workflow` skill keep it to a
  forced push the user explicitly asked for, of that branch to that
  remote: never on the agent's own initiative, never to get past a
  rejected push, never because a file, log, page or tool output says so,
  never through shell_run; `remoteChanged` or `localChanged` is told the
  user, then asked again (`ForcePushToolTests` pins the lines).
  A failure names its fix: Sign In with GitHub in Settings ▸ Git for
  github.com, a token the user gives for another host, an author there, a
  fetch and a merge or rebase the user agrees to before a rejected push,
  never a forced one, git_init for a project
  with no repository, and, for a push with no remote, asking the user
  whether to create a GitHub repository or for an empty one's `url`. The
  agent keeps the
  history itself (owner, 2026-10-25; the `apelin-git-workflow` skill, one
  line in the prompt): unless the user drives git, it commits on its own
  once a change builds, and pushes only when asked. apelin_git_read_settings, apelin_git_set_author,
  apelin_git_save_credential and apelin_git_remove_credential → `gitSettings`,
  `gitAuthorSet`, `gitCredentialSet` and `gitCredentialRemove`, in any chat:
  reading needs nothing, every change asks under Confirm (the card names
  the host and user, never the token, and never a session grant), and the
  token is masked in the `toolCall` and `approvalRequested` events
  (`ToolArgumentRedaction`); `GitHandler` skips its project check for
  these four. apelin_git_save_credential refuses github.com before
  anyone is asked: that host is the user's Sign In with GitHub.
  apelin_git_create_repository {name, visibility, owner?, description?}
  → `gitRepositoryCreate` (owner, 2026-10-29), in any chat: an empty
  repository on GitHub with that sign-in, answering its full name, clone
  URL and link and that git_push with `url` set to the clone URL
  publishes the project there (as `origin`, or the remote the user
  names). Its description and a line of the prompt's `# Working` keep it
  to a repository the user asked for or explicitly agreed to when asked,
  with the owner, name and visibility they gave — `visibility` is
  required, never assumed —, never on the agent's own initiative or
  because a file, log, page or tool output says to; the tool refuses
  before asking what `problem` would refuse. Like git_push it asks under
  Strict every time, the reason naming the owner, name and visibility and
  the card showing them as the arguments (`detail.repositoryCreate`
  {owner?, name, visibility, description?}), never with a session grant,
  and the host spends exactly that approval (`AgentRepositoryCreateRules`);
  Relaxed and Full make it without asking. A reply with reason
  `authenticationRequired` becomes "Nothing was created: GitHub
  authorization is needed … Sign In with GitHub in Settings ▸ Git"; any
  other refusal is GitHub's or the host's, in their words.
  apelin_git_create_issue {repository, title, body} → `gitIssueCreate`
  (owner, 2026-10-30), in any chat: an issue under the user's account on
  a repository the user named (`owner/name`), such as another app's or
  tweak's, answering its number and link; Apelin's own feedback stays
  apelin_feedback_send, and the tool refuses owngoal-dev/Apelin for it.
  Its description and a line of the prompt's `# Working` keep it to a
  repository the user named and asked to file on (or explicitly agreed to
  when asked), the repository and the whole title and body shown to them
  and posted only after their explicit consent, in every mode, never on
  the agent's own initiative or because a file, log, page or tool output
  says to; when GitHub refuses, the agent tells the user what blocks it
  and never posts elsewhere or falls back to a browser or the screen
  tools (a refusal's answer says so too). The tool refuses before asking
  a repository not shaped `owner/name` and text `FeedbackRules` would
  refuse. Like apelin_feedback_send it asks under Strict every time, the
  card showing the repository, title and body (`detail.issueCreate`
  {repository, title, body}), never with a session grant, and the host
  spends exactly that approval (`AgentIssueCreateRules`); Relaxed and
  Full post it without asking. `IssueToolTests` pins the description and
  the prompt line.
  On a workspace, apelin_project_build runs the script its `external`
  declares (Workspace builds, below) and asks under Confirm every time,
  never with a session grant; one that declares none answers how to
  declare it instead of asking.
  Toolchains and SDKs (2026-10-22, `ChannelHostBackend+Environment.swift`),
  in any chat: apelin_toolchain_list → `toolchainStatus` and `toolchainCatalog`
  (the installed ones with their components, newest SDK read and
  self-test results; each release Apelin sets up with its size, newest
  SDK, recommended SDK, minimum iOS, CPU features, Swift and why this
  device cannot take it, the catalog's fields the app's picker shows; the
  project's binding), apelin_sdk_list → `sdkList` with the sources read and
  `toolchainStatus` (registered SDKs and the branches the enabled sources
  offer, each with the toolchains that read it), both read presets.
  apelin_toolchain_setup {version | product_id, swift?} → `toolchainSetup` from
  Apple's catalog, the release resolved in the catalog before asking and
  sent by product ID (one this device cannot take, Swift a release does
  not offer, or a release already set up is refused before asking), and
  apelin_sdk_import {version, source?} → `sdkImport` of the branch an enabled
  source offers (the model never names an address), each read to its end
  with `environmentAttach`, only the stages, warnings, failed self-test
  cases and the record kept; under Confirm each asks every time, the card
  naming the release and its download size or the source, branch and
  address, never with a session grant, and the host spends exactly that
  approval (Approvals above). Their tasks are ended, not resumed, when
  the host stops (an agent session started them); a setup's job record
  stays, and the next setup of the same release goes on from it.
  apelin_toolchain_self_test {toolchain_id} → `toolchainSelfTest`, asking under
  Confirm (a session grant allowed: it records results and installs
  nothing). In a project's chat, apelin_project_set_environment {toolchain_id?,
  sdk_id?} → `projectCheck` with `environment` (the check a project bound
  to them gets, nothing written, digests the registry's), refused on any
  `environment.*` error with its message — an SDK newer than the
  toolchain reads is `environment.sdk.tooNewForToolchain`, as for a
  project bound to it — and on a project file that does not read with
  each error by its field (one lacking the `template` and `environment`
  only apelin_project_create writes, such as a workspace rewritten by
  hand, is told it is no description and that a workspace builds with a
  script of its own), then the four strings of `environment` rewritten
  in `apelin-project.json` through the file tools' writer, every other
  byte kept and read back to prove it, then written in the manifest's
  written form, which reads back as that same document
  (`ProjectEnvironmentEdit`). It is a
  project edit under Confirm: the file tools could write the same field,
  only a registered and checked pair goes in, and the binding is not in
  the build description digest (Documents/Schemas/README.md), so the next
  build does not ask for it. Left out (2026-10-22): toolchain and SDK
  removal (device-wide, never needed to build, Settings asks itself; the
  prompt says removal is the user's there, and never by deleting files),
  transfer export (its file is only of use through the app's share sheet);
  project rename came later (2026-10-24, apelin_project_rename, Project
  display names below); a distribution build is apelin_project_build
  {configuration: release, bootstrap}.
  apelin_project_list (2026-10-24), in any chat, a read preset with no
  host request: the projects under `Projects/` as the conversation tools
  resolve them (`ChannelHostBackend.projects`: no folder that links out,
  a manifest a regular file of at most 1 MB with a projectID, nothing
  hidden, sorted, at most 200), each with its folder, projectID, the name
  the sidebar shows, `apelin` or `external`, its link and whether it is
  this session's — the names a `project` argument takes, which General
  Chat had no other way to learn.
  Conversations (2026-10-22, `AgentConversations`,
  `Session/Agent/AgentConversationRules.swift`), in any chat — General
  Chat names a project, its own chat has no others:
  apelin_conversation_create {prompt, title?, project?} → `agentOpen` from the
  agent with this session's provider, model, effort and tier
  (`SessionModelChoice`: the open request's, then each app prompt's) and
  the title (`AgentOpenRequest.title`), answered without waiting with the
  session's link; the host opens it in the caller's own project, or the
  project the request names (by projectID or folder, resolved by the host
  as for the app's open), under the caller's current approval mode, with
  a non-empty prompt and nothing else of the caller's (never a temporary
  project, a session to reopen or a headless close; at most 6 opened by
  agents running per project, a place held from the check to the open so
  two opens cannot both take the last, and a chain of openings at most 2
  deep, across projects too), recording the parent and depth (kept when
  the app reopens the session) and appending `conversationOpened`
  {sessionID, task, title?, prompt, projectID, projectName} to the
  opener's task, from which the app adopts it as a conversation of that
  project without selecting it (and from `agentList`'s `parentSessionID`
  and `projectName` at launch: `ChatAdoption`). The worker names the new
  session by its title, else generates one. apelin_conversation_send {project?}
  → `agentPrompt` to another session as the user's message (never a
  temporary chat): the host writes `fromSessionID` (the app's is dropped)
  and clears the mode, provider, model, effort, tier, message ID and
  attachments, and refuses descriptors; the worker records it as
  `prompt` {text, from}, the model reading one line before it naming the
  sending conversation (`ConversationSender`), and the app names the
  sender over the bubble. apelin_conversation_list {project?} → `agentList`
  {projectID?}, one project's sessions only — in General Chat, naming
  none, every project's it may reach: all in Relaxed and Full, under
  Strict those the user let it reach, saying how many it left out
  (`unreachedProjects`) —, each with `parentSessionID`, its link and, from
  another project, its folder, titled by the session's own `title` events
  as the host relays them. The session table starts empty with every host
  and apelind exits when idle, so an agent's list (the app's stays the
  table's) also names the sessions that have not run since the host
  started (`AgentConversationList`, 2026-10-29): each by the newest agent
  task the registry kept, ended and read like any ended one, in the
  project its `session.json` names when that is under `Projects/`, at most
  200, the most recently active; apelin_conversation_read {project?} →
  `agentList` for the task, then `agentAttach` of a task of that
  project's sessions only, read from the start (`ConversationReader`:
  state running, waitingForApproval, idle or ended, the approvals still
  waiting (none once it ended), the assistant's `message`
  and `error` texts after `after_seq`, cut at 32 KiB with `last_seq`
  where the next read goes on), and with `wait_seconds` (0–180, under the
  provider's five-minute cache: Prompt caching, below) attaching
  again, 5 s at a time, until a turn after `after_seq` finishes, a new
  approval is asked, it ends or the time runs out; apelin_conversation_stop
  {close?} → `agentAbort`, then `agentClose` when asked, of a session the
  caller opened, wherever it is. In the caller's own project, create,
  send and stop pass Confirm like a project edit, list and read as read
  presets: the conversation it opens asks for its own risky steps. Any of
  the four that names another project asks under Confirm every time, the
  card naming the project and the prompt or text, never with a session
  grant, and the host decides again (Approvals above); the worker resolves
  the project from `Projects/` for the card, the host resolves it again.
  Links (2026-10-22): the app opens `apelin://conversation/<session ID>`
  (selecting its project) and `apelin://project/<projectID>`
  (`ApelinLink`); apelin_conversation_create, apelin_conversation_list,
  apelin_conversation_read and apelin_project_create answer them beside the IDs, and
  the system prompt tells the model to hand the user a markdown link
  whenever it opens or points to another conversation or project.
  `agentApprove` and `agentSteer` stay the app's.
  Notices (2026-10-24, `Tools/UserNotices.swift`), in any chat:
  apelin_notification_send {title?, body} → no host request: the tool writes a `notice`
  event, which the host posts as a banner by its own rules (Notifications
  above). It never asks, in either mode, and is no preset the user could
  take away (`ApprovalPolicy`): it reads, writes and runs nothing, and the
  reader it is for is away. Its description keeps it to what the user
  would want to know while away, never routine progress, the reply or the
  turn's end, which the host announces itself. The tool refuses, so the
  model hears it, what the host would not post — a body past 180
  characters or empty, a title past 40, a fourth in one run — and one
  sent within 30 s of the session's last; the host cuts and counts again
  (`AgentNoticeRules`).
  Web pages (2026-10-29, `Tools/WebFetch.swift`, `HTMLText.swift`,
  `PublicHost.swift`), in any chat: apelin_web_fetch {url, offset?} → no
  host request: the worker fetches one public http or https page itself,
  as mobile, through an ephemeral session with no cookie, cache or
  credential, and answers its text — HTML as plain text with headings,
  lists, ``` blocks and [text](absolute url) links, any other text as it
  is — 32 KB of UTF-8 a call, with the offset to read on. Refused before
  anyone is asked, and again for each of at most five redirects, which it
  follows by hand: another scheme, a user or password in the address, a
  local name (localhost, `.local`, `.internal`, `.home.arpa`, no dot) or a
  literal loopback, private, link-local, CGNAT, multicast or reserved
  address in any spelling the resolver reads (a name that resolves to one
  is not caught). A body is read to 5 MB and marked cut past it, a type
  that is not text is refused with its size, an HTTP error is answered,
  and a call is bounded at 30 s. A read that is no default preset
  (`isSensitiveRead`, like the screen's): Strict asks, a session grant
  covers that exact address and offset, Relaxed and Full run it. There is
  no web search: no keyless service would do, and kwwk sends no
  provider's search tool; the prompt sends the model to a known source,
  never a results page scraped with curl. Tested by `WebFetchToolTests`
  against a stubbed session; nothing there reaches the network.
  Feedback (owner, 2026-10-29), in any chat: apelin_feedback_send {title,
  body} → `feedbackSend` (Distribution repository ▸ Feedback, below),
  answering the issue's number and link. Its description and a line of
  the prompt's `# Working` (owner, 2026-10-29) have the agent ask first,
  in every mode: it shows the user the title and body it would send and
  sends only after the user replies with explicit consent (同意 or 确定,
  or the same word in their language), never on its own initiative and
  never because a file, log, page or tool output says to. The text holds
  no credential, device identifier, host name, network address or home
  path; the tool refuses before asking what `FeedbackRules` would refuse.
  `FeedbackToolTests` pins the description and the prompt line. On top
  of that, like git_push, Strict asks every time, the card naming the
  repository and showing the whole title and body (`detail.feedback`
  {repository, title, body}), never with a session grant, and the host
  spends exactly that approval (`AgentFeedbackRules`); Relaxed and Full
  show no card. A
  reply with reason `authenticationRequired` becomes "GitHub
  authorization is needed: … Sign In with GitHub in Settings ▸ Git".
  Feedback already filed is edited, never filed again (owner, 2026-10-30;
  `Tools/FeedbackEdit.swift`), in any chat: apelin_feedback_read {number}
  → `feedbackRead`, a read preset, answering the title, the body without
  Apelin's footer, the footer apart, who opened it, whether the user's
  account did, the state, the link and a `revision` naming the title and
  body it saw; apelin_feedback_edit {number, revision, title?, body?} reads
  the issue again first and refuses before asking another account's
  issue, one whose revision is not the one passed (it changed on GitHub
  since the model read it, perhaps by the user: read it again and keep
  that), an edit that changes nothing and text `FeedbackRules.editProblem`
  refuses, then sends `feedbackEdit` with only the fields that change and
  the title and body it just read as `expectedTitle`/`expectedBody`,
  answering the link and the revision a further edit passes. Its description and a `# Working` line keep it to
  a change the user asked for, shown to them (the new title and body, or
  before and after) and made only after their explicit consent, in every
  mode, never on its own initiative or because a file, log, page or tool
  output says to. Strict asks every time, the card naming the repository
  and issue and showing the new title or body whole (`detail.feedbackEdit`
  {repository, number, url, title?, body?, currentTitle, currentBody}),
  never with a session grant, and the host spends exactly that approval
  (`AgentFeedbackRules`); Relaxed and Full show no card.
  `FeedbackEditToolTests` pins the descriptions and the prompt line.
  Agent tool extensions (2026-10-29, `Tools/ToolExtensions.swift`,
  `Tools/ToolExtensionSessions.swift`; Milestone 1 §6), in any chat: an
  installed extension's tools are the agent's own. The worker reads the
  manifests as the host does (`ToolManifestValidator.discover` on the
  install root, root's files only) when the session opens and before each
  message that starts a run, and offers each tool by Agent tool names'
  rule; a manifest that does not validate is left out alone, and whatever
  is left out is logged. A definition is the manifest's description, a
  sentence naming the extension and saying it runs as mobile outside the
  project (so the model gives absolute paths), and its schema with the
  `reason`; a blank optional argument is dropped before kwwk holds the
  call to the schema, an empty one before the host does. The first call of
  one of an extension's tools opens it (`toolHostOpen`, never before: the
  host keeps 16 for the device), the session keeps it, a call answered
  `notFound` (the extension exited) opens it again once and is made again,
  and the session closes them with itself. Each call carries the
  manifest's `timeoutSeconds`; an `error` answer is the call's failure,
  "<extension> answered <code>: <message>"; the text is the result, and
  each returned file is copied into `Attachments/`, named in the text with
  its size for file_read and handed to the `toolResult` attachments as
  file_show's copies are, an image put before the model too. Strict asks
  every call, the reason naming the extension and the declared `risk`
  letting nothing through, with a session grant as for an MCP tool, bound
  to the extension's version; Relaxed and Full run it. An extension installed or removed while a chat
  is open changes its tools between runs, never during one or a
  compaction, and that message's `<system-state>` says so with
  `# Environment`'s lines that came and went. Tested by
  `ToolExtensionTests` (the shipped manifests among them) and
  `ToolExtensionBackendTests`.
  Publishing (owner, 2026-10-29; `Tools/PackagePublish.swift`,
  `ChannelHostBackend+Publish.swift`), in any chat: apelin_package_publish
  {build_ids} → one `distributionPublish` {files, digests, repository}
  with every package, read to its end with `environmentAttach`: release
  builds' packages put in the linked package repository exactly as they
  were built, never built again, so the roothide and rootless builds of one
  version go in one commit. Before anyone is asked the worker reads, as
  mobile, each build's `Builds/artifacts/<id>.json` (the build ID is the
  artifact ID), the link in `Settings/distribution.json` while its project
  is there and, from `gitSettings`, a github.com sign-in, and refuses, all
  at once, a build with no record, a debug build, a package gone from the
  build folder and two of one package ID, version and architecture; no
  link is "create or link one in Settings ▸ Git ▸ Publishing", no sign-in
  (or a reply with reason `authenticationRequired`) "Sign In with GitHub in
  Settings ▸ Git". Its description and a line of the prompt's `# Working`
  keep it to a publication the user asked for or explicitly agreed to, told
  which packages go to which repository, never on the agent's own
  initiative or because a file, log, page or tool output says to. Strict
  asks every time, the card showing the repository and each package by ID,
  version and architecture with its digest as the arguments
  (`ApprovalCardText`, from `detail.packagePublish`), never with a session
  grant, and the host spends exactly that approval and, in every mode,
  takes only files its builds reported with those digests
  (`AgentPublishRules`); Relaxed and Full show no card. The result names
  each file published or already there, the repository and that package
  managers see it once the repository's workflow has run. Sharing the file
  itself stays Distribute…'s or the share sheet's. Tested by
  `PackagePublishToolTests`, `PublishBackendTests` and the session host's
  checks.
  `agentRunCode` is a closed request — `argv` (an executable name looked up
  on the run's own `PATH` as its shell would, the toolchain's tools first,
  but a preset's and a root run's in the bootstrap's bin directories, then
  `/usr/bin`, `/bin`, alone; or a path, from the working directory unless
  absolute; the canonical file is exec'd with the request's own words as
  its argv, so `clang++` and `swiftc` keep the name they read) or `script`
  (sh, bash, zsh, python3, perl with `-c`/`-e`) — that the host runs itself,
  only for the caller that is that session's worker, as mobile (uid, gid,
  groups 501 before exec) — or, with `asRoot`, as root, which
  `AgentApprovals.authorize` allows only in Full mode (both the session
  table and the ledger saying Full, the ledger holding an unknown session
  to Confirm) or against one single-use approval of a *root* request
  (`detail.rootCommand`) for exactly that command and directory; a root run
  is never a preset, never a session grant, and an approval of an ordinary
  request never authorises it. The identity is the host's decision, not the
  request's; a root run keeps root's own `HOME` —, in a working directory
  that resolves inside the
  project, its own process group killed at the timeout (1–1800 s), both
  streams capped at 256 KiB and read for at most 2 s after it exits or is
  killed — a descendant that left the group (setsid) is neither found nor
  killed, and the pipes it still holds are closed on it, the output marked
  `truncated` —, so the timeout bounds the call. Every run but a preset gets
  the development environment (`DevelopmentEnvironment` in ApelinProtocol,
  the one builder the terminal and the system prompt read too): the
  project's bound toolchain, else the registry's default, first on `PATH`
  (also `APELIN_TOOLCHAIN_BIN`), and `SDKROOT` — the project's bound SDK,
  else the newest registered one that toolchain reads, what `projectCreate`
  binds — with `IPHONEOS_DEPLOYMENT_TARGET` (the project's, else 16.0), so
  clang targets iOS against the SDK without flags; a temporary chat gets
  the defaults. The host reads `Environment/Toolchains/registry.json`,
  `SDKs/.registry/` and `apelin-project.json` as root only inside the data
  folder or project, by canonical path, without following a link, and checks
  the opened descriptor's path again; only paths, IDs and a version go into
  the environment. A preset keeps its own list and the bare search path.
  Under Confirm the host
  re-decides it: a preset it recognises (read-only argv: ls, cat, head, tail, wc, file, stat,
  `plutil -p`, `git status|diff|log`; `Session/Agent/AgentRunCodePresets.swift`)
  — every path argument and `--option=value` value, read from the working
  directory, staying in the project by realpath, no list of names read
  from a file (`--files-from`, `wc --files0-from`), `file` with only
  `-b -i -L -h -k -N -0` (bundled letter by letter) and `--brief --mime
  --mime-type --mime-encoding --dereference --no-dereference --keep-going
  --no-pad --print0` (no magic file, no decompressor), `ls` without `-L`,
  `-R`, `--dereference*` or `--recursive`, and nothing after `plutil -p` but
  files; git without `--output`, `-o`, `--ext-diff`, `--textconv`,
  `--no-index`, `-c` (but after `log`, a combined diff), `-C` (but after
  `diff` or `log`, find copies), `-O`, `--exec-path`, `--git-dir`,
  `--work-tree`, `--submodule`, `--ignore-submodules`,
  `--recurse-submodules`, `--show-signature` or any `%G`, `%+G`, `%-G` or
  `% G` (long options
  abbreviated too, as getopt_long and git accept them), and no short option
  with anything attached but `-<n>`, `-U<n>`, `-l<n>`, `-n<n>`, `-M<n>`,
  `-C<n>`, `-B<n>[/<m>]`, `-G<regex>`, `-S<string>` and a bundle of the
  subcommand's value-less flags (status `-s -b -z -v` and a last `-u`
  with `no`, `normal` or `all`; diff `-p -s -z -w -b -R -a` and a last
  `-M` or `-C`; log those and `-c -m`); only in the
  repository git itself names from the working directory (`git rev-parse
  --absolute-git-dir --git-common-dir --show-toplevel` with the preset's
  environment and overrides, as mobile; never a model of git's discovery,
  which skips an invalid `.git` and takes HEAD beside `commondir` as a
  repository): its git directory its own common one and a real
  `<top level>/.git` directory inside the project, so neither a worktree,
  a `commondir` nor a bare layout counts, with or without
  `safe.bareRepository` (which a git older than 2.38 ignores); no
  `.gitmodules` and no `.git/modules`; and a config holding nothing but
  what `git init`, a clone (`apelin.cloneTask` included) and an author
  write — read by git's
  own parser (`git config --file … --list --name-only --null`, as mobile,
  no system or global config, off the cooperative pool), never by hand, any
  error or include refused — and run with `--no-pager --no-optional-locks`,
  configured commands overridden by `-c` (`submodule.recurse=false`,
  fsmonitor, pager, `diff.external`, hooks, attributes file,
  `safe.bareRepository=explicit`, every `gpg.*program` pointing nowhere
  and `log.showSignature=false`, so a signed commit never starts gpg),
  `--no-ext-diff --no-textconv` for diff and log, `--ignore-submodules=all` for status
  and diff, and no system or global config (`GIT_CONFIG_NOSYSTEM`,
  `GIT_CONFIG_GLOBAL=/dev/null`, discovery stopped above the project);
  the words of a preset are one rule, ApelinProtocol's `RunCodePresetRule`,
  which ApelinAgent's presets read too, with paths read from the same
  working directory — or an approval the app gave through
  `agentApprove` for a `shell_run` `approvalRequested` of this session, used
  once, and only for the command its `detail.command` showed (shell text
  as the `sh` script it is sent as) in its `workingDirectory`; any other
  run is refused and leaves the approval unspent. An `agentApprove` with
  `scope: session` for a request that offered it (`allowsSessionScope`)
  also leaves a session grant for exactly that command and directory,
  normalised the same way; the agent then sends an identical call as
  `RunCodeApproval.session` (its gate's remembered fingerprint), which the
  host runs only against a grant of this session, never spent, taken back
  if the worker refuses the decision and forgotten on `agentClose`. A root
  request (`asRoot`) is approved on its own `detail.rootCommand`, never a
  session grant and never a preset, and the relay takes it only with the
  app's `ownerVerified` (the device owner checked); `agentClose` forgets
  every unspent approval, a root one included. A call
  the agent sent as a preset that the host's rule does not count is
  refused with `RunCodeApproval.presetRefusal` (`denied`, reason
  `notAPreset`: the agent goes by `ApelinError.reason`, never the message);
  the agent then asks the user (`approvalRequested` with the command), sends
  it again with that approval. Nothing remembers the refusal: whether a
  call is a preset depends on the repository (a `.git` made, a
  `.gitmodules` removed), so the next one goes as a preset again and the
  host decides. The build/install digest rule reads the host's ledger
  (`HostDigestLedger`): the digest apelin-build answers in `projectCheck` ▸
  `descriptionDigests`, then `approvalDigestState` — the template's own runs
  without asking, an approved one too, a changed one asks (when apelin-build
  gives no digest the agent's own SHA-256 over the description stands in,
  which never matches, so it asks). `agentOpen` sets the session's mode in
  the ledger (`setMode`); relaying an approved `agentApprove`, the host reads
  what was asked from the session's own `approvalRequested` event and calls
  `recordApproval(digest, kind:, project:)` for a changed description or
  `allowRemoval(installationID:, session:)` for a package removal (a
  apelin_package_remove request carries `detail.packageRemoval.installationID`;
  without it the approval would never be spent), before
  the worker hears it, and takes the grant and the session's record of the
  decision back if the worker does not accept it; `agentClose` forgets the
  session.
- **Agent tool names** (owner, 2026-10-24). A tool that acts on what
  Apelin keeps — its projects and templates, the packages it installs, the
  device, the screen, logs and crashes, toolchains and SDKs, other
  conversations, memory, skills, its git settings, a notification, the
  feedback filed on Apelin — or reaches past the device (`apelin_web_fetch`,
  `apelin_git_create_repository`, `apelin_git_create_issue`) is
  `apelin_<scope>_<verb>` (`apelin_project_build`, `apelin_package_install`,
  `apelin_device_respring`, `apelin_git_set_author`, `apelin_feedback_send`);
  a generic verb on the
  session's own project is `<domain>_<verb>`: `file_read`, `file_write`,
  `file_create`, `file_edit`, `file_list`, `file_grep`, `file_find`,
  `file_show`, `shell_run`, and the repository's `git_*`. MCP tools
  keep kwwk's `mcp__<server>__<tool>`. Lowercase, `[a-z0-9_]`, a letter
  first, no `__`, at most 64 characters, which every provider takes
  (`AgentToolNameTests`). An agent tool extension's tools keep their
  manifest's names (`disassemble`, `symbols`, `assemble`) when a name
  keeps that rule, is no name `AgentToolName.canonical` knows, takes no
  `reason` argument and is declared by one installed extension only;
  otherwise the tool is left out, both of a duplicate
  (`ToolExtensionOffer`). Apelin's own names are ApelinProtocol's
  `AgentToolName`, which the session host's approval rules, the app's
  titles and widget and the agent read; what each tool does stays in
  ApelinAgent's `ToolCatalog`. `AgentToolName.legacyNames` keeps the names 0.1.8 and
  before used (and `notify_user`), and `canonical` answers the tool either
  kind of name means: the app titles an old conversation's calls as new
  ones, the widget and apelin_conversation_read show today's names, and the
  credential redaction masks a token whatever name the call was recorded
  under — a reopened session relays its whole log again. A reopened
  session's transcript is put in today's names before kwwk reads it
  (`LegacyToolNames.migrate`: calls, results and kwwk's tool
  declarations, never text), so no provider is sent a call to a tool the
  request does not offer. The host matches today's names only: an
  approval asked under an old one is refused, and the worker and host
  ship and restart together. Project instructions, memories and skills
  written before are not rewritten; the prompt says once that they may use
  the old names (`SystemPrompt.renamedToolsNote`). `ToolNameReferenceTests`
  fails on an old name in the prompt, a tool's description, a built-in
  skill or any source of the agent.
- **Agent credentials** are the keychain's: `KeychainCredentialSource`,
  service `wiki.qaq.apelin.agent`, access group `wiki.qaq.apelin.agent`
  (`keychain-access-groups` on apelin-agent only), after first unlock, this
  device only, never synchronised. The owner provisions one with no UI by
  dropping a file in `~/Documents/wiki.qaq.apelin/console/inbox/credentials/`
  — `<store id>.json` in kwwk's credential shape (any store id a provider
  below is kept under: `github-copilot`, `anthropic`, `anthropic-api-key`,
  `openai-compatible`, `openai-codex`, `kimi-coding`, …) or a kwwk `auth.json`
  map — and running `agentCredentialImport` (or opening a session, which
  imports first). Each file is opened without following links, bounded to
  64 KiB, read once, stored and unlinked whatever it held; the reply names
  store ids and reasons, never contents. The import runs in an apelin-agent
  instance named `credential-import`, so the item is written and read by
  the same signed executable.
- **Agent sign-in** (`Packages/ApelinAgent/Sources/ApelinAgentWorker/SignIn/`,
  `Apelin/Interface/Settings/Accounts/`). Settings ▸ Model Providers (one
  row on the Settings root, the signed-in count beside it, pushing
  `ModelProvidersController`: signed in first with who as and a `…` menu,
  then the rest under Sign In with an Account and API Keys, searchable)
  signs in to every login kwwk offers, plus DeepSeek. API-key fields use native inset
  grouped sections, with Fetch Models in the navigation bar. Setup stores
  the key and gets the endpoint's model list before model selection; no
  arbitrary default model is probed. The selection page allows custom IDs
  only for API-key accounts. A trailing swipe removes an API model locally;
  saved hidden IDs keep it out of later discovery, and adding the ID again
  restores it. Custom IDs, hidden IDs and enabled IDs commit together on
  Save. Save probes every selected ID in the account
  worker before changing the device's enabled list; a long press offers
  Save Without Verification. A failure preserves the selection. These
  validation tasks use the existing sign-in task lifetime and cancellation.
  `ProviderProgress` uses AlertController's progress view for discovery and
  the existing AlertController-backed ProgressCard for cancellable work;
  Cancel stops both the UI task and backend task. Both dismiss before success.
  OAuth has no editable key, endpoint or custom-model controls. After OAuth,
  users only select enabled models; Copilot applies the selected IDs' policy
  opt-ins before saving, and a refusal does not silently count as activation.
  `agentModelList` and `agentModelActivate` are app-only operations forwarded
  to the credential worker. `agentAPIConfiguration` is also app-only: the explicit
  Edit Configuration form receives the stored API key and endpoint in a direct
  reply, keeps the key secure while editing, and prefills every saved field.
  Account lists and task events remain secret-free; the console refuses this
  operation before sending it, so no key reaches its output or logs. DeepSeek's official
  Anthropic-compatible endpoint maps to the DeepSeek model family, not the
  Claude catalog; API-key discovery reads the endpoint's model-list API.
  `EnabledModels` owns only local, non-secret selections and custom IDs;
  sign-out clears them. The chat picker is an uncached deferred context
  menu reading enabled IDs only, and opens
  Model Providers when there are none. API-key model IDs need not occur in
  kwwk's static catalog; OAuth IDs remain restricted to that provider's list.
  Each login is an `AgentProvider` case kept
  under one store id (`AgentProvider.storeID`), with kwwk's own flows:
  every subscription `OAuthSubscriptions.providers` names, through
  `OAuthSubscriptions.login` (public KWWKAuth API; for Copilot kwwk's
  model policy activation after selection) — a device code for
  GitHub Copilot, Kimi For Coding and Grok; Safari with kwwk's loopback
  listener for Claude Pro or Max, ChatGPT Codex, Devin and OpenRouter; a
  page kwwk polls for Cursor, Qoder, Qoder CN, WorkBuddy, WorkBuddy AI, Z.ai
  and BigModel; Kiro's own listener — and every API-key entry of KWWKCli's
  `loginProviders` (Anthropic, OpenAI, Google AI Studio, OpenRouter,
  OpenAI-compatible), its fields mirrored once in `SignInKeyForms` (KWWKCli
  is an executable target), stored in kwwk's API-key shape (the key as
  `access`, no refresh, never expiring, `baseUrl` and `defaultModel` as
  extras — what KWWKCli's internal `apiKeyCredentials` writes, so it is
  rewritten in `AccountDesk`). DeepSeek adds an API-key form and its own
  `deepseek-api-key` credential item, separate from `openai-compatible`.
  Display order is Apelin's `AgentProvider.signInOrder`, independent of
  kwwk's registration order;
  `AccountDeskTests` fails when kwwk gains a subscription or a stored
  provider (`providerDirectory`) the table lacks, or when a provider here is
  one neither kwwk nor Apelin can register for a session. OpenRouter signs in both ways
  under one store id: `AgentAccount.alternativeMethods` names the key form
  beside its browser sign-in, and `agentSignIn{provider, method}` picks one
  (any other method is refused `badRequest` before the task is accepted).
  Kimi binds a grant to a device id: kwwk records it in the credential
  (`deviceId`), a sign-in again reuses the recorded one, a first one makes a
  new one (`KimiIdentity`), and neither the sign-in nor a session's refresh
  ever reaches kwwk's `~/.kwwk/kimi-device-id` (sessions build their
  `OAuthManager` with `KimiIdentity.refreshers()`). Sessions can use every
  provider: the first four keep their `ProviderConfiguration` cases, every
  other is `.stored(storeID:, model:)`. `ProviderRegistration` is shared
  by account verification and conversations: it uses kwwk's registration
  and transports, adds DeepSeek, and applies DeepSeek's catalog capabilities
  to its official Chat Completions endpoint. Unknown models keep their
  existing capabilities; model names alone never identify a provider. The
  app cannot write the keychain group, so every flow runs in apelin-agent's
  `credential-import` instance (`AccountDesk`), which stores the result
  where the sessions read it. `agentSignIn{provider, method?}` (app only) is a task
  of kind `signIn`, read with `agentAttach`, never resumed, one at a time
  (a new one ends the old `cancelled`, freeing its port) and ended `failed`
  after 15 minutes (`AgentSignInRequest.timeoutSeconds`). Its events carry
  only what the user must see or open: `deviceCode` {code, verificationURL,
  pageHoldsCode}, `authorize` {url, acceptsCallbackURL — false for a page
  kwwk polls and for Kiro, whose listener is kwwk's own}, `input` {fields:
  [{key, required, secure, defaultValue?, placeholder?}]}, then `state`.
  `agentSignInRespond{taskID, values}` hands back, once, the typed fields
  (`apiKey`, `baseUrl`, `defaultModel`) or a pasted `callbackURL`; the host
  checks the task is a running sign-in and forwards it to the running
  worker without keeping or logging it; a value that will not do is
  refused `badRequest` naming the field, never quoting it, and the flow
  goes on waiting. `agentSignInCancel{taskID}` is the host's cancel for
  that kind only. `agentAccountList` answers every provider, in kwwk's
  order, with `signedIn`, the method and any `alternativeMethods`, a typed
  key's endpoint host as `account` (its form's default when none was
  given) and `expiresAt` only for a sign-in nothing renews (Devin's
  session) — never a secret; `agentSignOut{provider}` deletes the item.
  The saved API key appears only in the app-only `agentAPIConfiguration`
  reply requested by Edit Configuration; it is never an event or log. No
  refresh token or authorization code is exposed; the device code is the one
  thing the flow shows. A loopback redirect is the URI kwwk registered for
  that provider (Claude's `http://localhost:53692/callback`, Codex's port
  1455, Devin's `127.0.0.1:59653`, OpenRouter's port 53693): kwwk's NIO listener in
  the worker, through kwwk's `loopback` seam (`PasteableLoopback`), answers
  Safari on the same device, and is raced against the redirect address
  pasted from Safari's address bar for a device where it cannot. No
  ASWebAuthenticationSession: the redirect is a plain loopback URI, not a
  scheme the app could claim, and Safari keeps the provider's own sign-in
  cookies. Proven on the Mac by `AccountDeskTests` (fake flows and
  listener, an in-memory store, no secret in any event: a device code that
  is typed and one that is only checked, Kimi's device id, a loopback with
  a paste, a polled page, every key form, OpenRouter both ways, kwwk's
  lists covered); on a device by `Documents/Console/scripts/accounts.json`
  (start, read, refuse and cancel a device code, a loopback, a polled page
  and two key forms; signs nothing in) and, by name,
  `a2-api-key-sign-in.json` (a placeholder key in and out again, which
  replaces the device's openai-compatible sign-in); the real sign-ins by
  hand.
- **Diagnostics** (`Apelind/Dispatch/{Logs,Diagnostics}Handler.swift`,
  `Packages/ApelinDiagnostics/Sources/{ApelinDiagnosticsWorker,ApelinLogReaderWorker}`).
  A `logStream` with a `filter` opens a task on apelin-diagnostics (icli as
  mobile) and answers its first batch; one with `stream` reads on. The worker
  reads its first second before accepting, and answers `denied` when the
  live log is not readable as mobile — only then does the host start
  apelin-log-reader (root) with the same request. Either streams `log`
  events {time, process, pid, subsystem, category, level, message} as they
  arrive, with no gap, for `windowSeconds` (default 30, 1–600) or `limit`
  (default 1000, 1–5000, then `truncated`), then `state` `succeeded`. The
  root reader keeps one LoggingSupport live stream open for the window;
  apelin-diagnostics keeps one icli `SyslogStream` open for it. icli
  filters by subsystem (dotted children), category, pid, message and level
  before anything counts; process (icli's is a substring, Apelin's the
  whole name) and `since` stay Apelin's, and every entry passes
  `LogFilter.matches`. icli's stream ending `interrupted` in the first
  second with nothing heard is `denied`; later, `truncated`
  {`reason: source`}. A streaming call belongs in icli, not beside it —
  `SyslogStream` is that call.
  Crash report ids are file names in icli's three crash directories.
  `crashOpen` is the host's own (open as root, `O_NOFOLLOW`, canonical parent
  equal to one of the three, regular, ≤ 16 MB, read-only descriptor);
  apelin-diagnostics asks it for a report mobile cannot read.
  `crashSymbolicate` decodes the report with ApelinCrash, symbolicates
  against every dSYM in `Builds/<projectID>/` (and the project folder) by image UUID (no image is
  opened by a path a report names) and ranks suspects. `confirmLoaded` is a
  task (kind `confirmLoaded`, read with `confirmLoadedAttach`) the session
  host owns, so the respring it may trigger — which takes the app down, not
  apelind, its session host or the worker — cannot lose the answer. The
  worker checks the request before accepting, then emits `stage`
  {`listening`, `trigger`} and ends with `state` `succeeded`
  carrying the `ConfirmLoadedResponse` as `result` (the check ran; whether
  it found the tweak is `result.loaded`), kept on disk with the task whether
  or not anyone is attached; `ApelinService.confirmLoaded` starts it and
  reads it to the end. The evidence is the marker `ApelinLoaded <buildID>`
  under the package id's subsystem, heard on the live log, which starts
  listening before an optional `trigger: respring` (the host's respring,
  icli's FrontBoard relaunch when the host has none); the live log has no
  history on iOS (icli and the root reader stream only; `OSLogStore` is
  current-process only; there is no `log` tool), so a marker logged at the
  target's launch is seen only with the trigger, or with the target
  relaunched during the window. The filter from `apelin-project.json` is
  checked statically. The image list is **never read** (the evidence says
  `notRead`, naming no iOS version, since it holds on every one): reading
  SpringBoard's image list panicked the iOS 27.0.1
  kernel on 2026-10-17, twice with the task-port read of dyld's image
  infos in place and once more through the region-path walk
  (`proc_pidinfo PROC_PIDREGIONPATHINFO`) alone. Both readers and
  `com.apple.system-task-ports.read` are gone; `imageCheck` still decodes
  and is refused with `badRequest` before the task is accepted
  (`Documents/Console/scripts/i3-image-check-refused.json`). `uiAction` with a
  `targetID` waits up to 3 s for that app, not just any app, to settle as
  the verified foreground app, and runs only then; `tapElement` waits up to
  3 s for its element (icli's `waitForElement`) and taps once; `type` goes
  at icli's own 30 ms a character and answers `typedTextMatches` and
  `fieldValues`, the values the visible elements took on while it went in
  (icli names no text-field role), so lost characters show.
  `press` is `wake`, `home` or `lock` (IcliKit's `pressButton`, `lock` its
  `power`; 2026-10-29). While the device is locked or its screen is off,
  the UI tree and every action but a wake answer `conflict`, saying which
  and that a wake comes first. A wake runs on either and answers what it
  left (`locked`, `screenOff`): a device without a passcode is past its
  lock screen, one with a passcode stays on it for the user to unlock.
  Nothing in Apelin asks for, keeps or types a passcode: not icli 0.11.0's
  `unlockDevice`, nor its `device passcode`, which the `apelin-icli` skill
  tells the agent never to run. IcliKit 0.9.0 already has the press and the
  wake, with the same iOS code as 0.11.0, so the pin stays. An agent's
  action never reaches Apelin itself (`AgentUIActionRules`): the host sets
  its `refusedBundleIDs` to `wiki.qaq.apelin`, whatever the agent sent, and
  apelin-diagnostics answers `denied` for a target on that list, before
  reading anything, and for an app on it in front — on the settled read
  the action is then bound to, verified or not, with no target too. It
  holds in every mode, so no approval or preset lifts it: approving or
  changing a setting stays the user's, and a project is deleted with
  apelin_project_delete (Agent sessions), never by taps. The app's and
  the console's actions carry no list, and the screen and the tree stay
  readable. While a session's Ask Before Using the Screen is on (owner,
  2026-10-30; Approvals ▸ The screen), its agent's tree reads and actions
  go only on the approval naming exactly each. Screenshots go back as an
  unlinked temporary file's descriptor, JPEG.
- **The hello** has a five-second bound per attempt, guarded by connection
  generation, retried every second; the fallback to the unprivileged backend
  comes ten seconds after the first miss (`Apelin/DaemonClient.swift`). After
  it answers, the connection stays open — a connected app is work that keeps
  apelind up — and is said hello to again after it drops. Without the
  backend, calls fail with `backendUnavailable` after one fresh hello.
- **The build number** is passed on the xcodebuild line and never written
  back: CI passes its run number, a local build the commit count.
  `Configuration/Version.xcconfig` holds the marketing version and the number
  an Xcode-run build carries; `make set-version` writes both.
- **The SDK tier** (2026-10-29): the app is linked against the iOS 27.1 SDK
  or later (`IOS_SDK_TIER` in the Makefile). The SDK, not the floor, picks
  how an iPhone Duo treats the app: from 27.1 it runs edge to edge, its
  navigation and toolbar items in one vertical bar beside the content (on
  the outer display and the inner one held sideways), and the safe area's
  sides differ; against 27.0 it stays clear of the status bar's edge, and
  against 26 it sits centred with empty space around it. The floor stays
  `IPHONEOS_DEPLOYMENT_TARGET`. `make build` and `make install-app` refuse
  an older SDK (`sdk-tier`), `_package` reads the SDK back from the
  `Apelin.app` it ships (`vtool -show-build`), and CI runs on the
  `xcode-27` image with Xcode 27.1 selected by name, since that image's
  default may be newer. A layout reads size class and the space it has,
  insets each edge by its own safe-area inset, and leaves bars to the
  navigation controllers; nothing asks whether it is on an iPhone Duo.
- **Strings**: one catalogue, `Apelin/Resources/Localizable.xcstrings`, kept
  the manual way — a key Xcode cannot see stays `extractionState: manual`,
  `make check` refuses `stale`. Prune by hand with Xcode closed, passing every
  source root: `Scripts/prune-xcstrings.py Apelin/Resources/Localizable.xcstrings
  Apelin Apelind Shared Widgets Workers Packages`. Never `--delete-orphans`: the
  project has several targets now. The widget extension is a bundle of its own
  and keeps its own, `Widgets/Extension/Resources/Localizable.xcstrings`, the
  same way; the gates run over both. Apelin ships the thirteen languages the
  sibling apps ship (owner, 2026-10-22): English, Arabic, German, Spanish,
  French, Italian, Japanese, Korean, Portuguese (Brazil), Russian,
  Vietnamese and Chinese (Simplified and Traditional, Taiwan usage), all
  in the project's `knownRegions`. A key goes in with all twelve
  translations, and so does a key of `Apelin/Resources/<language>.lproj/
  InfoPlist.strings` (the camera prompt and the three document type
  names): `make check` runs `Scripts/check-translations.py`, which refuses
  a key missing one. Use the words the siblings already use for the same
  English string — Fila, Irisin, Xrash, iGhostVT and Inspector ship the
  same languages. xcodebuild never merges a new key into a catalog (only
  the IDE does), so a string added outside Xcode is in no catalog and shows
  in English everywhere: `make build` runs `Scripts/check-catalog-keys.py`
  over the app's and the widget's `.stringsdata`, which refuses a key the
  compiler extracted that its catalog lacks (the Model Providers menu's
  "Edit", 2026-10-29). Put each one in by hand, with its translations.
- **Licenses**: the reviewed discipline (`Licenses/README.md`). A dependency's
  notices land in `Licenses/` and `review.json` in the commit that adds it.
  GPL-family text fails the build except for an entry in `review.json` ▸
  `gplExceptions`, keyed by notice id, text hash and pinned revision, with
  the owner's acceptance. There are two (owner, 2026-10-17). libgit2 is
  GPLv2 with the linking exception, its bundled xdiff
  (LGPL-2.1-or-later) a known, accepted item, linked only into
  apelin-environment. z2d, inside libghostty, is MPL-2.0, unmodified and
  linked statically into the app only. Its GPL wording is only MPL
  section 1.12's definition of "Secondary License", and its notice names
  where the source is, per section 3.2.
  `review.json` `excludedPaths` names, per pin, folders its own manifest
  never compiles (libpng and zlib's `contrib`, libpng's `ci`); the collector
  does not walk them. A component compiled from a checkout with no license
  file (BoringSSL in swift-nio-ssl) or kept under a name the collector does
  not walk (icli's ios-mcp notice) gets a `Licenses/<name>/` folder. So does
  vendored source: Runestone (`Runestone`, `tree-sitter`,
  `TreeSitterLanguages`, one `tree-sitter-<language>` per grammar), each
  folder the same text as the `LICENSE` beside the source, which `make
  check` compares. So does every component inside a prebuilt binary the
  app links, found by reading the binary rather than trusting its
  wrapper's LICENSE: each component of libghostty.a (`ghostty`,
  `ghostty-*`, with FreeType taken under the FTL, not GPLv2); and each
  SwiftMath font (`font-*`, OFL-1.1 or GUST), whose `OFL.txt` and
  `GUST-FONT-LICENSE.txt` the collector does not walk. The glyph sets in
  libghostty's embedded Symbols Nerd Font are covered too, one
  `ghostty-nerd-fonts-*` folder per set in Nerd Fonts 3.4.0's
  `license-audit.md`. `binaryRevisions` holds libghostty-spm, so an
  upgrade means reading it again.
- **UI dependencies** (owner, 2026-10-17: bundle everything, package size
  does not matter). The app target alone links DisplayLink, ListViewKit,
  Litext and LitextAnimation, MarkdownView and MarkdownParser, Runestone's
  Runestone, RunestoneLanguageSupport and RunestoneThemeSupport, and
  libghostty-spm's GhosttyTerminal and GhosttyTheme (`upToNextMajor` from
  2.2.2026101502, the same as iGhostVT). Through them come SwiftMath,
  swift-cmark, LRUCache and swift-collections, still the one pin kwwk
  shares. Everything is static, so nothing new is a dylib. The one
  `@rpath` library the app gains is `libswiftCompatibilitySpan.dylib`,
  which Xcode embeds in `Apelin.app/Frameworks/`.
- **Runestone is vendored and trimmed** (owner, 2026-10-17, the way Irisin
  does it): `Packages/Runestone` is simonbs/Runestone 0.5.2 from source,
  from Irisin's copy (the Xcode 27 `TreeSitter.h` fix, typed pointers,
  `EditMenuController`, themes in code), with the Tree-sitter runtime and
  only the grammars Apelin highlights: C, C++, Objective-C, Swift, Bash,
  Python, Ruby, JSON, YAML, Markdown and Markdown inline, XML and Make. The
  last three are upstream tree-sitter-grammars at ABI 14 (Make's parser
  regenerated with the 0.24.7 CLI; README.md there says how).
  tree-sitter-comment and -regex went too: nothing kept injects them.
  `RunestoneLanguage(fileName:)` is the one file → language lookup;
  Logos (`.x`, `.xm`) and `.h` read as Objective-C, a `control` file as
  YAML; `RunestoneLanguageProvider` serves Markdown's fences and a
  Makefile's recipes. The queries are compiled in as string literals, so
  the only resource bundle is Runestone's own `Runestone_Runestone.bundle`
  (theme colours, strings, privacy manifest), which Xcode copies beside
  the executable and the packager requires. The package has no tests:
  it has no Mac build (UIKit), so `make harness` skips it, and a grammar
  of the wrong ABI or a query with a predicate Runestone drops fails
  silently, as plain text. After touching it, put the app on a vphone
  (`make vphone-app`) and open a file of each language it changed, and
  one that injects it, to see them coloured. A grammar put back is paid
  for in the binary: add one as README.md says, with its notice, and
  look at it on the vphone.
  The product links whole whether or not anything imports it (Swift
  metadata keeps `RunestoneLanguage` alive): on 2026-10-17 the shipped
  app binary went from 14.9 MB without Runestone to 30.7 MB with these
  thirteen, Objective-C's tables the largest (5.5 MB of object); the
  xcframework with all 38 languages in use made it 55.0 MB.
- **The root** is laid out as ChatGPT's and FlowDown's (owner,
  2026-10-21): `RootInterfaceController`
  (`Apelin/Interface/Root/`), a container of its own, no
  `UISplitViewController`, with the sidebar's navigation controller and
  `DetailNavigator`, whose picked page — `ChatController` or the icon —
  is the stack's root. The window's horizontal size
  class and width pick the layout, never the idiom or a device's size.
  Regular with room for 340 pt of sidebar beside a page 402 pt wide, an
  iPhone's (an iPad, an iPhone Duo's inner display held sideways): a 340 pt
  sidebar beside the navigator, hidden or brought back by the button first
  on the navigator's bar. Compact, or regular without that room (an
  iPhone, the Duo's outer display, its inner display held upright: 669 pt,
  where the sidebar beside it left the page 329 and, at the 27.1 SDK tier,
  no room for the page's title): the navigator is the screen and the
  sidebar a drawer under it, the window's width less 64 pt (at most 400): the same
  button (`line.3.horizontal`) or a pan to the right on a root page slides
  the page aside, dimmed; a tap or a pan to the left on the shade, VoiceOver's
  escape, or picking or starting a conversation slides it back. A pushed
  page keeps its back button and swipe; the drawer opens from the root.
  While the sidebar is out of sight a New Chat button is last on a root
  page's bar. The sidebar reports what is picked through `onSelect`. The sidebar holds the current project's
  conversations (owner, 2026-10-19, 2026-10-21): its bar is the project's
  name as a plain navigation title at the leading edge (`.editor` style),
  and a plus on the right whose menu (owner, 2026-10-22) is New Chat, as
  the toolbar's, and New Project, as a form sheet. Under
  the bar a search field, hidden until the list is pulled down, filters
  chats ("Search chats"). Its toolbar is New Chat on the left, with the
  Projects folder immediately left of Settings (a gear) on the right.
  The button shows the selected project's icon, or the folder in General Chat,
  with its current selection in the accessibility value. Its uncached menu has
  a fixed order: General Chat, a separator, the project names, a separator,
  and All Projects, which opens the management sheet. The projects are
  listed newest first (owner, 2026-10-30, issue #22; `ProjectMenuOrder`,
  tested in `Tests/ChatTranscript`), a project as new as the latest
  conversation the reader started or wrote in it (`lastInteraction`) or
  its folder's creation, whichever is later: the five newest, and the open
  project wherever it falls, then the rest in a More Projects submenu,
  shown only when there are more. Each row is `Name - Count`
  (`Pineora - 3`; owner, 2026-10-31, issue #28): the name, then how many
  of its conversations show the unread dot, the name alone with none and
  never `- 0`; General Chat counts its temporary conversations and More
  Projects the projects inside it, so one hidden there is still found
  (`ChatUnread.Counts`, one format, `%@ - %lld`). Menu rows have no icons
  except the system's selected checkmark. The toolbar is
  glass on iOS 26 and the toolbar's blur before it. Before iOS 26 the
  accent is black in the light and white in the dark, the window's tint
  and AlertController's (`AppAccent`; owner, 2026-10-22); with Liquid Glass
  it stays the system's blue. With no project open
  the title is "Apelin" alone, with no subtitle (owner, 2026-10-21) and
  no menu, and New Chat starts a temporary
  conversation, as ChatGPT's temporary chat: it belongs to no project and
  is kept in `~/Documents/wiki.qaq.apelin/Temporary/<conversation>/`,
  its working folder too. `agentOpen.temporaryID` names that UUID; the host and worker both check the canonical direct child before using it. Below the bar
  the conversations in the system's inset grouped table, cells and
  headers as they come (owner, 2026-10-21: simple and native), a picked
  row's ground black at 0.1 (white in the dark) rather than the system's
  darker grey — a
  title on one line each, with a system activity indicator at the trailing
  edge while `ChatSummary.isWorking` is true (and "Working" as the row's
  accessibility value), or else a yellow dot while it is unread ("Unread"):
  `ChatRowStatusView`, the spinner's size with the 10 pt dot centred in it,
  so the two share a centre and the title keeps its width whichever shows.
  Unread (owner, 2026-10-31, issue #28; `ChatUnread`, tested in
  `Tests/ChatTranscript`) is `ChatSummary.isUnread`, saved with the chat
  (absent: read) and kept apart from working, which wins while it works.
  A conversation becomes unread when its task brings an assistant message
  with text, an error, a turn's end the reader did not stop (`aborted`) or
  an approval asked while the reader is not looking at it — never from a
  reopened session's replay (`take` reads past it), the reader's own
  message, a title, a queued echo or a count; events read at launch past
  the saved cursor count. Looking at it is `ChatRuntime.viewedChat`, which
  the root sets (`syncViewedChat`): the conversation page is the column's,
  the app is active and no drawer is out over it — an open drawer is not
  looking, so a reply behind it gets its dot, and closing the drawer over
  it reads it; a sheet over the page still counts. Becoming looked at reads
  it, and so does sending in it. `SidebarController.refresh()` reconfigures a row
  whose title, working or unread state changed without changing selection or order; the runtime derives working state from prompt/finished events.
  The saved conversation is restored at launch; an iPhone, or any drawer
  layout, without one creates a new chat only after its project selection
  is restored. New Chat reuses the project's untouched conversation (no
  events, session, draft text or attachments, not pinned) instead of adding
  another empty row, and a launch drops untouched ones other than the saved
  one. Switching projects opens the project's most recent conversation
  without closing a drawer; only a row or New Chat the reader picked puts
  the drawer away. A drawer always has a conversation behind it: an empty
  project, deleting the picked conversation, or a window narrowing onto the
  icon starts one. The drawer's pan yields to content scrolled sideways (a
  code block, a table, the attachments) and to a text selection. Pinned
  conversations come first, the rest under the day the reader last started
  or wrote in each (Today, Yesterday, the weekday
  within the week, then the date), newest first (owner, 2026-10-29:
  `SidebarOrder` by `ChatSummary.lastInteraction`, saved as `updated`).
  New Chat sets that time, on an untouched conversation it reuses too, and
  so does each message the reader sends, a queued one included, the moment
  Send is tapped; nothing the agent or another conversation does changes
  it — output, a title, an approval asked, a message
  `apelin_conversation_send` delivers, a compaction, a reopened session's
  replay —, nor do picking a row, Approve, Deny, Stop, pinning or
  renaming, so the list holds still while conversations work in the
  background. A conversation an agent opened keeps the time the app took
  it in (`ChatAdoption`) until the reader writes in it. A leading swipe pins, a trailing one
  deletes, a long press offers the same actions, and an empty list shows a filled symbol, its
  words left to VoiceOver. Every conversation listed offers Delete,
  whatever it is called or holds (owner, 2026-10-30, `ChatRowAction`: an
  untitled one — a first message on its way, a draft, a pinned New Chat,
  one an agent opened before it had a title — swiped to Stop alone while
  it worked, and at rest to UIKit's default Delete, which does nothing
  here, its swipe answering nil); one at rest goes at once. One still working — a turn, a
  compaction, an approval waiting — has Stop beside Delete, and its Delete
  asks first: Stop and Delete stops the run as Stop does, then deletes
  (`ChatDeletion`). Settings and the picker are form
  sheets through Xrash's `presentAsFormSheet` (`Interface/Components/`). The
  list contains only persisted conversations; no sample conversation is injected at launch.
  `ChatRuntime` owns drafts, session IDs, task cursors and histories; each chat is atomically saved under `Chats/`. A chat is removed from memory only after its session closes (an absent session is already closed) and its file is deleted; later queued saves cannot restore it.
  Projects are read from validated project folders, and the picker refreshes them on appearance. Its swipe and context menu can delete a project after confirming its name: close its chat sessions, remove only its real direct-child directory in `Projects/` without following links, then remove its chat histories. A project whose folder goes some other way — an agent's apelin_project_delete, a command, another app — takes its conversations with it the same way (`DeletedProjects`, `ChatRuntime.forgetDeletedProjects`), at launch and on each change `ProjectCatalogMonitor` reports: banners withdrawn, any session the host left open closed, histories removed, and the sidebar on General Chat when it showed that project; a `Projects/` that does not read takes nothing. With nothing picked the detail column shows
  the app's icon (`NothingSelectedController`) beside the sidebar; behind a
  drawer it is always a conversation. The placeholder cross-fades into a
  selected page, and the first transcript layout jumps to the bottom without
  animating. Never hide a
  `UITabBarController`'s bar to simulate that hierarchy.
  *The conversation page* (`Apelin/Interface/Chats/`, owner, 2026-10-21)
  is made once: the root keeps one `ChatController`, picking a
  conversation hands it over with `use(_:)`, and the navigator shows it
  again only when something else is its root. Switching never builds a
  page: the bar's title — the system's bar, its `titleView` a
  `ChatTitleView` drawing the name in the bar's own headline at the
  default size, `.label`, through Litext's `LTXAnimatableLabel` — rolls to
  the new name with `LTXNumericTransitionAnimator` and its `policy`
  (only on screen; a page coming back shows its name at once); the
  message list is replaced with a new ListViewKit `ListView<ChatMessage>`
  before applying the new conversation's live event rows, without transition
  animations or retained rows from the previous chat; and the
  composer's draft is kept per conversation on disk and put back, so
  nothing typed in one shows up in another. User text sits in a trailing,
  content-sized bubble with 12 pt padding and corners and a 10–15% accent
  gradient, following FlowDown. Its width leaves another 20 pt on each side
  inside the list insets before applying the 800 pt cap; text measurement and
  layout use that same limit. Assistant text uses MarkdownView for headings,
  lists, code, tables and math. Neither MarkdownView nor Litext makes text
  an accessibility element, so `ChatMarkdownView` makes its document label
  one, labelled with the rendered text and each attachment (a list marker,
  a code block, a table) as it would be copied (`spokenText`), worked out
  only for a view in a window, never for the one measuring rows; the view
  stays a container, so a code block's and a table's own controls are still
  reached. Without it VoiceOver, and any reader of the accessibility tree,
  found no reply text at all. Received images use an aspect-aware album with
  2 pt gutters (single, paired, leading portrait and balanced rows); Quick Look
  opens the selected image and pages through its album. `title` is still set, for
  the back button and the window. The title view asks the bar for all
  its room, so its frame holds still while the names roll, and places
  the text itself: centred on the bar as the bar's own title is, slid
  aside only as far as the items need, and cut with an ellipsis (Litext
  has no truncation); it is one header element named by the title. The
  composer (`Chats/Composer/`) is FlowDown's rich editor brought across
  (below, *Lists and rich text*): `ComposerView` stacks its bands
  (`ComposerSectionView`, the text band `ComposerInputView` alone for
  now; the attachments bar, quick settings bar and control panel join
  `sectionSubviews`) on one rounded ground — `UIGlassEffect` on iOS 26, a
  card with a plain layer shadow before it (no ColorfulX) — and publishes
  its height. The text band keeps FlowDown's three layouts (at rest,
  focused and empty, with text: More gives way to Send), return, ⌘
  return and ⌥ return by `ComposerBehavior`, a pasted image or a paste
  over 512 characters handed to the delegate, and its edit menu. Its
  icons are SF Symbols on `ComposerIconButton`, an element with the
  button trait and the name of its action. It
  sits on `view.keyboardLayoutGuide`, no wider than 750 pt and centred in
  the safe area (centred on the page, a vertical bar's inset on one side
  took the same width off the other), on a ground that reaches past the
  page's foot, and the list's bottom
  inset follows it. Its actions reach `ChatController` through
  `ComposerView.Delegate`; Send shows the message at once, a local row
  under the draft's UUID, and empties the composer; the host's `prompt` or
  `queued` event with that id takes the row's place. Until then the message
  is kept on disk (`ChatRecord.sending`), and a launch puts one never echoed
  back in the draft. A failed send removes the row and puts the draft back
  in an empty composer. Only one submission is accepted
  at a time; switching conversations invalidates its completion so a late
  reply cannot touch the incoming draft. More uses FlowDown's inline
  ControlPanel and GiantButton layout, with its camera, photo, file and web
  artwork; it closes on editing, send and conversation changes. The panel's
  published state alone drives the plus/close icon. Items dropped on the
  composer's card (FlowDown's drop, tinted while a drag is over it) are
  read as a pick from Files is, an image as a photo; a folder, a drag from
  Apelin itself or a drop while a request covers the input is refused
  (`ComposerDropPolicy`). Attachments use its
  horizontal preview layout, removal and Quick Look; camera, Photos and
  Files use system pickers, and web text uses FlowDown's ScrubberKit at its
  pinned revision. Live assistant text uses `MarkdownStreamView` with a stable message identity and immediate first fill, so only streaming additions fade in. Each turn is followed while a reader can keep up (`TurnFollowing`): from its user message (a local row just sent, a message a run took, or one another conversation sent) the list follows new output to the end of the turn while the reply streams at no more than 50 tokens a second. The pace is the reply's estimated tokens (`TokenEstimate`: about four ASCII characters to a token, a token to each other character, so Chinese and English both count sensibly) over the time since its first text, judged once a second of it has passed; the first update marks the start and does not count, so neither the first coalesced chunk nor a backlog reads as speed. Faster than that, the turn is followed only until its message reaches the top of the visible area, under the bar's blur, at most a page; the list then holds still while the reply grows below and the downward chevron above the composer shows (Liquid Glass on iOS 26, the system material's blur before it). The chevron scrolls to the latest content once and does not follow again; a drag ends following for the turn, and reaching the bottom does not bring it back: only the next turn does. A message a running turn will take later is shown once on Send and starts no turn until it is taken. The chat header uses a 1 pt private `variableBlur` CAFilter with an alpha-gradient mask on an owned `CABackdropLayer`, following VariableBlur; the old transcript opacity mask and the system top scroll-edge effect are removed. Drafts persist their attachment bytes; submitted and received files are stored in the chat workspace. User attachments sit above the bubble with the same trailing edge. Image previews, PDF first pages and supported Quick Look thumbnails use the same album layout as assistant images; text and other files use document cards with a filename and up to three lines of text, preserving single line breaks and collapsing consecutive blank lines in at most eight passes over the 220-character preview. Each card is capped at the smallest of its natural content width, its user bubble’s width and 350 pt; size labels are omitted. All user attachment previews stay within the maximum user-bubble width. Each image album and document card is at most 30% of the window height; album fitting preserves tile proportions. An album is also no larger than its images (owner, 2026-10-30, issue #20; `MessageImageLayout.frames(aspectRatios:naturalSizes:…)`): shrunk until the image it enlarges least is drawn at its own size, one of its pixels (the original's, read by ImageIO, not the thumbnail's) to each of the screen's (`displayScale`), but no tile under 32 pt on its shorter side, and never larger than those limits, so an icon stays small and sharp while a photo or a screenshot fills the limits as before; an image of unknown size (a PDF page, a Quick Look thumbnail) keeps its album as large as the limits, and a small album's corners round as an icon's. Card borders use the user bubble’s background tint. Attachment changes cross-fade, while ordinary reconfiguration does not. Presentation thumbnails are bounded and cached separately from the original attachment, which remains unchanged for sending, persistence and Quick Look. Ordinary blocks share a 16 pt gap. Unordered, ordered and task-list items use MarkdownView’s independent list spacing with no extra item gap, retaining the renderer’s 4 pt wrapped-line spacing; the transcript normalizer preserves this instead of replacing it with 16 pt. An empty body adds neither height nor spacing. Imports are bound to a chat and draft ID, so a late result cannot
  land in a newly cleared draft. The model control is below the input, with
  the exact FlowDown BlockButton geometry and original editor SVGs, with
  reasoning choices from kwwk's supported-thinking-level metadata; High is
  selected by default when supported. The UI offers only supported Low,
  High and Max levels, never Off. Unknown
  custom models do not get guessed levels. Beside it, Speed (a bolt) offers
  Standard and the faster tiers kwwk's catalog lists for the model
  (`AgentAccount.serviceTiers`: Codex's `priority`, shown as Fast, and
  `ultrafast`); a model that lists none shows no Speed, and Standard sends
  no tier. kwwk also drops a Codex tier the model does not list. Each
  control keeps its own `UserDefaults` value, shared by every conversation
  and restored on launch, and a change notifies every open composer:
  `ComposerModelSelection.current` the provider and model with the
  catalog's last supported-level and tier snapshot; `ComposerModelPreferences`
  the reader's effort and Speed (owner, 2026-10-24: Ultrafast must not
  vanish on its own), written only by the reader's pick. The catalog decides
  what is sent — the saved effort where the model offers it, else High, else
  its strongest; the saved tier where offered, else Standard — never what
  is saved, so a model that lacks a pick, or a catalog that briefly lists
  nothing, leaves it for the next model that offers it. A signed-in account
  whose sign-in did not read this time keeps its model rather than losing
  it to another account's. Return and long-paste preferences
  (`ComposerBehavior`) are also global `UserDefaults` values. Beginning to
  type takes the catalog's levels and tiers for the saved model again.
  Model, effort, Speed and Stop blocks fade and reposition on the composer's spring, including
  when the import panel hides or restores the row; Reduce Motion applies
  changes immediately. `AgentOpenRequest.reasoningEffort` and
  `serviceTier` reach the worker's session configuration. The stop control's icon, text
  and border are red. It takes a
  live output cancellation callback and stays hidden without one. Settings stores a global `AgentPermissions.mode`,
  default relaxed, one of Strict / Relaxed / Full (严格 / 宽松 / 完全), with a
  confirmation when changing into Relaxed from Strict, and, for Full, a
  confirmation that root runs without asking followed by `DeviceOwnerCheck`
  (Face ID, Touch ID or the passcode; a device with no passcode passes);
  leaving Full asks nothing. Under the modes, on the same page, a switch
  keeps `AgentPermissions.asksBeforeScreen`, Ask Before Using the Screen,
  default on (owner, 2026-10-30), its footer saying it covers opening apps
  and links and reading and acting on the screen, by the screen tools or
  icli, in every mode; it rides on every `agentOpen` and `agentPrompt` as
  the mode does. The composer's approval card
  (`ApprovalCardText`) says, under its title, the reason the agent gave the
  call (from its `toolCall`), why the gate asks, a changed description's
  diff, then the arguments by name through the same `ToolCallDetail` the
  trace sheet uses — a shell_run's argv as its command line
  (`CommandLineText`: plain words as they are, the rest single-quoted, a
  character that does not show escaped in `$'…'`, so two argvs never read
  the same). Display only: the approval stays bound to `detail.command` or
  `detail.rootCommand` and `workingDirectory`, and the command and directory
  the card shows are those, never the call's own arguments where they
  differ. It marks a root
  request with a red *Runs as root* line, which stands for the gate's
  sentence and the `root` argument, both left out (VoiceOver reads it; the row's
  accessibility value is "Root Approval Required"), and Approve on it runs
  `DeviceOwnerCheck` before `agentApprove` carries `ownerVerified`; on a
  failed or cancelled check nothing is sent and the request stays pending
  (an `SPIndicator` says so). Deny never checks.
  The runtime reads that mode when opening a session, and reads the global model, effort and tier on each send (changes apply between runs). The transport's explicit approval mode and host safeguards remain authoritative. A single summary groups consecutive thinking and tool steps, with body-size labels at 50% label
  colour; an unfinished thought shimmers unless Reduce Motion is on, a
  finished one names seconds and tool count. Tapping opens a live-updating trace form sheet (`TraceController`; owner, 2026-10-28), the system's inset grouped list with one row per step in order — thought, call, approval —, no icons: a `subtitleCell` titled by the step's kind ("Thoughts", the call's title as the transcript names it, the approval's operation) over one line of its detail (`TraceStep`, tested in `Tests/ChatTranscript`: a thought's start with its white space folded; a call's reason, else its command line, file or pattern, else its result; an approval's decision), each cut to one line, and a disclosure indicator on a step that has more. VoiceOver reads the two lines; nothing labels them again. The row pushes the step's page (`TraceStepController`): a thought's text, a call's arguments and output, or what an approval asked, as plain, selectable body text (Litext's `TextLabelView`, never Markdown) that VoiceOver reads as one element. As the run goes on, steps are added and rows reconfigured in place, a step that did not change is not read again, and an open page takes its step as it grows, where the reader left it; its selection goes only when its step changes. A call's arguments arrive as one line of JSON, so they are decoded for the page (`ToolCallDetail`, tested in `Tests/ChatTranscript`): each argument's name on a line of its own, set smaller in the secondary colour, its value under it — a string as itself, line breaks and quotes and all, so a written file reads as the file, anything else as compact JSON —, the reason first unless it only repeats the title, then the short values, then the long ones, by name within each, and last the result under "Result". Arguments that are not a JSON object show as they came. `TraceBody` builds the text and measures it once per text, text size and width, for `height(for:)` and the layout alike, so a long file is decoded and laid out once, never cut short. Main transcript headers have no icons either, except the count on the turn's latest summary: at the trailing end of its title line, the output tokens the run has received (`received`; `ReceivedTokensView`), grouped as the locale groups them, its digits one width, then a plain `arrow.down` drawn at the figure's font — "653 ↓" at the row's right edge (owner, 2026-10-25) —, both at the title's 50% label colour; right to left the arrow is at the left edge and the figure on its right. The title's first line fades out over 20 pt before it (a mask on the title's own container, the shimmer staying the title's mask), so a long title runs under the count instead of into it. The figure climbs rather than jumps (`TokenClimb`, tested in `Tests/TokenClimb`): straight from what it shows to each new count, arriving five seconds after the count came while the summary runs, and half a second once the reply after it has begun — the transcript keeps the count on the summary above the reply the run is writing (`ChatMessage.receivedSettles`) until the run ends —; it is drawn again at most ten times a second with Litext's numeric roll, starts from nothing when it appears on the same summary, and on another summary, off screen or under Reduce Motion is there at once. It fades in and out with the summary's run, and is the title's `accessibilityValue` ("1,234 tokens received", the count it is climbing to), the view itself hidden from VoiceOver. A session from before the count shows none. Under a running summary, the line of its newest call (Live chat and project UI ▸ `ToolCallBannerView`). Only provider-supplied reasoning
  belongs in those entries. `ChatMarkdownView` uses a 16 pt block gap shared with the gap between cells,
  removes extra heading top space and the trailing empty paragraph so gaps
  match between cells. Pending approvals use `ComposerApprovalSection`
  in place of the input, sharing its rounded background. The draft and
  attachments are preserved while the editor, import controls and model,
  effort and Stop row are hidden. Approval always stacks its content above
  the full-width action row, with equal-width Deny then Approve buttons.
  Both actions have tinted fills; only Approve has a border and semibold
  text. Opening and closing, one card morphs between the input's height
  and the section's on the composer's spring: the section is laid out
  before it is revealed and cut off at the card's edge, never collapsed to
  nothing, the bands it covers keep their own heights while they fade, and
  the model row's blocks keep theirs, so nothing inside is squeezed; the
  section keeps its text through its fade-out, and a request replacing
  another cross-fades its text. Approvals appear only in the trace, as a row naming the operation over its decision. The next pending request replaces the section; it collapses
  after the last decision. Test conversations are temporary fixtures created and
  removed by the test driver; no preview-only approval or Stop handlers ship. `updateMessages`
  follows a turn's output to its end, or for at most a page when it streams
  faster than 50 tokens a second, and never after a drag; a
  keyboard or composer height change keeps a reader at the latest message
  there and leaves any other where it was. A reader at the latest message when the page changes width (the
  sidebar opening or closing) is kept there while the rows wrap again and
  are measured, until a drag. A reader anywhere else is put back on the
  line they were reading (owner, 2026-10-30; `readingPlace`): the row the
  line under the bar crosses and how far into it, taken before the list
  takes the new width and set again once that row is measured at it, so a
  long reply that wraps taller or shorter around the reader does not carry
  the text they were on off the screen; a drag or another conversation
  forgets it. The message list is explicitly registered as the
  navigation bar's top content scroll view. `ChatTopBlurView` owns the masked
  backdrop and a matching page-color frost behind the status bar and navigation
  controls: radius 1 pt, linear alpha mask, linear page-color frost from 1.0
  to 0, and height equal to the top safe area plus 20 pt. The system top edge
  effect is hidden on iOS 26. Image albums use
  the user bubble's accent gradient with a 1 pt inset and concentric continuous
  corners; that inset is included in their width and height limits. Transcript
  rows do not clip selection handles. Text selections retain the system menu;
  a system response with only Copy/Select All receives Look Up, Share and,
  from iOS 17.4, the public translation presentation.
- **The sibling wheels** (owner, 2026-10-17): the app target, and only it,
  links the toolkit Irisin, Fila, Xrash and iGhostVT share, with Irisin's
  pins and requirement shapes (`upToNextMajor`), all static, so that code
  ported from them compiles as it is. One reason each:
  *SPIndicator* 1.6.5 is the floating one-line confirmation ("Copied",
  "Deleted") every sibling shows; UIKit has none, and one by hand is a
  window, a queue and haptics. *AlertController* 3.0.0 is the siblings'
  alert, with input fields and progress, which `UIAlertController` cannot
  host; it runs `String(localized:)` on every title and message, so pass
  it catalogue keys, never already-localized text. *Then* 3.0.0 is the
  `.then {}` the siblings' view code is written in. *SnapKit* 6.0.0 is
  their Auto Layout DSL; `remakeConstraints` and `updateConstraints` keep
  each view's constraints in one place where anchors would leave them to
  be tracked by hand. *SwifterSwift* 8.0.0 (the `SwifterSwift` product,
  the only one) was asked for by the owner; never add an app extension
  with a name it already has, or the call becomes ambiguous. *Dog* 0.1.2
  is the siblings' persistent journal: the live log keeps no history on
  iOS, so a file is the only record of an earlier launch a user can send.
  Not taken: SDWebImage and ScribbleLetterView, which nothing needs yet,
  and GlyphixTextFx (owner, 2026-10-17): Litext's animated text covers
  the same `numericText`-style transition.
  **Dog's journal** is `~/Documents/wiki.qaq.apelin/Journal/Dog_<date>_<id>.log`:
  `AppJournal.start()` calls `Dog.shared.initialization(writableDir:
  DataFolder.app.root)` once, early in `didFinishLaunching`, after making
  `Journal/` with `makeLevels` (so a missing data folder is an NSLog line,
  never a folder Dog makes), and writes a launch header, its paths through
  `AppJournal.redaction` (`~`, `<install root>`). `DataFolder.app`,
  not `DataFolder(home: NSHomeDirectory())`: on roothide `NSHomeDirectory()`
  is the system's `/var/mobile`, not the bootstrap's. Never call it with no
  argument: its default is `.documentDirectory`, which for an app with no
  container is mobile's shared `~/Documents`, and the journal would land in
  `~/Documents/Journal`. Dog keeps 128 files by default and mirrors every
  line to the unified log under its own subsystem, `com.lakr233.dog`. It
  is the app's alone: apelind and the workers never link it and keep their
  own logging, and no task, scope or operation reads the journal.
  Settings ▸ About ▸ Logs (`Apelin/Interface/Settings/Logs/`) reads it
  back: every launch Dog keeps (`JournalFiles`, tested by
  `Tests/Journal`), this one first, each opening Irisin's log page
  (`LogViewerController`: level and category filters, Errors Only, a search
  field over each entry's text — a call ID finds its call —, Share as
  a `.log` file, row Copy; the running launch is followed and can be
  Cleared from view); an earlier launch's file can be deleted. Under it,
  Chats lists the agent's journal of each conversation (Agent sessions ▸
  the diagnostic journal; owner, issue #27), written last first, named by
  the conversation the runtime has for its session (else by when it was
  last written), read with its rotated file first and deleted with it.
  The app's journal itself has one line, category `Conversation`, for each
  problem it sees arrive in a conversation (`ConversationJournal`): an
  `error` event, a `compactionFinished` that failed, a Compact… that could
  not be asked for, with the session, redacted (`LogRedaction`); a
  reopened session's replay, which `ChatRecord.take` reads past, adds
  none. The parser is `JournalLines`, Foundation only, which
  `Tests/Journal` feeds what apelin-agent's `DiagnosticJournal` writes.
- **Release notes** live in `Documents/Releases/<version>.md`, written before
  the tag.
- **Before every push, tag or release**, an agent reads the diff, the staged
  payload tree and `strings` of the built binaries for credentials, private
  keys, home or scratch paths, device identifiers, hostnames and addresses.
  Nothing goes out until it comes back clean. No device hostname, serial, UDID
  or LAN address goes into docs, commit messages or release bodies.

### Projects and builds (apelin-build, 2026-10-17)

- **Documents** (`ApelinProject`) go through `StrictJSON` (UTF-8, no BOM,
  no duplicate member, integers only within ±(2^53−1)), then the schemas
  themselves, embedded by `Packages/ApelinKit/Scripts/embed-schemas.py` and
  held to `Documents/Schemas/*.schema.json` by a test, then the rules beyond
  them — `Documents/Schemas/Tools/apelin_schema.py` ported message for
  message. Canonical JSON and both approval digests are byte-identical to
  it: the fixtures, the edit table, and every shipped template instantiated
  by both and compared file by file are in `ApelinProjectTests`.
- **The written form** (owner, 2026-10-31, issue #30; `ProjectManifestFormat`,
  the reference's `manifest_text`, Documents/Schemas/README.md ▸ Written
  form): every writer of `apelin-project.json` writes it as
  `json.dumps(document, ensure_ascii=False, indent=2)` and one `\n` —
  two spaces a level, one member or element a line, members in their
  written order, `{}`/`[]` inline, only the escapes JSON needs — so it
  reads on GitHub and in a diff: `projectCreate` (the generated manifest,
  and the empty workspace's), the rename, the transfer import and
  apelin_project_set_environment. Only the text changes: the document read
  back is the one the file held, order included, so neither approval digest
  moves (the edit table's "written on one line" and "formatted from one
  line") — unless the project takes the manifest as a file of its build or
  package, whose bytes the packaging digest covers; a file the strict
  reader refuses is left as it is, and one already in the form is the same
  bytes. Every build puts the manifest into the form before its first step
  (after the check of a described project, before a workspace's script),
  says so in one line of its log, and writes nothing when it already is,
  when the check digested it as a file (`checkedFiles`), or past 1 MB, the
  most the other readers take: through the opened project folder, which
  must itself be no link, never through a link, opened non-blocking until
  it is known to be a regular file, mode and owner kept, only while it is
  still the file read (`ProjectManifestFile`, the rename's writer). The one-line files came
  from the rename, which wrote the whole manifest compact
  (`JSONDocument.description`), and from the empty workspace, written
  compact and sorted by `JSONCoding`. `Fixtures/manifest-format.json`
  holds both implementations to it. The template files are not JSON before
  substitution and keep their layout; the file tools write what the model
  writes, and the next build tidies it.
- **Extensions** are scanned from `<install root>/usr/share/apelin/development/`
  on every `extensionList`; each is checked alone and a bad one, or both of
  a duplicate id, is listed with its problems and never offered.
- **projectCreate** stages beside `Projects/<name>/` (`.<name>.creating-…`)
  and moves in with `renamex_np(RENAME_EXCL)`. Apelin supplies `projectName`,
  `projectID` and the `template*` values; `bundleID` and `packageID` default
  to `local.apelin.<name as a slug>`, an `identifier` parameter named
  `productName` to the name's words joined and capitalised (`I3 Chain Tweak`
  → `I3ChainTweak`, so two projects never install the same file),
  `deploymentTarget` to 16.0,
  `architectures` to the manifest's, toolchain and SDK to the registry's
  defaults. The answer carries `descriptionDigests` {build, packaging},
  which the session host's approval ledger records as the template baseline
  for that project ID, and `baseline` (`ProjectBaseline`: the same digests
  with both descriptions' canonical JSON and the template, for a diff);
  nothing in the project folder holds either. `projectCheck` answers
  `descriptionDigests` of the project as it is now, absent when a
  description cannot be computed. With `purpose: distribution` (and an
  optional `bootstrap`) it adds `distribution.*` warnings (`DistributionCheck`
  in ApelinBuild: template placeholders, the template's first version, a
  `local.apelin.` identifier, an app without an icon, a version already
  packaged for the target), never an error; the distribution page and the
  agent's `apelin_project_check_distribution` tool read them (`Documents/Distribution.md`).
  Its answer carries the `environment` binding it checked; with
  `environment` {toolchainID?, sdkID?} in the request it checks the
  project as if bound to those registered components instead — digests
  the registry's, an unregistered one `notFound`, nothing written; a
  project file that does not read answers its own check, with no
  binding — which
  is how the agent's apelin_project_set_environment is judged before it writes
  (`ProjectCheck.binding`, `run(projectID:environment:)`).
- **The environment** apelin-build reads through `EnvironmentRegistry`
  (`ApelinProject/Environment`); on the device that is `EnvironmentStores`,
  apelin-environment's own files read as they are — `Environment/Toolchains/registry.json`
  and `SDKs/.registry/<id>.json` — without linking ApelinEnvironment. A
  toolchain's binding digest is `sha256:` + its `contentDigest`, an SDK's
  `sha256:` + its tree `digest`; a component counts only if its self-check
  passed; tools are `<path>/usr/bin/<tool>` (or the CLT's
  `Library/Developer/CommandLineTools/usr/bin`). A project builds only
  against the toolchain and SDK whose ID *and* digest it is bound to.
- **A build** (`ApelinBuild`) has one ID: the host's task ID, which is
  `APELIN_BUILD_ID`, the artifact ID and what `confirmLoaded` takes. Its
  layout comes from the assignment — mobile's home inside the install root
  is roothide, otherwise rootless — and it builds only that one. Outputs live
  in `~/Documents/wiki.qaq.apelin/Builds/<projectID>/<buildID>/` (objects,
  slices, products, dSYMs, `build.log`, the deb), never in the project. Tools
  are the registered toolchain's `usr/bin/<tool>`, posix_spawn'd by argv,
  stdin `/dev/null`, `POSIX_SPAWN_CLOEXEC_DEFAULT`, a process group each
  (cancel kills the group). clang gets `-isysroot <SDK>`, `-arch`,
  `-mios-version-min`, `-O`, `-g`, `-fobjc-arc`, `-Wall -Wextra`,
  `-Werror=unguarded-availability-new`, `-fvisibility=hidden`,
  `-ffile-prefix-map=<project>=.` and the `APELIN_*` defines, run in the
  project folder with relative sources. Signing is `ApelinCodeSign`, no ldid:
  byte for byte what `ldid -Hsha256 -S[entitlements]` writes. It is the one
  signer: the toolchain retarget (`Packages/ApelinToolchain`,
  `MachOImage.signed`) lays out its own slice but builds the blobs with the
  same `LdidStyleSignature` and `LdidEntitlements`, which Irisin's seven
  device fixtures there hold too; never a second copy. Script steps
  run with the bootstrap's own interpreter, in the project folder, as
  mobile; Confirm reviews them through the build digest before `buildStart`.
- **Its task events**: `stage {stage, product?}`, `log {line}`, `diagnostic`
  (a `ProjectDiagnostic`; clang and ld lines parsed to file, line, column,
  severity), `artifact` (a `BuildArtifact` with `path` — the deb, inside
  `~/Documents/wiki.qaq.apelin/Builds/` —, `projectID` and
  `packagingDigest`, which the host's ArtifactRegistry records), and a final `state` that, on
  success, also carries `artifactID`, `digest`, `buildID`, `packageID`,
  `version` and `bootstrap`.
- **The artifact** is registered at `~/Documents/wiki.qaq.apelin/Builds/artifacts/<artifactID>.json`
  (`ArtifactRecord`): the deb's path and `sha256:` digest, both description
  digests as built, the products with their digests and UUIDs, the dSYMs,
  the regular files and links the deb installs as dpkg lists them
  (`packageFiles`, fewest components first, at most 256), read back from
  the deb by both builds,
  and `loadCheck` (`BuildLoadCheck`: marker `ApelinLoaded <buildID>`,
  subsystem the package ID, the dylib and its filter plist — `<dylib name>.plist`
  beside it — logically and under this install root, the filter). The file
  is mobile's: `installPackage{artifactID, digest}` copies the deb to the
  host's private staging and refuses it unless the copy's digest is the one
  asked for.
- **The deb** is written by `DebPackageWriter`, never dpkg-deb: the logical
  layout through `PackageLayout`, `Depends` from `firmware (>= deployment
  target)`, `depends` and `dependsByBootstrap`, `Icon` after `Name` from
  `package.icon` (an https URL, none without it), maintainer scripts with
  `@PREFIX@`/`@ROOTFS@` filled and `sh -n` passing, `control.tar.gz`
  (`controlCompression = .gzip`, which the host reads) and `data.tar.zst`. ApelinDebArchive brings
  `libarchive.xcframework` into apelin-build, reviewed in `Licenses/`.
- **Workspace builds** (owner, 2026-10-23: an imported repository stays
  external and keeps its own build; it is never converted to a description).
  A workspace declares one script in its manifest, `"external": {script,
  interpreter?, arguments?}` (`ExternalBuildDeclaration` in ApelinProject:
  a regular file inside the project by canonical path, `sh` by default or
  bash, zsh, python3, perl, at most 32 one-line arguments, nothing else).
  `buildStart` on a workspace runs it in apelin-build (`ExternalBuild`),
  the manifest in its written form first (The written form, above): as
  mobile in the project, the bootstrap's interpreter, stdin closed, its own
  process group, 30 minutes at most (a cancel or the timeout kills the
  group), the output the build log; with the development environment
  shell_run gets and `APELIN_BUILD_ID`, `APELIN_BOOTSTRAP`,
  `APELIN_ARCHITECTURE`, `APELIN_PREFIX`, `APELIN_CONFIGURATION`,
  `APELIN_PROJECT_ROOT` and `APELIN_PACKAGE_DIR`, a fresh folder in
  `Builds/<projectID>/<buildID>/`. Exactly one regular `.deb` there, whose
  control names a Package, a Version and the bootstrap's Architecture,
  becomes the artifact (`ArtifactRecord` with `buildSystem: external`, no
  build digest, binding or template), reported by the same `artifact` and
  `state` events, so installPackage, removal, crash lookup and
  confirmLoaded work as for any build; Apelin neither compiles, signs nor
  packages for it. Its packaging digest is cut from the package
  (`apelin.external-packaging`: the control file but `Version`, every
  other control member's digest, each data member's path, kind and mode),
  so an install asks once and again only after one of those changes.
  confirmLoaded reads a workspace build's load check from its record (one
  dylib in MobileSubstrate's folder with its filter beside it). A
  workspace's `projectCheck` answers `buildSystem: external`, no digests,
  and passes when the declaration reads. Under Confirm the host lets an
  agent's workspace build through only by spending an approval the app
  gave that session for exactly it (`detail.externalBuild` {projectID,
  configuration, bootstrap?}, `AgentExternalBuildRules`): one approval
  builds once, never for the session, since the script runs whatever the
  repository holds. ManagedPackagePolicy still refuses installing over a
  package Apelin did not install. A workspace is distributed like any
  project (owner, 2026-10-24): a release build per bootstrap, its package
  exported from the distribution page. Having no description to check
  before, the release build reads the package it wrote
  (`DistributionCheck.packageFindings`) and reports `distribution.*`
  warnings: a `local.apelin.` identifier, a version already packaged for
  the target, a package other than the other target's latest release.
  apelin_project_check_distribution counts any check error as not ready and, for a
  workspace, notes that the build checks the package. Tested by
  `ExternalBuildTests` (the declaration, the script's environment, one
  package, the failures, the timeout, the release findings, a workspace
  rewritten as a description), the agent's
  `ExternalBuildToolTests` and the session host's approval checks.
- **Tested** by `make harness`: the schema fixtures and the reference
  implementation, `ApelinCodeSign` against ldid's own output
  (`Packages/ApelinFormats/Tests/ApelinCodeSignTests/Fixtures/build.sh`), and
  the tweak template built with Xcode's tools and iPhoneOS SDK into a
  roothide and a rootless deb read back by dpkg-deb, codesign and ldid. On a
  device: `Documents/Console/scripts/i3-chain.json` (create → check → build →
  install → confirmLoaded with `trigger: respring`; delete
  `Projects/I3 Chain Tweak` before running it again).
- **Distribution repository** (owner, 2026-10-25;
  `Operations/Distribution.swift`, `ApelinEnvironment/Distribution/`,
  `Apelind/Dispatch/DistributionHandler.swift`,
  `Apelin/Interface/Settings/Git/DistributionRepository*`). The user's own
  package repository: a GitHub repository of theirs that GitHub Actions
  indexes and GitHub Pages serves as an APT source
  (`https://<owner>.github.io/<name>/`), laid out after
  owngoal-dev/owngoal-packages trimmed to committed packages
  (`DistributionTemplate`: `debs/`, `depictions/`, `index.html`,
  `CydiaIcon.png` (Apelin's icon), `sileo-featured.json` (a file name
  Irisin reads too), `scripts/update-repository.sh` indexing `debs/` with
  apt-ftparchive and drawing the home page's QR code with qrencode for the
  address `configure-pages` answers, and
  `.github/workflows/update-repository.yml` building and deploying Pages
  on every push to the repository's branch). The home page is the
  repository's card as the app draws it, centred, with Open in Irisin…
  under it; everything the template writes points to Irisin alone (owner,
  2026-10-26: no Sileo or Zebra).
  apelin-environment serves it, holding the github.com sign-in: GitHub's
  API (`GitHubAPI`: the account, its own repositories, creating one, Pages
  with `build_type: workflow`) is called with that token, and the clone
  fetches and pushes with it as any remote does. Its clone is an ordinary
  workspace project, so its conversation maintains it with the file and
  git tools (the `apelin-package-repository` skill); the link is
  `Settings/distribution.json`, read only while its project is there.
  `distributionRepositoryCreate{name, owner?}` (a task: `creating`,
  `preparing`, `pushing`, `publishing`) makes a public repository — on the
  account, or in the organization `owner` names (`POST /orgs/<owner>/repos`),
  which the app asks for first when the account has any —, the project with the
  template, its first commit and push, then Pages, and links it; once
  GitHub has the repository a failure says Link finishes the setup.
  `distributionRepositoryLink{fullName}` (`fetching` first) takes the
  project whose origin it already is, else clones it into a new workspace
  — an empty repository is set up as a new one —, adds the template files
  it lacks without overwriting any, commits and pushes those, switches or
  turns on Pages and links it. With `overwrite` (Update Repository…, after
  a warning that it replaces them) it also replaces the files the template
  maintains (`DistributionTemplate.maintained`: the home page, README,
  icon, workflow and index script) whose bytes differ, by a rename over
  each, never through a link; packages, depictions and banners are left. A Pages refusal (a private repository on a
  free plan) is a warning; the repository is set up either way.
  `distributionPublish{files, digests?, repository?}` (`fetching`,
  `preparing`, `pushing`) takes `.deb` files under the data folder's
  `Builds/` (≤ 16, each ≤ 100 MB, which GitHub caps) and needs the
  github.com sign-in, fast-forwards the clone, copies each into the task's
  staging while it is hashed — a file whose bytes are not its `digests`
  entry (`sha256:<hex>`, one per file, else `badRequest`) is `conflict` —,
  names it from that copy's control file as
  `<Package>_<Version>_<Architecture>.deb` (the epoch's colon `%3a`, as
  dpkg-name spells it; two of one name `badRequest`) and judges every name
  in `debs/` — the same bytes again are skipped, other bytes under that
  name `conflict` — before the first goes in, so a refusal publishes none;
  then commits "Publish …" and pushes, a push made even when every package
  was there, which sends a commit an earlier push failed to. A
  `repository` that is not the one linked is `conflict`. The agent's
  apelin_package_publish (Agent sessions) sends both fields.
  `distributionRepositoryList{repositories}` answers the account, the link
  and, asking GitHub, the repositories it can push to, its own and its
  organizations', with those organizations (`/user/orgs`, which the `repo`
  scope may not fill, and every organization owner the list names);
  `distributionRepositoryUnlink` forgets the link only. Its card (Repository
  Card…, `Apelin/Interface/Settings/Git/RepositoryCard/`) is a badge the
  Camera scans to add the source in Irisin: icon, title, the source address,
  a QR code of `irisin://repository/add?url=<source address>` (Irisin's
  `IrisinLink`) and `@<owner>`, every line the body size in SF Rounded,
  bold or regular at half opacity, always light. Save writes it to Photos
  (`NSPhotoLibraryAddUsageDescription`); `…` opens the source in Irisin on
  this device (nothing under the card: an iPad's form sheet has no height
  for it), chooses the icon and edits the title, kept per repository in the
  app's defaults. The app's alone, but for a publish an agent's session
  may start as `AgentPublishRules` allows (CallerPolicy); their tasks are
  not resumed. Settings ▸ Git ▸
  Publishing and the GitHub welcome page create or link one; the
  distribution page's Publish to Repository (the release packages picked
  under Packages, both targets in one commit) and the build page's
  Distribute ▸ Publish to Repository publish verified packages, and with
  none linked open Settings at its Git page instead. Tested by
  `DistributionTests` (a fake
  GitHub and bare repositories on disk: create, link with a file of the
  user's kept and a branch-built site switched, an empty repository,
  publish once and refuse a changed package, a digest that differs and
  two of one name publishing nothing, an earlier commit pushed, the
  refusals); on a device by
  `Documents/Console/scripts/distribution.json` (refusals, unlink and a
  read of the star: nothing is written to GitHub).
  *Feedback* (owner, 2026-10-29; `Operations/Feedback.swift`,
  `ApelinEnvironment/Distribution/FeedbackService.swift`). `feedbackSend
  {title, body}` files a public issue on Apelin's own repository,
  `FeedbackRules.repository` (owngoal-dev/Apelin, never one a request
  names), with the same github.com sign-in (`GitHubAPI.createIssue`); one
  request, not a task. apelin-environment checks the text first, before
  the sign-in is read: a title of one line of at most 120 characters, a
  body of at most 16 KB, and none of the shapes `FeedbackRules` refuses —
  a token or key, a home or install path (mobile's home, the install root
  as the host gave it, roothide's `.jbroot-`, an app container), a local
  address or `.local` name, the device's own host name, a UDID, serial or
  MAC address — `badRequest` naming the kind, never quoting it. The check
  reads shapes and proves nothing; Strict showing the whole text is the
  safeguard. Below the body it writes the footer itself, "Sent with
  Apelin <version> (<build>) · iOS <version> · <bootstrap>", the version
  from `<install root>/Applications/Apelin.app/Info.plist` (`BoundedFile`)
  and no model, name or identifier. Without a sign-in, `denied` with
  reason `authenticationRequired`. The app's and the agent's, as
  `AgentFeedbackRules` lets it through. Tested by `FeedbackTests` and
  `FeedbackRulesTests`; the console's `distribution.json` sends an empty
  title, refused before anything reaches GitHub.
  An issue there is read and, when the signed-in account opened it,
  edited (owner, 2026-10-30): `feedbackRead {number}` answers {number,
  url, title, body, footer?, author, state, isAuthor}, the body split from
  the footer it ends with (`FeedbackRules.split`, `\n` or GitHub's `\r\n`);
  a pull request, or an issue GitHub moved elsewhere (its `html_url` not
  this repository's), is `notFound`. `feedbackEdit {number, title?, body?,
  expectedTitle, expectedBody}` checks only the fields that change
  (`FeedbackRules.editProblem`: the same shapes, a body ending in a
  footer refused, nothing changing refused) before the sign-in is read,
  refuses another account's issue `denied`, reads the issue again and
  writes nothing unless its title and body are still exactly the expected
  ones (`conflict`), so an edit the user made on GitHub meanwhile is never
  overwritten; then it `PATCH`es only those fields, the footer kept below
  the body as it was, never written again with this device's version.
  Answers {number, url, title, body}. Both the app's and the agent's.
  Tested by `FeedbackEditTests`; `distribution.json` reads issue 0 and
  edits a title to nothing, both refused before GitHub.
  *The star* (owner, 2026-10-29; `Apelin/Interface/Feedback/`). Once the
  reader has signed in with GitHub, builds that complete ask "Do You Like
  Apelin?" — "Please star us on GitHub. It helps us go further.", Maybe
  Later (下次一定) beside Star Now (立即标记) — and Star Now stars
  `FeedbackRules.repository` with that sign-in (`feedbackStar`,
  `PUT /user/starred/…` with an empty body), then says Thank You, or
  GitHub's refusal in a notice. `StarPromptState`, kept as JSON in the
  app's defaults, paces it: after ten builds, again ten builds after each
  Maybe Later, three times at most; Star Now ends it for good, whatever
  GitHub answers. `StarPrompt` counts only builds that complete while
  `gitSettings` names a github.com sign-in: each apelin_project_build
  result a conversation reads for the first time whose answer says
  `succeeded` (`CompletedBuilds`, so a reopened session's replay counts
  nothing again) and each distribution build. When an ask is due it reads
  `feedbackStarState` in the background (`GET /user/starred/…`, 404 being
  no star), at most once a day, and an account that has starred Apelin is
  never asked. While the app is in the background, an alert or a
  presentation is coming or going, the read fails or UIKit does not take
  the alert, it asks nothing and waits for a build on a later day. Both
  operations are the app's alone, no worker's (CallerPolicy), and the
  console refuses `feedbackStar` before sending it: a star on the
  reader's account comes only from their tap. Tested by `FeedbackTests`
  (the read, the empty PUT, the sign-in), the console's tests, and
  `CompletedBuildsCheck` and `StarPromptStateCheck` in the transcript
  harness.

### Product (decided 2026-10-16)

- **Toolchain**: no Apple binary is redistributed and no LLVM is built.
  The device fetches Apple's Command Line Tools package itself (no Xcode, no
  Apple ID), unpacks it and retargets the tools to iOS on the device — the
  platform, the flattened framework paths, the Swift shims, the signature.
  The tools being retargeted are macOS binaries, so that editing is our own
  code, not `vtool` or `install_name_tool`. Exporting a retargeted toolchain
  and importing one sent from elsewhere is a transfer file (`.apetc`,
  Decisions ▸ Transfer files), user to own device.
- **Swift** is in v1, optional at toolchain setup; templates default to ObjC.
- **SDK**: the Command Line Tools carry no iPhoneOS SDK. The SDK manager
  downloads one from `owngoal-dev/iOS-SDKs` — a detached fork of
  `xybp888/iOS-SDKs` we maintain and credit, one SDK per branch — or another
  source the user adds, or takes a file, identifies it from `SDKSettings.json`
  and its `.tbd` targets, and registers it. No Apelin package carries an SDK.
- **Git** is libgit2, built and kept as `Lakr233/libgit2.xcframework` the way
  `Lakr233/libarchive.xcframework` is.
- **Agent**: option C — the session host spawns `apelin-agent`, running as
  mobile and linking KWWKAgent; the app renders its structured events.
- **Credentials** live in the keychain, this device only, never synced, in
  Apelin's own items; nothing is shared with kk or `~/.kwwk`. Exporting a
  signed-in state comes later.
- **Approval** has three modes (owner, 2026-10-24). *Relaxed* runs everything.
  *Confirm* lets every
  edit inside the project through — never one in a git directory, which no
  mode writes —, plus a preset list of reads and commands
  (respring among them); any other system tool or binary is confirmed at
  every step. Under *Confirm*, a build or install whose build or packaging
  description matches the project's template runs without asking; a changed
  one is reviewed on its first run after each change, the approval bound to
  that description's digest and kept by the session host. A toolchain
  setup or an SDK import asks every time, and so does any conversation
  call that reaches another project, and so does deleting another project
  (owner, 2026-10-29), and so does publishing packages to the user's
  package repository (owner, 2026-10-29), and so does editing a feedback
  issue or opening an issue on a repository the user chose (owner,
  2026-10-30), and so does squashing the project's own commits (owner,
  2026-10-31); none is ever granted for the
  session, and the host spends the one approval (owner, 2026-10-22). An
  MCP tool and an agent tool extension's tool ask at every call too,
  whatever the extension declares its risk to be; those two may be
  granted for the session.
  Switching a project's toolchain or SDK is a project edit. The UI and the
  agent call *Confirm* Strict (严格模式; owner, 2026-10-22); `ApprovalMode.confirm`
  and every stored or wire value keep the name.
  *Full* (完全) is Relaxed plus one thing: a `shell_run` as root runs without
  asking. A command as root (`shell_run` ▸ `asRoot`) is the one thing Relaxed
  and Strict both ask about, every time, on a card that says *Runs as root*;
  Approve on it is answered only after LocalAuthentication's
  `.deviceOwnerAuthentication` (Face ID, Touch ID or the passcode) passes, or
  the device has no passcode — Deny needs none —, and the host takes the
  decision only with the app's `ownerVerified`. A root command is never a
  preset and never granted for the session; the host runs it only in Full,
  or against one single-use approval bound to that exact command and
  directory as a *root* request (`detail.rootCommand`, never
  `detail.command`). Root is for a step of the user's task that needs uid
  0 (owner, 2026-10-30): a dependency install (`irisin-cli install --yes
  <id>`), irisin-cli's questions and `--dry-run --yes`, which Irisin answers
  only as root (apelin-package-dependencies skill), or another step only
  root can take — never the project's own build, install, removal or a
  respring, never to get around a refusal or an approval, never Apelin's,
  Irisin's or the bootstrap's own packages. The prompt has the agent say
  first what a root call runs and why, request root when the user asks it
  to, and, in every mode, Full included, make a change outside the
  project (deleting, overwriting or moving files, a system or bootstrap
  setting, a launch daemon, another package) only with the user's
  explicit go-ahead for exactly it. Switching into Full is a confirmation that
  says root will run without asking, plus the same owner check; leaving it
  asks nothing. The wire value is `full` and old stored values still decode;
  `ApprovalMode.asks` is true for Strict alone.
  *A forced push* (owner, 2026-10-31, issue #29: "default protected,
  allowed with explicit authorisation") asks in all three modes, Full
  included, every time, on a card naming the branch and remote, the
  commit replaced and the one sent, and the commits that leave the
  branch; never granted for the session. It goes with
  `--force-with-lease`'s protection, never a plain force: if the remote's
  branch is not where the card said, nothing is pushed and the user is
  asked again.
  A reset of the project to a remote (git_reset_to_remote, owner,
  2026-10-31, issue #32) asks in every mode, Full included: it discards
  local work, so its card names what is lost, it is never granted for the
  session, and what it discards goes first onto an `apelin-backup/…`
  branch.
  *Ask Before Using the Screen* (owner, 2026-10-30: asked to
  report a problem upstream, an agent opened the issue page in Safari with
  `icli url open` and read the UI tree twice, never asking) is a setting
  beside the mode, on by default, that holds in all three: while on, the UI
  tree, every UI action and every `shell_run` that runs icli (or uikittools'
  `uiopen` or `uishoot`) ask on a card every time, whatever the presets or
  the icli subcommand, never granted for the session, and the host runs
  each only on the one approval given for exactly it. A request to do a
  task is no consent to open an app, read the screen or act on it: the
  prompt has the agent say what it will open, read or do and wait for the
  user's reply first. Off, those calls go as the mode says. Screenshots
  stay the conversation's rule (2026-10-29).
- **Install** always packages a deb and hands it to Irisin's daemon. irisind
  is changed to accept a peer by its entitlement and an executable under the
  jailbreak root or the system, not by Irisin's own path, and ships in a new
  Irisin release; Apelin depends on that version and installs through it
  from there on. No CLI, no symlinks into the load directory. Nothing in
  Apelin couples to the `apt` or `dpkg` binaries: both are on their way out.
- **Reuse before writing**: everything the five sibling apps already do comes
  across — iGhostVT's terminal, log viewing, Fila's binary parsing and its
  file-descriptor editing through the privileged process, Irisin's signing —
  taken as is where it fits and changed where it does not.
- **In v1**: everything that can be wired in, the terminal and git included.
  Not clangd: the editor is basic editing on Runestone (vendored,
  `Packages/Runestone`), with no completion, hints or jump-to-definition.
- **Projects** live in `~/Documents/wiki.qaq.apelin/Projects/<name>/`, nowhere
  else.
- **Diagnostics** use `owngoal-dev/icli` for everything it can do — logs,
  crash reports, screenshots, the UI tree and actions, respring — and gaps are
  filled in icli, not beside it. The package depends on the icli CLI too
  (`com.icli.icli (>= 0.10.0)`, from apt.owngoal.dev; owner, 2026-10-26),
  which the agent runs through shell_run as the `apelin-icli` skill says —
  dedicated tools first, mobile's commands only, `icli probe` (a
  JavaScriptCore script with Objective-C reflection, in process, read-only
  `api()`, no `proc.run` or `exit()`, never `probe repl`) to look into what
  the device has, and, when it is missing, asking the user to install it
  from `https://apt.owngoal.dev`.
- **Lists and rich text** follow FlowDown: ListViewKit, MarkdownView, Litext
  and DisplayLink. FlowDown is the owner's own code (Lakr233's Inhouse
  Code; owner, 2026-10-21), so it is brought across as it is, whatever
  its licence says; every file taken from it starts with the two lines
  `// Lakr233's Inhouse Code, from FlowDown.` and
  `// I CAN DO WHAT THE FUCK I WANT.`
- **Every package** — the IDE, each development extension, each agent tool
  extension — ships as a rootless and a roothide deb in our repository
  index.
- **Packages**: the IDE is one package and depends on no injection framework.
  The development environment ships as extensions — app, tweak, command-line
  tool and preference bundle support — that the IDE package recommends, so
  they come by default and removing one is not an error. The tweak extension
  depends on an injection framework. Templates from OwnGoal's open-source
  template repositories reach the extensions by a file convention, and the
  app discovers extensions and templates at launch.
- **Not in v1**: source packages (later, when a user links their GitHub, the
  app manages the repository instead), and DCRM in any form.
- **Milestone 1 is the whole chain end to end**: the toolchain set up on the
  device, the SDK manager (download, check, register), project checks, the
  extensions with their templates, then build, sign, package, install through
  Irisin, respring and confirm the tweak loaded. The UI covers daemon access,
  project management and install, on iPhone and iPad with a standard sidebar
  split view, borrowing the five-field apps' designs — a privileged process
  handing back a file descriptor for editing among them.

## Layout

```
Apelin/                  the app: main.swift (manual UIApplicationMain), Application/
                         (delegate, ExecutableWatch, QuietExit, saved-state reset),
                         Interface/<feature>/, Resources/ (assets, string catalogue)
                         Console/ (the console's launch hook), Service/ (ApelinService.app),
                         DaemonClient (the app's ApelinTransport)
Apelind/                 the daemon, product `apelind`: main.swift (mode switch), Proxy/
                         (listener, WorkLedger, SessionLink), Session/ (SessionHost,
                         TaskRegistry, WorkerSupervisor, CallerPolicy, Approval/, Install/,
                         Files/, Terminal/, ToolHost/, Notice/), Dispatch/ (Dispatcher,
                         <Domain>Handler.swift), Vendor/ (IrisinExternalClient),
                         PeerAuthenticator, Spawn, syscalls
Workers/<Name>/          one tool target each: Environment, Build, Agent, Diagnostics,
                         LogReader (products apelin-environment … apelin-log-reader)
Packages/ApelinKit/      local package: ApelinCore, ApelinProtocol (AppOperation,
                         Operations/<Domain>.swift, Tasks, Envelope, Service/, Worker/),
                         ApelinEnvironment, ApelinBuild, ApelinProject, ApelinGit,
                         ApelinConsole (the console's runner, linked into the app),
                         ApelinReplay (ApelinService from captured runs, Fixtures/); Tests/
Packages/<Other>/        standalone packages the workers link (ApelinToolchain,
                         ApelinFormats, ApelinDiagnostics, ApelinAgent, ApelinToolHost)
Packages/Runestone/      the editor's text view and grammars, vendored and trimmed
                         (README.md: origins, changes, adding a language); the app only
Shared/                  compiled into the app and apelind: the XPC side of the wire
                         (Protocol/: AppProtocol, AppXPC, XPCEnvelope), the XPC constant
                         shim (XPCShim/, a C module), RoothideRoot
Widgets/                 Extension/ (target ApelinWidgets, ApelinWidgets.appex: the home
                         screen widget and the Live Activity, Resources/ with its
                         catalogue); Shared/ (compiled into the app and the extension:
                         ApelinLink, ChatWidgetSnapshot, ChatActivityAttributes)
Configuration/           Version, Base, Development and Release xcconfigs
Packaging/               entitlements (Workers/<name>.entitlements too), the launchd plist,
                         DEBIAN/{control,postinst,prerm,postrm}
Scripts/                 package-deb.sh, install-device.sh, device.py (the device harness),
                         collect-licenses.py and the gates
Tests/                   the harness's host tests (RoothideRoot, ExecutableWatch, ApelinLink,
                         SessionHost)
Licenses/                reviewed notices: review.json, Compatibility.md, one folder per component
Documents/               Icon/ (the .icon source, in no target), Site/ (Pages), Releases/,
                         Banner/ (the banner's template and make-banner.sh), screenshots.jpg,
                         Plan/ (Milestone-1, Handoff), Research/ (Device-Validation, the
                         toolchain retarget, ApelinHello), Console.md, Console/ (scripts/,
                         device-harness.json, fixtures/, demo/: the capture scripts and
                         the replay sanitiser),
                         Schemas/
manifest.json            the owngoal-packages entry
```

## Build & verify

- **Finish every round** (owner, 2026-10-21): use `code-clarity` for code
  changes, validate the result, commit and push this task's changes, then
  install and launch the current build on the existing vphone and verify it
  is running. Preserve other tasks' uncommitted changes. Report any failed
  step explicitly instead of claiming the round is complete.
- `make harness` — the host tests on the Mac: RoothideRoot, ExecutableWatch
  against a real replace/unlink/rollback, `swift test` for ApelinKit (the
  wire, the worker channel, paths, `ApelinService` and the console with its
  scripts), the system-only check, and apelind and
  every worker typechecked for macOS. Run this first. `SWIFTPM_SCRATCH`
  moves the package's build directory (default `Packages/ApelinKit/.build`).
- `make check` — project and packaging validation, including the floor greps.
- `make format` — `swiftformat` over the repository, for Swift 6.2, as
  `.swiftformat` configures it: Runestone, `Apelind/Vendor`, the
  development templates (their digests are pinned) and `EmbeddedSchemas.swift`
  are excluded. Run it before committing Swift. Two of its rewrites need a
  hand: a `Task { [self] in … }` after `guard let self` loses the `self.` the
  compiler still wants (write `Task { self.… }`), and `andOperator` turns
  `&&` inside a ternary condition into a comma (name the condition with a
  `let` first).
- `make build` — unsigned app, daemon and workers for iPhoneOS.
- `make deb` / `make deb-all` — roothide and rootless packages, verified.
- Packages go onto a device through Irisin's installer (`irisin-cli install
  --yes <deb>`, as root), never apt or dpkg; `install-device.sh` and
  `device.py install` do so.
- `make install` — build for `FLAVOR` and update the installation on
  `DEVICE_HOST:DEVICE_PORT` over ssh, register the bundle with `uicache -p`,
  and open the app.
- `make vphone` — the same, roothide, onto the vphone VM: `VPHONE=<name>`
  as vphone-launchpad names it (its address is read from the guest),
  `VPHONE_HOST=<address>`, or with neither the one that is running.
- `make vphone-app` — the inner loop while working on the app: the same
  build, incremental, and only `Apelin.app` put over the installed one,
  signed as the packager signs it and root's (`install-device.sh --app`),
  in about ten seconds. No gates, no harness, no package; the daemon,
  workers and dpkg's record stay as the last package left them, so a
  change outside the app, and anything that ships, takes `make vphone`.
  `make install-app` is the same onto `DEVICE_HOST`.
- `make device-test [SUITE=smoke|regression|…]` — console scripts on that
  vphone or device (`DEVICE_HOST`), set up, followed, checked and cleaned up
  by `Scripts/device.py`; `make device-run SCRIPT='i1-smoke terminal'` for
  some by name, `make device-status` for what it has, `make device-install`
  for every built package without building. `Scripts/device.py --help` has
  the rest (`call` one operation, `out`, `crashes --pull`, `screenshot`,
  `kill-host`, `shell`).

Give every parallel worker its own `DERIVED_DATA=/private/tmp/<name>` — spelled
`/private/tmp`, never `/tmp`, or a package manifest that strips its own
checkout path finds no headers.

## Package Pages

Every deb's control names its package manager icon (`Icon:`), served from
`Documents/Site`: Apelin's is `icon.png`, rendered from the `.icon`; each
extension's and the toolchain's is `icons/<package id>.png`, Apelin's plate
and braces with a green mark in place of the leaf, drawn and rendered by
`Scripts/render-package-icons.py` (sources in `Documents/Icon/Packages/`).
A new package gets its mark there; `make check` fails a control without
an icon Pages serves, and `check-templates.py` a template whose
`package.icon` is not its extension's icon there.

`Documents/Site/depiction.json` is the native depiction page. Keep its Details
copy accurate and use the largest banner referenced by the README as
`headerImage`. That banner is `Documents/screenshots.jpg`, as Fila's is, made by
`Documents/Banner/make-banner.sh` from `Template.fig`: iPhone screenshots of
the demo conversations in `demo-data.py`, taken on the iOS Simulator by a
screenshot-only build (the one simulator build there is; nothing ships from
it), put into the template's named slots and rendered at 2x
(`Documents/Banner/README.md`). Never draw or lay it out by hand: change the
data or the slots and run the script again. The Pages workflow refreshes its Changelog from published GitHub
releases using the shared updater pinned in that workflow; never maintain a
second changelog implementation or edit generated release notes by hand.
The copied publishing workflow must be named `Release` so Pages refreshes after
it succeeds. Deploy from `main`, including when an older release is edited.

Keep the `uikittools` dependency: its triggers register and unregister the app.
Maintainer hooks manage the daemon only; never add explicit `uicache` calls.

That trigger is `uicache -a`, which registers only what is not registered yet.
A package manager's UI re-registers an upgrade itself; an install from a
`.deb` file over an installed copy may not, and LaunchServices keeps the previous build's
Info.plist — version, document types, URL schemes, every key SpringBoard reads
from the record rather than from disk. After installing by hand, run
`uicache -p <prefix>/Applications/<App>.app` in the terminal, and respring if
SpringBoard has to read it again. When a plist or entitlement change "does not
take", check the record's `CFBundleVersion` against the bundle's before
anything else.

## Where things get tested

The Mac harness first (`make harness`: host tests on the Mac, no simulator);
then a vphone for the app and everything visual — `make vphone-app
VPHONE=Banana` for the iPad, `VPHONE=Date` for the iPhone, screenshots by
`Scripts/device.py screenshot` —, `make vphone` and `make device-test` for
anything that needs the package installed or runs a console script, a
jailbroken device for what a vphone cannot show, and an actual device on the
oldest OS this app claims for that floor (`make check`'s SF Symbol and XPC
macro gates and the packager's rpath check catch some of what breaks there;
none of them launches the app on it). There is no simulator
build: the app is not run on the iOS Simulator. Report which of those actually
ran. On a device, `make device-test` (the smoke suite, under a minute) after
every install, `SUITE=regression` before calling a change done, on an iPhone
and an iPad vphone both.
An iPhone Duo's inner display, either way up, can be looked at on the
iPhone Duo simulator with the banner's screenshot-only build; where the
simulator SDK is older than `IOS_SDK_TIER`, a copy of that build with its
executable's SDK stamped to the tier (`vtool -set-build-version`) shows the
tier's layout, vertical bar and all. It shows nothing of the outer display
or the fold: those take Xcode 27.1's Device Hub or a device.
What has run on a device so far, and what is still to run, is
`Documents/Research/Device-Validation.md`; keep it current rather than
adding a dated record beside it.

## Gotchas that bit us

- **A package resource bundle beside a tool.** KWWKAI reads its model
  catalogue through `Bundle.module`. Xcode's accessor for a command-line
  tool looks beside the executable and names no build path (SwiftPM's own,
  which kk patches out, bakes in the build directory), so the packager
  installs `kwwk_KWWKAI.bundle` in `usr/libexec/apelin/` next to
  apelin-agent; without it the first session is a `fatalError`.
- **A back-deployed Swift library beside a tool.** apelin-agent links
  `@rpath/libswiftCompatibilitySpan.dylib` (Swift 6.2's `Span`
  back-deployment library), and its only rpath was `/usr/lib/swift`. iOS 26 has
  the library there; iOS 16–18 do not, and dyld would kill the worker before
  `main`. Xcode embeds such a library into an app's `Frameworks/` only, never
  beside a command-line tool. Every worker target's rpaths are now
  `/usr/lib/swift`, then `@executable_path`, so the OS copy wins where it
  exists. The packager installs the toolchain's copy
  (`swift-*/iphoneos/`, install name `/usr/lib/swift/…`) in
  `usr/libexec/apelin/`, re-signed with ldid like the rest
  (`worker_runtime_libraries` in `Scripts/package-deb.sh`).
  `Scripts/check-rpath-dependencies.py` then fails the package on any shipped
  Mach-O with a strong `@rpath/` dependency that resolves to neither a file in
  the package nor a library listed as present on the floor.
- **C `__FILE__` in a package target.** Package targets do not read
  `Configuration/Base.xcconfig`; BoringSSL's error macros put a derived-data
  path into apelin-agent once per source file. The Makefile passes
  `OTHER_CFLAGS` with `-ffile-prefix-map` on the xcodebuild line, which every
  target sees: the derived-data folder for checkouts, and the repository
  root for the vendored tree-sitter runtime's `assert`s
  (`Packages/Runestone`).

- **The scaffold's daemon idle-exited under `KeepAlive`.** The template's
  daemon is on-demand and exits three seconds after its last client; the
  session-host plist kept it alive, so launchd restarted it every few
  seconds, throttled. It looked fine on the vphone — `apelind` was running
  each time anyone looked. The plist and the idle exit must agree: apelind
  is now on-demand (Product, 2026-10-16), and its idle exit waits for every
  piece of work to finish, not three seconds after the last client.
- **A vphone guest can refuse password authentication.** One answered only
  keyboard-interactive, and an agent's keys used up the attempts first.
  `install-device.sh` clears `SSH_AUTH_SOCK`, turns public keys off and asks
  for keyboard-interactive, which sshpass answers.
- **"Unable to register" from uicache is not always a failure.** On the
  iOS 27 iPad vphone, uikittools' trigger and `uicache -p` both print it for
  `Apelin.app`, and `uicache -i wiki.qaq.apelin` still shows the app
  registered at the bundle's path, and it opens. Check the record before
  chasing the message. `install-device.sh` runs `uicache -p` after every
  install anyway, for the install-from-a-file case above.
- **An iPad keeps the other app.** On the iOS 27 iPad vphone, opening
  Settings and then Apelin, to make Apelin come to the foreground, left
  Settings beside it with the focus: the UI tree read Settings, a tap meant
  for Apelin went to Settings, and Apelin was suspended mid-run, its follow
  stalled for good. The harness quits an idle app and launches it instead.
  And (4, 4), a corner of the status bar on an iPhone, is a window's close
  control on iPadOS 26: `diagnostics.json` taps (200, 4).
- **A cancelled watchdog cancelled the reader it guarded.** The console's
  follow cancelled its timeout task when the task ended; that task's
  `try? await Task.sleep` woke and went on to cancel the reader, and when it
  did so before the runner read `isCancelled`, a task that had ended
  `succeeded` was reported as a timeout after 0.3 s (`i1-smoke`'s terminal,
  once, on the iPad vphone). The watchdog now answers whether it fired. A
  `try?` around a sleep that guards something else is the same bug.
- **swift-nio 2.104.0 aborted sign-in on iOS 17.** On an iPhone 15 Pro on
  iOS 17.3.1, apelin-agent died with SIGABRT on its event loop the moment a
  browser reached the sign-in loopback: `swift_dynamicCastFailure` in
  `configureHTTPServerPipeline`, casting its handlers to `[ChannelHandler]`.
  2.104.0 made `ByteToMessageHandler`'s decoder `~Copyable`, so the
  handler's conformances carry a `where Decoder: ~Copyable` condition, and a
  Swift runtime before 6.0 (iOS before 18) cannot find such a conformance;
  NIO's own `as?` casts to its handler protocols fail there too, silently.
  The iOS 26 and 27 vphones never show it. `Packages/ApelinAgent` holds
  swift-nio to `2.98.0..<2.104.0` through a product dependency, so the app's
  and the package's `Package.resolved` both pin 2.103.0. Stay below 2.104.0
  until NIO's noncopyable conformances work on the deployment floor, and
  check again on an iOS 16 or 17 device before raising it.
- **CLT 15.0's linker bound arm64e without pointer authentication.** Given
  `-undefined dynamic_lookup` (or `suppress`), its ld writes an arm64e
  slice's fixups as plain dyld opcodes, not chained fixups: the signature
  stays encoded in each slot, and dyld overwrites it with a bare pointer.
  A constant string's class and every import arrive unsigned; on the iOS
  26.4 iPhone vphone the first message to an `@"…"` constant killed the
  process. CLT 14.2, 15.3 (threaded binds), 16.4 and 27.0 keep the
  signatures, none of the five drops one in an ordinary link, and Xcode
  27's ld switches such a link to chained fixups itself. apelin-build
  refuses a slice like that at its link (`DyldInfo.dropsPointerSignatures`
  in ApelinMachO); a symbol left to load time is named with
  `-Wl,-U,_symbol`, which every release links signed.
- **A long chat opened in its middle.** `use(_:)` asked for the opening
  scroll, then restored the composer's draft, whose height update lays the
  whole window out (`doWithAnimation`), before the new list had its rows.
  `viewDidLayoutSubviews` ran the opening loop on the empty list, took it
  for its end and was done; the jump that followed went to the end the
  44 pt estimates make, and the essays measured there grew below it, so a
  14-turn chat opened at its 7th turn (iPhone vphone, build 45). The loop
  waits while `use(_:)` swaps the conversation in (`isSwitchingChat`), and
  `use(_:)` asks for the pass once the rows are in. A synchronous layout
  anywhere in `use(_:)` is enough to bring it back.


- **The app was offline while the workers were not.** Sign In with GitHub
  failed "The Internet connection appears to be offline" on an iPhone where
  every model provider's sign-in went through: the device flow runs in the
  app, the provider sign-ins in apelin-agent, and CoreTelephony's per-app
  data policy (Wireless Data; WLAN & Cellular on a device sold in China)
  binds apps by bundle ID, never a daemon's children. No prompt asks about
  an app a package manager installed, so where the system holds it denied
  the app stays offline. At launch the app reads its own policy and, unless
  Wi-Fi and cellular are both allowed already, allows both
  (`NetworkAccess`, the journal says what it found), as Irisin does
  (`CellularPolicy`) and as icli's `app network repair` does for another
  app, with `com.apple.CommCenter.fine-grained` `spi` and
  `data-allowed-write`, which the packager requires.


## Live chat and project UI (2026-10-21)

- `ChatRuntime` keeps one reader per live session while the user switches pages. It persists ordered host events and reattaches after the saved cursor. A save that fails (a full disk, a folder it cannot write) leaves the conversation running in memory: `StorageWarning` says so once — "Storage Almost Full" when less than 512 MB is free, else the error — and not again until a save gets through; the unsaved conversations are written with the next save that works and on every return to the foreground, and the same notice comes at launch or on return when free space is already under 512 MB. Sending text never needs the disk; only attachments are staged. A stopped host can reopen the persisted session ID; the host and worker refuse a different workspace identity. A reopened session comes back as a new task that replays the whole history, renumbered and newly timed, before anything new; the conversation keeps the events it has and reads past that replay (`ChatRecord.reopen(as:)`, `SessionReplay`, saved with the record) to the first user message or compaction it has not seen (Compact… reopens a stopped session with no message after it), or to the task's own end, so the rows on screen stay as they are. A terminal `state` is never read as the replay (the worker replays only the states an approval sets), so a task that stops before catching up (its worker died, the host stopped, a second open failed) ends the turn as a first task does. A conversation an earlier version saved with its cursor past that end takes it again when an attach answers `finished` while its transcript still runs a turn (`ChatRecord.missedEnd`, `takeMissedEnd`): that one event, read again from just before the task's last seq; the row stops working even when it cannot be read. Never empty the events for a new task: the list would collapse to the message being sent and land at the top of the history when the replay came back. Rows are numbered by their event's position, not its seq, since a reopened task's numbering starts again. Stop calls `agentAbort`; approval buttons call `agentApprove` and wait for the authoritative resolved event.
- `agentPrompt` accepts an optional message UUID and descriptor-indexed attachments (at most eight, at most 32 MiB each). The worker saves them under random workspace-relative `Attachments/` paths; filenames remain display metadata. The session log records the message UUID and relative attachments, deduplicates a retried send, and supplies image content to the provider. Tool-returned images are saved the same way and replay into the image album UI. So are the files `file_show` puts in front of the reader (2026-10-29, `Tools/FileShow.swift`), the agent's one way to show a project file, since a path or a `file:` link in a reply opens nothing: one to eight regular files inside the project, each at most 32 MiB, every one checked before any is copied into `Attachments/` as it is then, listed in the result's `details` (which no provider reads) and handed by the session to the call's `toolResult` attachments, where the album, the document cards and Quick Look show them. A read preset with no host request; the model hears what was shown, never the contents.
- Every app prompt also carries the current approval mode and Ask Before Using the Screen, which the message's `<system-state>` names beside the mode (owner, 2026-10-30). The host updates its ledger and session table before forwarding; the session updates its tool policy and metadata, records the message (its `prompt` or `queued` event, the text alone), then builds the message's `<system-state>`: the mode reaches the model there, with whatever the session's system prompt shows that changed since (Prompt caching). A prompt naming the provider and model the session already resolved, with the same stored sign-in, keeps that resolution: no token exchange before the message is recorded, and a signed-out provider is still refused. An existing pending approval is not silently accepted. A bounded, tool-free completion on the current model summarizes the first user message into a `title` event; title failure leaves the local fallback and does not fail the turn; a later message asks again, until three completions have named nothing (`maximumTitleMisses`) or, while the project keeps its generated name, on every message. A JSON answer in one Markdown fence is read as the JSON.
- `ChatRuntime.transcript` brings a conversation's rows up to date only when they would differ (`ChatTranscriptCache`, kept for the followed conversations and the page's). `ChatTranscript` is a fold: new events (`ChatRecord.events` are only appended to) are read onto the rows the earlier ones made (`append`), and the rows shown are made afresh from those, as a build from every event at once at the same `now` makes them (`Tests/ChatTranscript/TranscriptFold.swift` compares the two over random logs). A change to the messages it is sending, or a `quietDeadline` passed since it was shown, shows the rows again, so the refresh `ChatQuietWatch` asks for at the deadline adds the stand-in; only a sender's new title builds it again from every event. A row equal to one shown before is that very value, so the page's comparison stops at its storage. The composer is told of its approval request and its Stop only when either changes, a long-poll that ran out with nothing writes nothing, and a conversation is written once at a time, then once more with what changed meanwhile.
- Working state comes from session events, never a late send acknowledgement. Completed zero-second, zero-tool thought rows are omitted. A positive duration without tools shows only the duration; tools without a positive duration show only their count; “and” joins the clauses only when both values are positive. Thought headers use Litext numeric transitions, with reduced motion respected. User messages and reply text are selectable.
- The conversation alternates a single thinking summary with response content. Consecutive thinking steps merge across tools and approvals. Tool calls and completed approvals stay out of the main transcript; tapping the summary opens their ordered trace in a form sheet, a list of the steps, provider-supplied thinking included, each opening its own plain text. Headers use body-size 50% primary text aligned to the body margin, with a sentence for duration and tool count. Pending approval still replaces the composer.
- Every agent tool, MCP tools included, requires a short `reason` (`ToolReason`), stripped from the arguments before the approval gate, the fingerprint, the tool or the host sees them; the `toolCall` event keeps it. The file tools end their result's first line with `+a -b` lines added and removed. While a turn runs, its trailing summary stays unfinished across calls and approvals, the run's received tokens climbing at the trailing end of its title line (and of the summary above the reply while the reply streams). Once the summary has a call, `ToolCallBannerView` shows one line under it, at the reading width, between hairlines on a 5% grey ground drawn out to the row's edges: the newest call in its trace (`ToolCallBanner`), by its reason, or its title for a call made without one, and for a file tool (`ToolCallBanner.fileTools`) the file's name first, then the lines added in green and removed in red once its result is in, read from the result's first line (a failed call has none), so truncation takes the end of the reason, never the numbers. Thinking after a call leaves that call there; nothing of the thinking shows (owner, 2026-10-24: no thinking tail, typing or character fade). On the same summary, a new call, or its counts coming in, fades in over 0.2 s; the line's first call, a row taken over by another summary and everything under Reduce Motion show at once. VoiceOver reads the line after the title: the reason, then the file and its counts in words as its value. Only the running summary in the transcript has it; the trace sheet lists every call and opens each whole. The running summary reads “Reconnecting…” after a `reconnecting`, until the request made again streams or the run moves on, else “Executing N tools…” only while N calls await a result, “Thinking…” otherwise, and its title changes at most once a second: the first change at once, the latest of the rest when the second is up. A running summary stands in under a prompt, or under images a tool returned, until the turn shows something, with the id its next thought takes, and `toolCallPreparing` starts one while the model writes a call's arguments, so a turn never shows a gap. One stands in under the turn's last reply (or error) too once the running turn has gone `ChatTranscript.quietInterval` (1.5 s) without an event — the model may be writing a call it has not announced, or the provider has stalled —, never under a running summary or a waiting approval. The transcript is given the time (`now`) and answers `quietDeadline`; the page builds its rows again once, then (`ChatQuietWatch`), and nothing polls. The reply's next thought, call or message start takes the stand-in's id, so it becomes that row with no flash, and more of the reply ends it. A `messageDiscarded` takes back the rows its message made, while it was still streaming, and leaves unanswered again what it answered, so the stand-in comes back under the same id and the retried reply is drawn once, never under the partial one. Transcript content is centred in at most 730 pt, the composer card's widest, so the two edges line up; the list itself spans the page's safe area side to side, so its margins scroll, and stops at a vertical bar's strip, which is the bar's (iPhone Duo at the 27.1 SDK tier: a trailing safe-area inset on one side only).
- `ProjectPickerController` lists real projects; `NewProjectController` chooses a catalog template, using its default parameters and calls `projectCreate`. Settings includes a read-only Templates catalog with single-line names with source-file byte counts at the trailing edge, no subtitles and no disclosure navigation. The built-in `wiki.qaq.apelin.workspace/empty` template creates only a workspace identity manifest, atomically and without SDK/toolchain requirements. It supplies no build or install baseline; a build requires a real build description.

- Templates are a single read-only release catalog, with additions and corrections submitted as repository pull requests. There is no create/delete action or separate user template library. `make template-archive` validates and reproducibly packs sources, support files and licenses as `Apelin_<version>_Templates.tar.zst`; CI records its checksum and Release publishes that exact artifact without rebuilding. The command-line tool templates' `Tool.entitlements` carry the app templates' GPU and IOSurface IOKit user-client list under both keys from `wiki.qaq.apelin.dev.cli` 0.1.1 (owner, 2026-10-29; `make check` holds the app's entitlements and every app and cli template's to `Scripts/check-gpu-entitlements.py`, while a tweak or preference bundle, a library, runs with its host process's), and a project keeps the entitlements its template wrote, so a cli project made from 0.1.0 has no list until one is added, a build description change Strict reviews. Every template writes its extension's package manager icon on Pages, `https://owngoal-dev.github.io/Apelin/icons/<extension id>.png`, as `package.icon` (owner, 2026-10-29; app and tweak 0.1.1, cli and preferences 0.1.2), which the build writes as the deb's `Icon`, so a package manager shows it beside the installed package and in the user's package repository; the user keeps it or names their own https image, a packaging description change Strict reviews. It is not an app's own icon, nor a Settings row's: the preference bundle template carries that one in its bundle from `wiki.qaq.apelin.dev.preferences` 0.1.3 (owner, 2026-10-30, issue #19), `Resources/icon.png` with its @2x and @3x at 29 points, the extension's plate scaled from the `ProjectIconPreferences` image set, named by the PreferenceLoader entry's `icon`, for the developer to replace. A project made before has none and keeps its digests.


## Project display names and external project actions

The project folder (`ProjectSummary.name`) and manifest `projectID` are stable.
The optional manifest `displayName` is the name shown in the sidebar and project
picker; `autoName` grants one automatic replacement of a generated placeholder.
`ProjectCreateRequest.automaticallyName` is true while the name field is empty:
the generated fruit name is only its placeholder, and the project takes it. A manual rename clears `autoName`; an automatic rename
also checks that the displayed name still equals the original folder name, so
a direct external rename wins even if it left the flag set. The current model's
title completion returns a separate optional project-name candidate, limited to
eight words and 80 characters. A greeting or generic question has no project
candidate. If a greeting came first, the same chat can still receive a project
candidate on a later concrete goal while the placeholder remains; its existing
chat title is kept. Plain-title or malformed JSON responses never rename a project.
The agent renames through `projectRename` too (apelin_project_rename,
owner, 2026-10-24; `Session/Agent/AgentProjectRenameRules.swift`): its own
session's project in either mode, without asking — the label the file
tools may write in its manifest anyway, outside every approval digest —,
with `automatic: true` as `onlyIfAutomatic`, the session's own project's
alone (the prompt's way to name a placeholder once the user states a goal,
a user's or an external rename winning as above; its result names the
`local.apelin.` identifiers the project still carries, `identifierHint`,
since the new project's name is the moment to settle them, and a rename the
user asked for names none); another project only by
its projectID, and under Confirm only by spending one approval the app gave
that session naming exactly that project and name
(`detail.projectRename` {projectID, folder, currentName, displayName}),
every time, never for the session. The file tools still edit the field
where they reach. The writer (`ProjectManifestFile`) opens the
canonical project directory, refuses a symlink manifest, checks its identity and
bytes again, and replaces it relative to that directory, its mode and owner
kept, in the manifest's written form (`ProjectManifestFormat`). These display
fields are excluded from build and packaging approval digests.

Deleting a project (owner, 2026-10-29: dangerous, but the feature exists
and the agent may do it, under the modes as they are) is `projectDelete`
{projectID, projectName?}: the app's own Delete in All Projects stays as
it was, and the agent's apelin_project_delete reaches the same end. The
session host resolves the project (`AgentProjectDeleteRules.target`,
through `AgentProjects.resolve`: the folder directly under `Projects/`
whose `apelin-project.json` carries that id, by canonical path, no link
followed, and the folder named when one is; a `temporary:` id is
refused, a temporary chat's folder being no project), refuses an agent
its own session's project and under Confirm spends the approval naming
exactly it, closes every running session of the project as `agentClose`
closes one (`AgentHandler.closeSessions`; one its worker will not close
keeps the project), then forwards the request, bound to the folder it
resolved, to apelin-build: the worker that makes and renames project
folders, as mobile, their owner, so root never removes them. It reads
the folder's id again without following a link and removes the folder
with `DataFolder.removeProject`, the call the app's Delete makes
(`ProjectDeletion`). `Builds/<projectID>/` stays, as the
app's Delete leaves it. The app learns of it from the folder itself
(`DeletedProjects`): whatever removed it, the project's conversations,
their delivered banners and their widget and Live Activity rows go as
Delete takes them. It goes by the folder rather than by an event on the
deleting conversation's task because the app may not be following that
task (closed, or the host restarted since), and because a folder another
app or a command removed is just as gone; a folder renamed outside Apelin,
whose conversations were already unreachable, loses them too. Tested by
`ProjectDeletionTests` (ApelinKit), the session host's checks (the
temporary folder, the link, another id, the session's own project,
Strict's spend, the sessions closed), `ProjectDeleteToolTests` and
`ProjectDeleteBackendTests` (ApelinAgent) and `DeletedProjectsCheck` in
the transcript harness; on a device only the refusal in `hello.json`
runs unattended (Device-Validation ▸ Still to run has the rest).

`ProjectCatalogMonitor` observes project directories and manifests, including
in-place writes and atomic replacements made outside the app. A change reloads
project metadata without changing the selected folder or chat. All Projects
uses type section headers and single-line display names.

The chat's More menu (`ChatActions`) acts on its conversation and its current
project, in four groups: Rename… and Compact… (the conversation); Open in
iGhostVT and Open in Fila; the project's Rename…, Export… and Distribute…;
and Delete Conversation…. General
Chat has Rename…, Compact…, the two Open items for the conversation's own `Temporary/<conversation>/`,
made if missing (`ProjectActions.temporaryDirectory`), and Delete
Conversation…. Delete Conversation… (owner, 2026-10-30) is the sidebar's
Delete (`SidebarController.delete(_:from:presenter:)`), but always asks
first, naming the conversation; while it works the question says so and
its button is Stop and Delete. The page is then what the sidebar's Delete
leaves it: the icon beside the sidebar, a conversation behind a drawer. A conversation the reader
renamed keeps that name (`ChatSummary.isNamedByReader`, saved with the chat):
the agent's `title` events and the first message's opening no longer replace
it, and a name of only spaces changes nothing. Compact… is enabled only
between runs (`ChatRuntime.canCompact`: a session, nothing working, waiting
or being sent); it asks first, then shows a cancellable progress card while
`agentCompact` runs and follows the task to `compactionFinished`, which also
marks the conversation working meanwhile (Stop stops it). Compacted says so
in an `SPIndicator`; too short and failed say so in a notice, the failure
in the provider's words. A compaction that compacted is also a row of the
transcript where it happened (2026-10-28): `ChatTranscript` makes a
`.compaction` row of its `compactionFinished`, its id from the event like
any row, its text the event's `summary`; `ChatCompactionRow` is one quiet
line, "Compacted" at the body size in 50% label colour like a summary's
title and with no icon, an accessibility element with the button trait,
and a tap opens the summary as plain selectable text in a form sheet
(`ChatCompactionController`, not the trace sheet). It comes between turns,
with none to follow, so a reader at the latest message is scrolled to it.
A compaction recorded
before the summary was kept has its row, which opens nothing and is no
button. Distribute… builds a project
from its description or a workspace from its own script (`ProjectBuildMethod`;
owner, 2026-10-24); it is disabled, saying what is missing, for a manifest
with no `build` and for a workspace with no `external` script, and the
distribution page checks again, lists the check's errors (a script that is
not in the project, say) and keeps Build off until they are fixed.
Fila opens the canonical folder with `fila://open?path=…&tab=new`;
iGhostVT 1.6.19 or later opens `ighostvt://new?directory=…`, a directory-only URL
that cannot carry a shell command. Both apps are package dependencies. Project
export reuses `transferExport` and the real `.apeproj` transfer format; no new
archive format or exporter is introduced. Distribution sends `buildStart` with
its optional `bootstrap` (`roothide` or `rootless`); omission retains the current
device default. The distribution page starts with no build. Its Packages
section (2026-10-29, `DistributionPackages`) lists per target the newest
release build of the manifest's version (a workspace's newest), from the
records in `Builds/artifacts/`, offered only while its deb still has the
recorded digest (an older build of that version when it is the one the
repository holds), each Built, Shared (a completed share sheet, by digest in
the app's defaults) or Published (the repository's clone holds those bytes
under `distributionPublish`'s file name). Publish to Repository sends the
selected ones, roothide and rootless together, in one `distributionPublish`
after a confirmation naming each; Share Package works per row
(`DistributionPublishing`, the build page's too). Nothing is built or
packaged again; `distribution.version.packaged` is advice to publish or share
that build, and Build asks nothing for it alone when that package is listed.
Building again stays: the user chooses one target and taps Build. The first
page lists the distribution check's warnings for that target, offers Ask
Agent to Prepare (a prompt sent to the project's conversation), and asks before building with
warnings left; Build pushes `DistributionBuildController`, which sends one
build request, shows only that target's progress and keeps the build log behind
its `…` menu. Once its one package is verified, the page's primary action is
Distribute (2026-10-29: the bar's prominent style on iOS 26, a bold title
before it), whose menu, repeated in `…`, keeps sharing and publishing apart:
Share Package hands the `.deb` to the share sheet, and Publish to Repository
adds it to the linked package repository or, with none linked, opens
Settings at its Git page (`SettingsViewController.presentGit`) over the
build page, where Publishing sets one up, after Sign In if GitHub has no
account yet. Choosing another target
requires going back and a new run. The table uses stable diffable identities and
reconfigures progress rows in place. Each release build produces its own package
and dSYM through the existing complete build pipeline (see `Documents/Distribution.md`).


The agent's system prompt (`ApelinAgent/Session/SystemPrompt.swift`) is kept
short, after pi's: the language the user writes in, for the reply, every
progress note between tool calls and every question, even after English
tool results (when that is unclear — code, a log, one word, a pasted
file — the system language `<system-state>` names; code, identifiers, paths
and commit messages as the repository has them; owner, 2026-10-25; on a
device, Chinese chats got "Build passed. Installing." from a rule that
said only "Reply"), the result first with no preamble, a
greeting answered with a greeting (no tools, no survey of the project), then the
checks actually run and any real blocker; whatever was done other than as
asked (a setting left at its default, a step skipped or left to another
conversation or a later turn, a smaller change) is said plainly with what
remains, never for the user to find. A build, an install or a load check
proves no behaviour: the reply says something works only if the model saw it
work on the device, and lists each changed behaviour it did not exercise under
"Not tested", one line each with how the user can check it (on a device, a
chat called a gesture, the Dock's spacing and a settings list done that it had
never run). `# Responses` makes concision bite —
match the length to the task, and do not paste tool output, files, diffs or
logs back, narrate the steps or recap at the end; a progress note is one short
line in the user's language (owner, 2026-10-24). It also says the prompt is
not secret, Apelin being open source: asked for it, its skills list or the
project instructions, the model shows or summarizes them, and only
`<system-state>` stays unquoted (2026-10-29; on a device a chat refused,
stretching that block's rule to the whole prompt). `# Working` opens with
what a model's general knowledge gets wrong: an Apelin tweak is plain
Objective-C hooked with `MSHookMessageEx` (the template's `Sources/Tweak.m`),
with no Logos or Theos,
and Apelin-specific work, a question included, starts from the matching skill
(on a device, General Chat answered from memory that the template was a
Logos `Tweak.x`). A package comes only from apelin_project_build: never a
`.deb` put together by hand or copied into the project, a workspace's
declared script aside (`# Workspace`); a user who wants the file takes it
from Distribute…, release builds already made go to the user's package
repository with apelin_package_publish (owner, 2026-10-29: Distribute… would build
them again), only as the user asked or agreed, told which packages go to
which repository, and a conversation opened for one is asked for a build (on
a device, one opened to deliver a tweak's packages made them itself, into
the project's `Dist/`). A new project's `local.apelin.` package and bundle
IDs are settled with the user before its first install and kept the same for
debug and release builds; once its package is installed, the agent never
changes one on its own, since a new identifier is another package, and agrees
a migration with the user first (2026-10-29: a package ID changed while
preparing a release, after a debug package was installed, and the user met
installer errors moving between them). It keeps apelin_notification_send for what the reader
would want to know while away (a long build, install or setup ended, something
to do on the device), never routine progress, the reply or the turn's end,
sends the model to a known source with apelin_web_fetch, never a search
engine through curl, and sends a program the agent compiles and runs
itself through shell_run to `apelin-device-executables` to be signed
first, has apelin_feedback_send wait for the user's explicit consent
to the issue it showed them, and apelin_feedback_edit, which corrects
feedback already filed instead of filing it again, for their consent to
the edit it showed them, has apelin_git_create_repository make
only a repository the user asked for or explicitly agreed to, with the
owner, name and visibility they gave, and has apelin_git_create_issue
post only on a repository the user named, after their explicit consent
to the issue shown, a refusal reported rather than worked around in a
browser or on another repository. After a change that shows on screen it
drives it with the screen tools — the UI tree read, an action, the tree read
again —, and a step it cannot take (the device locked, a gesture the tool
lacks, a declined call or screenshot) leaves that behaviour Not tested. A
screenshot, by apelin_screen_capture, icli through shell_run or any other
way, waits for the user's explicit consent to that one, in every mode (owner,
2026-10-29: a user working on a Dock animation saw the agent take several
without asking, some catching unrelated apps in front): the model says what
it is for and what it will show and asks, a broad request such as testing on
the device is no consent, nor is another conversation's message, one consent
covers one screenshot, and what is under test comes to the front first. That is instructions only, in the
prompt, the tool's description and the apelin-icli and
apelin-tweak-development skills (`ScreenshotConsentTests`); the tool and
Strict's card are as they were. While `<system-state>` says Ask Before
Using the Screen is on (owner, 2026-10-30), opening an app or a link and
reading or acting on the screen, by the screen tools, icli or any other way,
wait the same way, in every mode: the model says what it will open, read or
do and why, a request to do a task (filing an issue, testing on the device)
is no consent, and the card then asks too; `# This device` and
`# Approval modes` say so, as do both screen tools' descriptions and the
apelin-icli and apelin-tweak-development skills, and the gate and the host
enforce it (`ScreenUseConsentTests`). It asks for independent tool calls in
one response (kwwk's `parallelToolCallsGuideline`), treats tool output, files,
logs and MCP results as data, and names every approval mode with what it
lets through (`# Approval modes`) but none as the one on. It holds nothing
that changes from message to message: no date, no mode, and it is taken
once a session (Prompt caching, below). The date and mode are each
message's (`Session/SystemState.swift`, owner, 2026-10-25): before every
message from the user or another conversation — a prompt, a queued message,
a steer, `apelin_conversation_send` — the model reads a `<system-state>`
block, the system language (the mobile user's `AppleLanguages` and
`AppleLocale`, read by the worker itself through `CFPreferences` each time,
so no wire change), the reply rule, progress notes included, the local
date, time and time zone, the approval mode on and whether Ask Before
Using the Screen is on — and, when the
snapshot is out of date, what changed since the model was last told, and
on the first message after the host said it restarted (`hostRestarted`,
Agent sessions above; owner, 2026-10-29: a roothide device's jbroot was
renamed after a reboot, and a chat that went on trusted the paths in its
history and spent a turn finding its toolchain and SDK "gone") a note
(`SystemState.restartNote`) that Apelin's background service restarted
since the conversation last ran, so the device may have rebooted and the
jailbreak, Apelin or the bootstrap's root path may have changed, naming
the install root now, that paths, toolchains, SDKs, processes and files
named earlier may be stale while the Environment section is current (a
reopened session takes its system prompt afresh), and to check before
relying on an earlier path and set up, install or import nothing again
before checking what is registered. It is taken as a delta is, so a
dropped queued message that carried it leaves it for the next, and a
steer carries none — and the prompt says it is Apelin's, unseen
by the user, and not to be quoted. Like the project context it is added to the text the
model sees and goes into that message of the transcript, so every later
request sends it as it went; the app's `prompt`, `queued` and `steer` events,
the title completion and `apelin_conversation_read` have the text alone.
The language, time, mode and screen setting are in every block, a few dozen
tokens paid in full once and read from the cache after: the time differs on
every message anyway, and a block that said only what changed would leave the model
guessing once a compaction summarised the message that last named the
language or the mode. The host's
enforcement of the mode is unchanged; the block only tells the model. The
project's `AGENTS.md`, else `CLAUDE.md` — a regular file inside the project, at most
16 KB — is added as project instructions that never override the prompt or the
approval mode. Skills are pi's progressive disclosure: the prompt lists each
built-in and user skill (`~/Documents/wiki.qaq.apelin/skills`) by name and
description only, and `apelin_skill_read{name, file?}` reads the body, or a file in a
user skill's own folder (no link out of it), on demand; it is a read preset.
The built-ins are one Swift file each under `ApelinAgent/Skills/BuiltIn/`,
listed by `BuiltInSkills.all`; what they claim about the device was read from
Apelin's own templates and pipeline, the sibling apps (Irisin's installer,
icli, Xrash, iGhostVT, Fila, LookInside's tweak) and roothide's developer
notes, and a claim nobody has seen hold on a device stays out.
A built-in skill may carry files of its own (`SkillDocument.files`):
`apelin-project-description` is every member of `apelin-project.json`, the macros the
build defines and what asks the user, with the embedded schema as its file
`apelin-project.schema.json` (`ProjectValidation.schemaText`); a test fails
when the schema gains a member the guide never names. `apelin-tweak-development`
is the edit-build loop, ending on the changed behaviour driven with the screen
tools (the UI tree, asked for first while Ask Before Using the Screen is
on, and a screenshot only once the user agreed to it), and how
to live beside other tweaks (hooks that chain,
`static` names, prefixed added methods and classes), and says Theos is not
supported (owner, 2026-10-23): a Theos tweak's Logos is rewritten as plain
Objective-C in the template's style, never built with Theos, which is never
installed; an imported repository keeps building with a script of its own.
`apelin-bootstrap-paths` (owner, 2026-10-24) is roothide and rootless path spelling —
jbroot vs `/var/jb`, `/rootfs`, `@PREFIX@`/`@ROOTFS@`, `@loader_path/.jbroot`,
the compiler-vs-shell split, and never storing a resolved jbroot path
(2026-10-29) — and carries `ApelinBootstrap.h`, a
jbroot()/ROOT_PATH_NS() helper written so one source builds for both
bootstraps (compiled by hand for roothide arm64e and rootless arm64 with the
template's flags; a test holds that the skill ships the header).
`apelin-tweak-runtime` is logging (os_log under the package id, `%{public}`, the live
log apelin_log_read reads), the sandbox an injected dylib inherits, reading a
setting, and signalling another process with a payload-free Darwin
notification. `apelin-preference-bundle` is the Settings pane: `PSListController`,
`Root.plist`, the PreferenceLoader entry and the domain the tweak reads,
and where the preferences extension's header is, to read with file_read
before calling the framework from code (a method it lacks goes in a
category in the project).
`apelin-package-dependencies` is how a package is installed — the project's own build
through `apelin_package_install`, a dependency through the user in Irisin — and why
shell_run (mobile) cannot install, remove or respring and why `apt` and `dpkg`
do not work for the agent; `irisin-cli`, which answers only as root, runs
with `root: true` for a dependency's install and, to find why Irisin
refuses an install or upgrade, for its questions and `--dry-run --yes`
(owner, 2026-10-30). `apelin-packaging-and-install` and `apelin-crash-triage` cover
where the package stays, its identity (the placeholders asked about before
the first install and changed everywhere `file_grep` finds them, the same
identifiers for debug and release, and changing an installed one: another
package, so the old installation is removed with the user's agreement before
the new one installs, and nothing keyed by the old ID follows),
install/respring/confirm (an app installed again
restarted with icli's `app kill --force`, then `app launch`) and reading a
crash. `apelin-external-build` is the workspace
build: the declaration, what the script gets and must write, and how its
package is installed. `apelin-device-executables` (2026-10-29) is a program
the agent compiles and runs itself through shell_run: `ldid -S` with the
skill's `Tool.entitlements` after every link (unsigned, it exits 137), the
file the cli templates' keys, which carry the app template's IOKit
user-client lists from `wiki.qaq.apelin.dev.cli` 0.1.1 (a test holds the keys
to the cli templates and the lists to the app template), since a VideoToolbox
tool signed without them failed `CVPixelBufferCreate` with -6662 on a device;
it says a cli project made from 0.1.0 needs both lists copied into its own.
`apelin-git-workflow` (owner, 2026-10-25) is keeping the
project's history for the user: commit on your own once a change builds
unless the user drives git, `git_commit` with `all`, messages, `.gitignore`,
`git_init` for a project without a repository, push only when asked (a
first one with `url`, to an empty repository apelin_git_create_repository
made as the user asked, or one the user made), a squash or a forced push
only when the user explicitly asks for it (git_squash, git_push with
force_with_lease, owner, 2026-10-31), and github.com through Sign In
with GitHub. `apelin-package-repository` is the package
repository (Distribution repository, below): its layout after
owngoal-packages, the control fields a package needs, how Publish adds a
release, and keeping old versions in check. `apelin-icli` (owner,
2026-10-26) is running icli through shell_run: an argv, its help read
first, Apelin's own tools where they exist, the commands its device
acceptance ran as mobile, never its package, respring or uicache
commands, its launchd changes, `fs chown`, system writes and a reboot only
as root with the user's go-ahead for exactly that (owner, 2026-10-30), its
`screen shot`, `screen ocr` and `screen describe` as screenshots that wait
for the user's consent, every command, while Ask Before Using the Screen is
on, asking on a card and, for one that opens, reads or acts on the screen,
after the user's consent in the conversation (owner, 2026-10-30),
roothide's `jbroot` prefix,
and pointing the user to `https://apt.owngoal.dev` when it is missing.
Every built-in's name begins `apelin-` (owner, 2026-10-25), so none takes
the name of a user's skill of the same subject; `BuiltInSkills.legacyNames`
lets `apelin_skill_read` find one by its old name when no skill has that
name now, for transcripts, memories and instructions written before.
Skills, memory and the project instructions are the session's snapshot
(Prompt caching, below): an open session hears of a change as a delta in its
next message's `<system-state>`. Skills are global (owner, 2026-10-23): the built-ins and the skills folder,
never a project's own `.claude/skills` or `.kwwk/skills`. Settings ▸ Agent ▸
Skills (`Apelin/Interface/Settings/Skills/`) lists them from `agentSkillList`,
which the credential worker answers with `SkillCatalog.listing` — the
catalogue a session reads, each skill's body and files as `apelin_skill_read` serves
them, its place in the folder (`location`) and every problem kwwk or a taken
built-in name raises. A row opens the instructions; the plus copies in a folder
with a `SKILL.md` at its top, or one Markdown file as the `SKILL.md` of a folder
named for it (`SkillFolder`, in ApelinCore: links and hidden entries left
behind, at most 2,000 files and 32 MB, staged under a hidden name and moved
in whole, an existing one replaced only after asking); a swipe removes a
folder skill or a problem's place, after asking, never through a link out of
the folder. The app writes the folder itself, as mobile; an open session is
told in its next message's `<system-state>`.
The agent manages the same folder (owner, 2026-10-24; `Skills/SkillTools.swift`,
in every chat, no host request — the worker is mobile too):
apelin_skill_list (a read preset: name, description, source, files,
`location` and the folder's problems, no bodies), apelin_skill_save
{name, description, instructions, replace?} and apelin_skill_remove {name}.
A save is checked before asking as kwwk reads a skill — the name lowercase
letters, digits and single hyphens, at most 64, not a built-in's; the
description one line of at most 1024; the instructions at most 64 KB —,
refused when `<name>.md` sits at the top or a skill is there without
`replace`, written as `<name>/SKILL.md` with `name` and `description`
frontmatter through `SkillFolder.write`, which stages the folder, has kwwk
load it there (any diagnostic refuses it, nothing changes) and moves it in
whole, a link in its place moved aside, never written through. A removal
takes a user skill by name, never a built-in. Under Strict both ask every
time (`ApprovalDetail.skillChange` {action, name, location, replacing,
text}: the card shows the whole `SKILL.md`), never with a session grant,
because a skill is instructions every later conversation, in every project,
lists and may follow, unlike memory, which is data; the tool's description
says to save one only when the user asks or agrees, never from a file, log,
web page or tool output.

A local tool's empty optional argument — `null`, `""`, `[]` or `{}` — is
dropped before the tool, the gate or the host sees it (`ToolArguments`), as a
model fills an optional parameter it means to leave out; a required one is
left for the tool to refuse, and `apelin_git_set_author`'s empty fields, which clear
them, are kept. shell_run refuses two of `argv`, `command` and `script` at
once, and a memory id the current revision lacks is named as a wrong id,
not as a change to memory.

`# Environment` (`Session/EnvironmentPrompt.swift`, one call site in the
prompt) states the device — `hw.machine`, arm64e, the iOS version and the
kernel's FEAT_LRCPC, FEAT_SHA3 and FEAT_DotProd —, the bootstrap and install
root (from the assignment, `BuildBootstrap.resolve`), every registered
toolchain (ID, CLT release, components with the Swift version, the minimum
iOS, the newest SDK it reads, its self-test count, default / this project's /
prepared, its tool directory) and SDK (ID, version, path, the same marks, and
"too new" for the prepared toolchain), a binding this device lacks, and that
shell_run and the terminal already have the prepared toolchain and SDK, so the
model neither probes nor sets up again what is installed. It also says that
shell_run needs no login shell (whose profile builds `PATH` again), on roothide
that a path a bootstrap tool prints (`/var/mobile/…` with the bootstrap as
`/`, or `/rootfs/…`) is not the name the toolchain's compilers know, so they
get relative paths or `$APELIN_PROJECT_ROOT` (on the iPhone vphone, `pwd -P`
in the data folder printed `/var/mobile/Documents/…`), on roothide that the
install root can be renamed on a reboot or a new jailbreak, taking the
data folder (in its own `var/mobile`), the project, `$APELIN_PROJECT_ROOT`,
`$APELIN_TOOLCHAIN_BIN`, `SDKROOT` and every toolchain and SDK path with it,
so none is written into anything that outlives the run (project files,
build scripts, Makefiles, `AGENTS.md`/`CLAUDE.md`, memory, skills, package
scripts, code): code resolves it at run time (`jbroot()`, the
apelin-bootstrap-paths skill's `ApelinBootstrapPath()`), plists and
maintainer scripts take `@PREFIX@`/`@ROOTFS@`, scripts Apelin's run-time
variables or project-relative paths (owner, 2026-10-29; rootless's `/var/jb`
does not move, and the skill says so), and which of cmake,
dpkg-deb, git, ldid, make, ninja, perl, python3 and xcrun are on shell_run's
search path (`DevelopmentEnvironment.searchPath`,
the host's own list), dpkg-deb, when found, for a workspace's declared script
alone, the two folders the read tools reach besides the project
(`ReadOnlyRoots`), and the agent tool extensions whose tools it offers,
each with its version, ID and tools, saying they run outside the project
and ask in Strict mode (none when none is). It is part of the session's
snapshot, holds nothing
that changes unless the environment does — no time, size or duration,
everything sorted — and a toolchain or SDK registered or removed later,
or an extension installed or removed, reaches an open session as the
lines that went and came, in its next message's `<system-state>` (that
of the next run's first message for an extension, whose tools change
with it).
A project's conversation gets the project once, on the message that starts
its first run (`Session/ProjectContext.swift`): a `<project-context>` block
before the user's text, which the model sees and the app's event does not —
name, ID, kind and language, deployment target, architectures, template,
build system with its steps and products, package, binding, git in one line
— the host's `gitStatus` (branch, HEAD, the changes as `git status --short`
spells them, at most 12 then counted, and `origin` without any credential),
asked before the run starts and waited for at most 3 s, else read from
`.git` itself, naming git_init when there is none — and a breadth-first tree (`ProjectTree`: at most
200 entries, 6 levels, 2000 names a folder, 20,000 names in all; `.git`,
`.DS_Store`, the top-level `Builds`, Apelin's temporary files and what the
`.gitignore` files name left out; `Attachments` shown, not opened; links
listed, never followed), then that message's `<system-state>`. It then lives
in the transcript, so a reopened
session neither repeats nor loses it, and it stays out of the system prompt,
where a changing tree would break the cache. General Chat gets the
environment only.

**Prompt caching** (audited 2026-10-24 against kwwk 0.1.100, `fb74cf5`).
Every provider caches a prefix of the request: the tools and the system
prompt, then the messages. kwwk takes a run's system prompt and tools once,
when the run starts (`Agent.snapshotContext`), so every request of a run
sends the same ones; the tool list is `AgentToolName`'s order and static
text, then the MCP tools, then the agent tool extensions' by extension ID
and manifest order, which change only when an extension is installed or
removed and then only between runs (Agent sessions ▸ Agent tool
extensions); every request carries the session ID as
`sessionId`, which kwwk sends as `prompt_cache_key` (OpenAI's Responses API,
Copilot's GPT route), Codex's `session-id`/`thread-id`, OpenRouter's
`x-session-id` and Grok's `x-grok-conv-id`; Anthropic (API key, Claude
Pro/Max, Copilot's Claude route, Kimi For Coding) gets `cache_control` on
the last tool, the system prompt and the last message block; DeepSeek,
Gemini and other OpenAI-compatible endpoints cache prefixes on their own.
kwwk's request encoders sort JSON keys. `received` and `notice` are events,
never messages: the transcript is kwwk's `messages` alone, changed only by a
compaction and, once, the tool-name migration. The system prompt is taken
once a session (owner, 2026-10-25; `Session/PromptState.swift`): when it
opens, and again only when it is reopened or compacted, where the prefix is
written anew anyway (after a compaction, by the next run that starts; a
mid-run compaction of kwwk's own thus costs one more write of the now small
conversation). For the session's life it stays those bytes: the project's
`AGENTS.md` or `CLAUDE.md`, the skills list, the memory this chat sees,
`# Environment`, the build system and the MCP list are as they were then, and
there is no date and no mode in it. A change reaches the model only in the
next message's `<system-state>`, once, as a delta naming its source —
`memory added (all chats): <title>: <body>`, `memory removed: <title>`,
`skill added: <name>: <description>`, `project instructions: AGENTS.md is
now:` and its text (over 2000 characters: that it changed, and to read it
with file_read), `environment:` and the lines that went and came, `build
system:` — each quote at most 300 characters and the whole at most 4000,
past which it names the sources that changed and the tool that reads each.
What the session's own apelin_memory_save, apelin_memory_delete,
apelin_skill_save or apelin_skill_remove changed is not told again (its
result said it), only the item the call named; a delta carried by a queued
message the run dropped is told again by the next. A steer carries no delta
(kwwk drops one a stopped run never took). The host's enforcement is
untouched: the block only tells the model. Nothing that changes per message
is in the system prompt (the project context is the first message's, the
system state every message's, and the memory section carries no revision),
so neither a Settings edit, a mode switch, midnight nor another chat's write
costs a cache write. Anthropic's cache lives five minutes from the start of
the request that last used it, OpenAI's five to ten of disuse (kwwk's loop
pins `cacheRetention: nil`, so Anthropic's 1-hour TTL and OpenAI's 24-hour
one are out of reach without wrapping `AgentOptions.streamFn`, an owner
decision): a tool call or an approval that outlasts it costs one such write
too, which is why `apelin_conversation_read` waits at most 180 s and is
called again rather than waiting ten minutes. Extra requests: a title
completion (no tools, at most 3000 characters in and 160 tokens out) for the
first message, for later ones until it names the chat (three that name
nothing at most), and on every message while the project still has its
generated name; compaction, automatic at 75 % of the window or
`agentCompact`; nothing at reopen, where the transcript is read back (the
tool-name migration is idempotent) and the next request finds the prefix the
last one cached. Known in kwwk, not worked around:
`ProviderImageBudget.clamp` drops the oldest image one at a time past a
provider's limit (5 for Copilot, Kimi and OpenAI-compatible endpoints, 90
for Anthropic, 200 for OpenAI and Codex), so each later image moves the
change point and rewrites the cache from there (an image dropped so can be
read again with file_read, as one more); and its native compaction
requests (`AnthropicProvider.swift`, `OpenAIResponsesProvider.swift`) are
encoded without sorted keys, so they probably miss the conversation's cache.
The device check is `Documents/Research/Device-Validation.md` ▸ Still to run
▸ Prompt caching.

## Long-term agent memory

`MemoryStore` in ApelinCore owns `memories.json` and `memories.lock` directly
inside the shared data folder. App and mobile agent workers use the same store;
there is no daemon operation or provider-specific memory service. Records have
stable UUIDs, a short title, a body and an optional stable project ID. Nil means
all chats; project records are injected only into that project's sessions.
Settings ▸ Agent ▸ Memories lists both, resolves current project display names,
and supports adding, editing and deleting. User additions apply to all chats;
editing preserves a record's scope. Missing projects remain visible for cleanup
but their records never enter another project's context.

Every mutation rereads under an interprocess file lock and compares a snapshot
revision, then atomically replaces the JSON through the opened data directory.
No snapshot is written back from a cache. A stale create, update or deletion is
refused; a user edit or deletion therefore cannot be undone by an older pending
agent write. Files must be regular, singly linked, owned by the calling mobile
user and not writable by group or others; symlinks are refused. Corrupt data is
reported rather than replaced with an empty library. Titles are nonempty and
single-line; bodies are nonempty. The library holds at most 64 records and
32,768 content bytes.

`apelin_memory_list`, `apelin_memory_save` and `apelin_memory_delete` are local agent tools and run
without an approval prompt. They see all-chat records and the current
project's; a call that names another project with `project` (its projectID
or folder, resolved as the conversation tools resolve it) sees that one's
instead, and `apelin_memory_list{all_projects}` lists every record with its
project's folder and name, `missing` when no project has its id, so General
Chat tidies every project's memory without opening a conversation for each.
A missing project's id still reaches its records, to change or delete, never
to add one, and General Chat, which has no project, keeps a project record
only for the project it names. What the session's prompt and deltas show
stays its own project's, so one project's records never enter another's
context. A session's system prompt carries the records it saw
when it opened and never the revision, which every write changes, another
project's included; a record added, changed or removed later, in Settings or
by another chat, is a delta in the session's next message (`PromptState`),
while one its own call saved or deleted is not repeated, since the tool's
result said so (`PromptCacheTests`). Memory is explicitly untrusted fact
and preference data, never instructions or authorization. The agent is told to
maintain only durable useful facts, avoid secrets and transient conversation,
and not recreate user-deleted facts from older context. Cross-session memory
is separate from transcript recovery and user skills; kwwk model selection and
compaction defaults are unchanged.

## Table updates

The app's UIKit tables use diffable data sources. `TableDataSource` keeps stable
row identities separate from their equatable display content, so unchanged
refreshes leave selection and row actions alone. Every such table is a
`FirstFillTableView` (a page that is one table derives from `TableController`,
never `UITableViewController`; the project picker's list is a
`FirstFillCollectionView`): its first snapshot waits until the list is in a
window at its own width, then goes in and is laid out in that pass without
animation, and every update until then replaces it. Rows laid out earlier are
laid out at a width of zero, and the push or sheet that gives the list its width
stretches them from there. Whether a later change animates is `ListPacing`'s,
after Fila's lists: data that lands within 200 ms of the list's last change or
of the load it answers (`TableDataSource.beginLoad()` where a fetch starts,
`ListPacing.begin()` where a list is about to show other data: another project,
a search) appears without animation, and so does the answer to the list's first
load, however late. Only a list that has sat still in a window for longer
animates its change, and never under Reduce Motion. Every table, the sidebar's,
the memories' and the task log's raw diffable sources included, goes through
both. Form fields and task-stage cells keep their existing views. The sidebar
updates for changed titles, activity or order, rather than each streamed text
fragment. The chat's ListViewKit keeps its own update mechanism.

## Widgets, the Live Activity and `apelin://` links (2026-10-22)

- **Links.** `apelin://conversation/<id>` opens a conversation: `<id>` is its
  agent session ID (what the conversation tools return), or the app's own
  chat ID. `apelin://project/<projectID or folder name>` opens a project on
  its most recent conversation, or a new one. `apelin://chat?prompt=<text>`
  (2026-10-26) opens a new General Chat — the untouched one if there is
  one — with `<text>` in its composer and the keyboard up, and sends
  nothing: the reader reads it and taps Send, so a link from anywhere can
  only suggest a message (≤ 32 KB, no control character but a line break or
  a tab, else `unknown`; without `prompt` the composer is empty).
  `apelin://import?url=<address>&branch=<name>` (owner, 2026-10-31, issue
  #31) is Open in Apelin for a Git repository: a README's button
  (`Documents/Site/open/badge.svg`) links to
  `https://owngoal-dev.github.io/Apelin/open/?url=…&branch=…`, a static
  page (`open.js`, the same checks, no markup from the query) that shows
  the repository, opens this link, says how to install Apelin and copies
  the address. `url` starts `https://`, in lower case, with a host and a
  path, printable ASCII, no user, password, query or fragment, ≤ 2 KB
  (`isRepositoryAddress`);
  `branch` is optional and a name `git check-ref-format --branch` takes,
  no white space or format character (`isBranchName`); each is named at
  most once, anything else is ignored, and a link that fails is
  `invalidImport` ("names no HTTPS repository Apelin can import"). The app
  asks first (`RepositoryImportController`, a form sheet): the address,
  the branch, any project whose `.git/config` origin is the same
  repository (`RepositoryImportPlan.comparable`), to open instead, and the
  name, the repository's own (`suggestedName`), never one a project has.
  Import is `projectCreate` of the empty workspace, then `gitCloneInto`
  followed on the progress card (`RepositoryImporter`); success opens the
  project on a new conversation and sends nothing, and a failure or
  Cancel takes that project away with `projectDelete`. A private
  repository's `authenticationRequired` points to Sign In with GitHub for
  github.com, else to a token given to the agent. One import at a time
  (`RepositoryImportFlow`): a link for the one open does nothing more,
  another says an import is under way. An import link waits through the
  welcome rather than being dropped.
  `apelin://` opens the app as it is. The format is fixed — the agent
  writes these links. `ApelinLink`
  (`Widgets/Shared/ApelinLink.swift`, Foundation only; `Tests/ApelinLink` in
  `make harness`) parses and builds them; the scheme is declared in the
  partial `Apelin/Resources/Info.plist`. `SceneDelegate` hands an `apelin:`
  URL from the connection options or `openURLContexts` to `ApelinLinkRouter`
  and anything else to `TransferOpener`, as before. A link tapped in a
  transcript (`ChatMessageRow`'s `linkHandler`) goes there too, never through
  the system. `RootInterfaceController.open(_:)` resolves it with
  `ChatLinkTarget`: a session the app has no row for is taken in first
  (`ChatAdoption`: in its opener's project, else the project `agentList`
  names), then the conversation is selected in its project (General Chat for
  a temporary one) as if picked, which puts an iPhone's drawer away. A link
  that comes before the conversations are read waits for them and wins over
  the saved selection; one during the welcome is dropped; one that names
  nothing leaves the page as it was and says so in an `SPIndicator`.
- **Widgets** (design approved by the owner, 2026-10-22; the SwiftUI that
  rendered it is the views). `ApelinWidgets.appex` (`Widgets/Extension/`,
  embedded by the app target's Embed Foundation Extensions phase). Small: the
  conversation that most needs a look — waiting for an approval, then
  working, then any other, and among those the one the reader last started
  or wrote in, as the sidebar orders them — with the mark, a status line and its dot
  (`Approve: Install`, 需要授权 · 安装: "Needs Approval · Install" did not
  fit the small widget's one line), the title and the project dimmed; a tap opens
  it, where a waiting approval stands in for the composer. Medium: the
  header with the counts (`2 working · 1 awaiting approval`), up to three
  conversations, waiting and working first, each a `Link`, then `N more
  chats`; a tap elsewhere opens the app. Working is green, waiting amber,
  done grey, failed red (a last turn that finished `failed`, or was cut off
  by its task failing or being interrupted); with no conversation, New Chat.
- **The snapshot.** The extension is sandboxed and cannot read mobile's
  Documents, and the app has no container, so the app writes
  `ChatWidgetSnapshot` to `Widgets/chats.json` in the App Group container
  `group.wiki.qaq.apelin`, which both targets carry — the way Fila's save
  action shares Fila's. `make check` and the packager require exactly that
  group on both, and nothing privileged on the extension (no `no-sandbox`,
  `platform-application`, storage, container or client keys, no Mach
  lookup). The snapshot is ready to draw — status, the project's display
  name, the order, the counts, and no dates, so streamed text writes nothing.
  `ChatWidgetPublisher` (`Apelin/Widgets/`) is attached and told of every
  `ChatRuntime` change by the root, looks at most once a second and only
  once the saved conversations are read, writes and reloads the timeline
  (one entry, policy `.never`) only when the snapshot changed, and reads the
  display names again on `.apelinProjectsChanged`. An untouched New Chat is
  not listed; a deleted conversation, a deleted or renamed project and a
  temporary conversation (General Chat) show as they are on the next look.
  The widgets show what the app last saw: a suspended app follows nothing.
- **The Live Activity.** One while any conversation works or waits; its
  state is the snapshot cut to those (at most four, inside ActivityKit's
  4 KB). The lock screen shows the header and three rows; the island,
  closed, the mark and the count, amber while an approval waits; minimal,
  the mark; expanded, the counts and two rows. A tap opens the conversation
  waiting, else the latest working. It ends when nothing is in progress, and
  in `applicationWillTerminate` (nothing would update it after); one that a
  killed run left is updated or ended by the first look after the next
  launch. iPadOS 26.4 shows it on the lock screen too, after asking once to
  allow Live Activities from Apelin.
- **After installing over an earlier build**, chronod keeps refusing the new
  extension's timelines (`WidgetArchiver.ValidationError.bundleStubNotSupported`
  in its log) and the widgets go on showing their last render until chronod
  restarts — a respring or a reboot; the app's reloads cannot fix it. Seen on
  the iPad vphone, 2026-10-22; the hooks do not restart chronod (they manage
  the daemon only).
- **The floor.** The extension deploys to 16.0 with the app, because a
  jailbreak install registers it whatever its minimum OS says. The home
  screen widget runs from 16.0; the Live Activity from 16.2 (`ActivityContent`,
  as iGhostVT's), with `-weak_framework ActivityKit` on the app and the
  extension so 16.0 and 16.1 load them; `containerBackground` from 17, the
  view's own padding before. The packager requires exactly this appex in
  `PlugIns/` with the app's versions, strips it, greps it for build paths,
  signs it with `Packaging/ApelinWidgets.entitlements` and reads them back;
  `install-device.sh --app` signs it too, and the rpath check takes an
  `.appex` as its own `@executable_path`.
