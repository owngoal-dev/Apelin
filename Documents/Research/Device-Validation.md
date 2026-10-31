# Device validation

What the milestone 1 data layer has been proven to do on a device, where,
and what is still to run. Every Apelin step below ran through the console
(`Documents/Console.md`): a script dropped into
`~/Documents/wiki.qaq.apelin/console/inbox/`, the app brought to the front,
the result read from `console/out/<runID>.jsonl`. Since 2026-10-18 that is
`Scripts/device.py` (`make device-test`; `Documents/Console.md` ▸ From the
Mac), which also does each script's setup, kills and checks, and keeps the
output in `build/Device/<vphone>/`. Those milestone-1 runs exercised the
console while the UI was a scaffold; later UI validation is recorded in the
dated sections below.

"Product path" means the step went through Apelin's own operations end to
end, with irisind doing every install and removal. Nothing in the current
results was registered or installed by hand.

The on-device toolchain retarget itself (Apple's package, stage timings,
memory and disk, the six language checks) is recorded in
`2026-10-17-Toolchain-Retarget.md`, with every other CLT release in
Apple's catalog set up and self-tested by the probe on the iOS 26.6.2
iPhone vphone (▸ Other Command Line Tools releases).

## Devices

| Name | System | Bootstrap | Beside Apelin |
|---|---|---|---|
| iOS 26.4 iPhone vphone | iOS 26.4 | roothide | Irisin 4.7.0, ElleKit 1.2-1, icli 0.9.0, SDK iPhoneOS 26.4 |
| iOS 27.0.1 iPhone vphone | iOS 27.0.1 | roothide | Irisin 4.7.0, ElleKit 1.2-1, icli 0.9.0, SDK iPhoneOS 27.0 |
| iOS 27.0.1 iPad vphone | iOS 27.0.1 | roothide | Irisin 4.7.1, ElleKit 1.2-1, SDK iPhoneOS 27.0 |
| iOS 26.6.2 iPhone vphone | iOS 26.6.2 | roothide | Irisin 4.7.2, ElleKit 1.2-1, SDK iPhoneOS 27.0 and 18.5 |

Packages under test: Apelin (`make deb-roothide`), the app, CLI and tweak
development extensions (`make deb-extensions`) and the agent tools
(`make deb-agent-tools`). The preference bundle extension depends on
preferenceloader, which no vphone has. Nothing here is a result for
rootless, real hardware, the iOS 16 floor, or the iPad's sidebar layout.

## Current results

The first two iPhone vphones, on main after the review rounds (the iOS 26.4
vphone re-ran the whole list as a regression at the end; the iOS 27.0.1
vphone ran it once just before), by hand. The iPad vphone and the iOS 26.6.2
iPhone vphone ran `make device-test SUITE=regression` on 2026-10-18 (build
15), the iPhone from a fresh install with no SDK or toolchain registered;
the iPad ran `t1`, `t2` and `r2` after the toolchain registered there by
hand on 2026-10-17 (no installation) was deleted.
Times are typical for one step; — is not run there.

| Script | What it proves | iOS 26.4 | iOS 27.0.1 | iPad 27.0.1 | iOS 26.6.2 |
|---|---|---|---|---|---|
| hello, `extensionList`, `sdkList`, `toolchainStatus` | apelind starts on demand and answers; the session host and workers come up | pass, 1–14 ms | pass | pass | pass |
| `i1-smoke.json` | PTY as uid/gid 501; protected edit with backup, spent grant and dpkg status refused; install and removal of the fixture deb through irisind, wrong digest refused | pass | pass (install 0.87 s, remove 0.35 s) | pass (install 0.8 s, remove 0.3 s) | pass |
| `terminal.json` | open, resize, attach, close, resize after close refused | pass | pass | pass | pass |
| The terminal's environment | `GIT_CONFIG_COUNT=1`, `safe.bareRepository=explicit` | pass | — | — | — |
| `files.json` | `fileRead` by descriptor; escape `badRequest`, dpkg status `denied`, unknown grant `notFound` | pass | pass | pass | pass |
| `logs.json` | a 5 s live log read in two calls, crash list, open, symbolicate | pass | pass (2.08 s) | pass | pass |
| `i5-log-continuity.json` | 60 s of live log across icli's chunk boundaries: exactly 200 lines, none lost or repeated | pass | pass | pass | pass |
| `diagnostics.json` | screenshot, UI tree, tap, confirmLoaded of a missing build, unknown load check refused | pass (tree 0.4 s) | pass | pass, after bugs 6 and 7 below | pass |
| `tool-host.json`, `i6-tool-attachments.json` | the disassembler extension as mobile; attachment bytes back as a descriptor with the same sha256 | pass | pass | pass | pass |
| `i2-git.json`, `i2-git-commit.json` | clone one branch over HTTPS, status, diff, stage, unstage, commit; refusals | pass | pass (clone 0.7 s) | pass | pass |
| SDK remove and re-import from the inbox; escape and plain HTTP refused | the SDK manager on a real 380 MB SDK | — | pass (import 4.1 s); `i2-sdk-import.json` also passed on the iPad vphone | pass (`i2-sdk-import.json`, 4.3 s) | pass (first import, 3.8 s) |
| `environment.json` | setup started, replayed, cancelled; unknown removals refused | pass | pass | pass | pass |
| `t1-toolchain-setup.json` | Apple's CLT downloaded, retargeted, packaged, installed through irisind, six self-tests as mobile, registered | pass (29 s) | pass (25–33 s) | pass (53 s) | pass (55 s) |
| `t2-toolchain-remove.json` | removed through irisind, second removal `denied`; refused with `conflict` while a project binds it | pass | pass | pass | pass |
| `t4-toolchain-swift.json` (2026-10-19, build 20) | CLT 27.0 set up with Swift beside the registered 27.0, both components passing: six C-family cases (C with `__builtin_available`) and Swift, Swift dylib, Swift async, Swift macro on arm64e against the iOS 27.0 SDK; the `uikit-swift` app created, checked, built debug and release, installed through irisind and removed | — | — | — | pass (setup 49 s) |
| A12Z iPad, iPadOS 26.0.1, roothide (2026-10-19, build 23, by hand) | the iOS 27.0 SDK imported from the inbox; `toolchainSetup` of 27.0 with Swift: download, retarget and install passed, the six C-family self-test cases passed, the four Swift cases trapped on `eor3` (FEAT_SHA3), so the setup was rolled back (`Toolchain-Retarget.md` ▸ Older CPUs) | — | — | — | — |
| CLT 27.0 with the Xcode 27.1 SDK (2026-10-19, build 25, by hand) | the iOS 27.1 SDK imported from the inbox; the Swift toolchain removed and set up again, self-tested against 27.1 (`selfTestSDK` 27.1, `newestSDK` 27): ten cases passed; the `uikit-swift` template bound to SDK 27.1 checked, built debug, installed through irisind and opened | — | — | — | pass (setup 47 s, build 24 s) |
| `t3-toolchain-side-by-side.json` (2026-10-19, build 19) | an iPhoneOS 18.5 SDK imported; CLT 12.4 refused with its reason before any download; CLT 16.4 set up beside the registered 27.0 (its own ID, path and package), six self-tests against 18.5, the default left on 27.0; 16.4 removed and 27.0 still registered and the default; `project-build-install.json` then built with 27.0 | — | — | — | pass (16.4 setup 74 s) |
| `i3-chain.json` | create → check → build → install → `confirmLoaded` with `trigger: respring`: marker confirmed, image `notRead`, the run re-attached to the load-check task after the respring took the app down | pass (build 0.8 s, install 0.3 s) | pass | pass (48 s with the respring) | pass (47 s) |
| `project-build-install.json` | approval digests, build cancel, build, install, removal | — | pass | pass | pass |
| `resume.json` | the app killed mid-follow re-attaches to the same terminal; the run goes on after the respring | pass | pass | pass | pass |
| `r1-resume-build.json` | session host killed during `compile`: one `resumed`, rebuilt from `check` under the same build ID | pass (21 s) | pass | pass | pass |
| `r1-resume-sdk-import.json` | session host killed 1 s into the import of a copy of a registered SDK: one `resumed`, the import done and the SDK answered | — | — | pass (4 s after the resume) | pass |
| `r2-resume-toolchain.json` | session host killed 5 s into setup: one `resumed`, seq continuous, one installation, one toolchain | pass | pass | pass (58 s) | pass (60 s) |
| Retry bound | host killed three times: `resumed` 1 and 2, then `interrupted`, attach fails `taskEnded` | pass | pass | — | — |
| `agent.json` without a credential, agent refusals | `denied` without a credential; `notFound` for every call on an unknown session; `agentRunCode` from the app `denied` | pass | pass | — | — |
| `Documents/Console/demo/` with an openai-compatible (DeepSeek, `deepseek-chat`) credential | credential imported and unlinked; a Relaxed session edits, builds and reports; Confirm asks for `run_code` `uname -a`, waits, runs once after `agentApprove`; abort ends `aborted`; steer lands mid-run; app and CLI templates build, a failing build reports 2 diagnostics. Captured as the replay fixtures | pass | — | — | — |

The session host was killed with `kill -9 $(cat <install
root>/var/lib/apelin/session.pid)` from a loop on the device watching the
run's output (the harness's watcher since 2026-10-18); the proxy started a new host 1–2 s later every time. No crash
report for apelind, its session host, a worker or the app came out of any
run.

The daemon's lifecycle: after a reboot no apelind runs (no `RunAtLoad`, no
`KeepAlive`); the first console request starts apelind and its session host
as root and the workers as uid 501, children of the session host. The idle
exit after the last piece of work has not been timed on a device.

## Bugs the device found

Each was fixed with a test before the results above.

1. The app read the wrong data folder on roothide: `NSHomeDirectory()`
   answers the system's `/var/mobile`, the package and the workers use
   `<jbroot>/var/mobile`. The app now finds the bootstrap from its own
   bundle path (`RoothideRoot`).
2. The terminal's bash crashed before its first prompt: iOS has one locale,
   `UTF-8`, and readline dereferences the null `setlocale` answer under
   `LANG=en_US.UTF-8`. The shell gets `LC_CTYPE=UTF-8`, and a shell that
   dies of a signal ends its task `failed`.
3. The iOS 27 SDK was refused: `CoreImage.metallib` is a fat file of Metal
   libraries, and every fat slice was treated as Mach-O. Non-Mach-O slices
   are data.
4. A respring ended a console run mid-script. A run whose last step was a
   successful respring now goes on at the next launch, once. `respring`
   answers in about 66 ms, before SpringBoard takes the app down, so the
   runner waits up to 15 s for the app to go before it starts the next step.
5. The first UI read after the app came to the front failed "frontmost
   application could not be verified": during a switch, RunningBoard
   reports two focal apps (`several_focal_apps`) for about 0.25 s. Not an
   entitlement. UI reads and targeted actions wait (up to 3 s) for the same
   verified app on two reads in a row.
6. A followed task that had ended `succeeded` was reported as a timeout
   after 0.3 s (`i1-smoke`'s terminal, once, on the iOS 27 iPad vphone): the
   console's watchdog, cancelled when the task ended, woke from its
   `try? await Task.sleep` and cancelled the finished reader, and the runner
   read `isCancelled` after it had. The watchdog now answers whether it
   fired. It never reproduced on a Mac.
7. On the iPad, bringing Apelin to the front through Settings left Settings
   beside it with the focus (iPadOS 26 windowing): the UI tree read
   Settings, `diagnostics.json`'s tap at (4, 4) hit Settings' window close
   control, and Apelin was suspended with its load-check follow stalled.
   The harness now quits an idle app and launches it, brings a stalled app
   back to the front, and the script taps (200, 4).
8. `r1-resume-sdk-import.json` expected the import to be still `running` 20 s
   after the kill; on the iPad vphone the resumed import of a registered SDK
   took 4 s. The final `succeeded` and the `resumed` event prove the resume,
   so that expect is gone.
9. On both real devices every toolchain record outlived its package: all
   twelve packages had been removed from outside Apelin, and roothide's
   package removal leaves each folder behind with the `.jbroot` link it
   puts there. `toolchainStatus` reported the empty trees as healthy and
   `toolchainRemove` refused them forever ("no longer installed"), since
   the folder still existed. A tree with no regular file left now counts
   as gone in both (`ToolchainService.exists`), so the record is dropped.

## The image list is never read: three kernel panics

`confirmLoaded` was designed to read the target's loaded images as a second
piece of evidence beside the marker line. On the iOS 27.0.1 vphones it
panicked the kernel three times on 2026-10-17, always with the same
signature, the panicked task `apelin-diagnostics`:

```
panic(cpu 0 caller …): VM entry … lock is invalid (0) <v:0 c:-- w:-- -/0> @vm_entry_lock.c:168
Panicked task …: pid …: apelin-diagnostics
```

1. Twice on the iPad vphone, reading SpringBoard's image list while
   apelin-diagnostics carried `com.apple.system-task-ports.read` and read
   dyld's image infos through the task read port
   (`mach_vm_read_overwrite`).
2. With that reader and the entitlement removed, once more on the iPhone
   vphone through the region-path walk alone
   (`proc_pidinfo(PROC_PIDREGIONPATHINFO)` over SpringBoard's regions),
   asked for deliberately with `imageCheck: regionPaths`.

The kernel backtraces were not symbolicated. Both readers are gone, the
image evidence is always `notRead`, `imageCheck` is refused with
`badRequest` before a task starts (`i3-image-check-refused.json`), and only
the marker `ApelinLoaded <buildID>` heard on the live log, plus the static
filter check, decides `loaded`. Do not add an image reader back without a
safe mechanism proven on that kernel. The run that panicked was left in
`console/running/` and would have been resumed at the next launch; the
console now goes on after a restart only past a successful respring.

## Known limitations seen on a device

- icli's `app frontmost`, `log crashes` and `log crash` answer
  `device_locked` while the screen is locked (icli's own lock policy;
  `log syslog` still runs). Apelin's worker links IcliKit and does not go
  through that gate.
- An interrupted toolchain setup leaves its job record and
  `Environment/staging/<taskID>/` until the next setup of the same source,
  which clears them.
- Only the `ApelinLoaded` marker is checked; whether the template's hook
  ran (`ApelinHooked`) is not part of the evidence.
- Procursus' PreferenceLoader 2.2.8 on the iOS 26.4 iPhone vphone added no
  row for an installed pane, neither in Settings' list nor under Apps, so
  a Settings row and its icon are seen only on an older iOS.

## Still to run on the owner's devices

- [ ] Each conversation's diagnostic journal (2026-10-31, issue #27,
      AGENTS.md ▸ Agent sessions; only the Mac's `SessionJournalTests`,
      `LogRedactionTests` and `Tests/Journal` have run). After `make
      vphone`, on the iPhone and the iPad vphone: in a project's chat, a
      call that runs (file_read), one declined under Strict, one stopped
      while it waits, and Compact…; Settings ▸ About ▸ Logs lists the chat
      under Chats by its name, its page shows the Session, Model, Tool,
      Approval and Compaction lines, a call ID typed in the search field
      finds its `Started` and `Ended` lines (succeeded, denied, cancelled),
      and Share sends `apelin-agent-<session>.log` with no key, home path
      or jbroot in it. `kill-host` while a shell_run sleeps, then a message
      in the same chat: the call's `Ended … status=interrupted` line. On a
      Copilot GPT model where #26's compaction fails, the Compaction line
      says `Failed … status=400` with the provider's words, and the app's
      journal for that launch has the `Conversation` line with the session.

- [ ] `apelin-project.json` in its written form (2026-10-31, issue #30,
      AGENTS.md ▸ The written form; only the Mac harness has run). On a
      vphone with the package installed (`make vphone`): a project with a
      one-line manifest (rename one made before this change, or write it
      on one line from the terminal) builds, its build log says
      "formatted apelin-project.json", the file is two spaces a level,
      every value and its order as before, mobile still owns it, and a second
      build leaves it alone; under Strict that first build asks nothing
      the template's digests did not. A new project, a workspace, a
      rename and apelin_project_set_environment each write it formatted.

- [ ] Open in Apelin for a repository (2026-10-31, issue #31; only the
      Mac harness's `Tests/ApelinLink` and a node run of the landing
      page's checks have run). After `make vphone` (iPhone and iPad):
      from a README, `https://owngoal-dev.github.io/Apelin/open/?url=…`
      shows the repository and Open in Apelin opens the sheet filled in,
      with the app cold and running; Import makes the project, clones it
      on the progress card and opens it on a new conversation that sends
      nothing; Cancel on the sheet makes nothing and Cancel on the card
      leaves no project; `&branch=` checks that branch out; a private
      github.com repository without a sign-in offers Settings ▸ Git and
      leaves no project; a malformed link says it names no repository; a
      second tap of the same link brings nothing new up and another
      link's says an import is under way; a repository imported before
      offers Open; a link during the welcome is shown once it finishes;
      the page without Apelin installed explains how to get it and copies
      the address.

- [ ] A forced push with a lease (2026-10-31, issue #29; the Mac only so
      far: `GitLeaseTests`, `GitForcePushServiceTests`, the session host's
      checks, `ForcePushToolTests`, `ForcePushBackendTests`, the transcript
      harness's `ForcePushCardCheck`). On a device: `i2-git-remote`'s two
      new lease refusals; then, with a GitHub account and a scratch
      repository whose `main` has a commit the project lacks, a chat asked
      to force-push `main` there shows the Force-push to the remote card in
      Relaxed and Full as in Strict, naming the commit replaced, the one
      sent and the commits lost; Approve overwrites `main` on GitHub; a
      commit pushed to the scratch repository from elsewhere between the
      card and Approve ends with nothing pushed and the agent asking again;
      a protected `main` answers in GitHub's words.
- [ ] A preference bundle's Settings row with its icon (2026-10-30, issue
      #19, `wiki.qaq.apelin.dev.preferences` 0.1.3), on a device where
      PreferenceLoader shows panes (the owner's iOS 17.3.1 iPhone): a new
      project from the template, built and installed, shows the plate
      beside its name in Settings.

- [ ] Deleting a conversation (2026-10-30, AGENTS.md ▸ The root
      and ▸ Project display names and external project actions; only the
      Mac transcript harness's `ChatDeletionCheck` has run). On the iPhone
      (`VPHONE=Date`) and the iPad (`VPHONE=Banana`) vphone, after `make
      vphone-app`. In the sidebar, a New Chat holding only a typed draft,
      a pinned New Chat, and a conversation swiped the moment its first
      message is sent (still "New Chat" and spinning): each swipes to a
      red Delete, with Stop beside it while it works, and its long press
      ends on Delete. Delete on one at rest goes at once, the picked one
      leaving the icon beside the iPad's sidebar and a new conversation
      behind the iPhone's drawer. Delete on one that works, and on one
      waiting for an approval, asks "Delete Conversation?", saying it is
      still working, with Stop and Delete: Cancel leaves it running, Stop
      and Delete stops it (no more output) and the row goes. From the
      chat's `…`, in a project's chat and in General Chat: Delete
      Conversation… is last, red, in a group of its own; it asks, naming
      the conversation, Cancel keeps it, and Delete takes it, the page
      then as the sidebar's Delete leaves it; while a turn runs the
      question says so and its button is Stop and Delete. A deleted
      conversation leaves no banner in Notification Center and goes from
      the widget on its next look. VoiceOver offers Delete (and Stop) among
      a row's actions and reads Delete Conversation… in the menu; in
      Chinese they read 删除 / 停止并删除 and 删除聊天….
      Run so far (2026-10-30, build 24 from CI): on the iPad 26.4 vphone
      the menu ends with Delete Conversation… in red, it asks naming the
      conversation, and Delete took the row and its file, leaving the icon
      beside the sidebar; on the iPhone 26.4 vphone the same from a
      General Chat, leaving a new conversation behind the drawer. The
      sidebar's swipe, a working conversation's Stop and Delete, the
      widget and VoiceOver are still to run.
- [ ] Ask Before Using the Screen (2026-10-30, AGENTS.md ▸
      Product ▸ Approval, Approvals ▸ The screen; none has run on a
      device, and it needs a model provider). On the iOS 26.4 and iOS
      27.0.1 iPhone vphones (roothide) and the iPad vphone: Settings ▸
      Permission Mode shows the switch under the modes, on, with its
      footer, and VoiceOver reads it as one switch with its state. With it
      on, in Relaxed and again in Full, ask a project's chat to report a
      problem upstream: before anything opens, the reply says what it
      would open and why and waits; once told to go ahead, `icli url open
      https://github.com/…/issues/new` asks on a card ("Opens … on this
      device …", no "for this session") and Approve opens Safari; an
      apelin_screen_read_tree and an apelin_screen_interact each ask the
      same way, every call, and Deny leaves the screen as it was. The
      next message's `<system-state>` names the setting on. Turned off,
      the next message's state says off and the three run as the mode
      says: no card in Relaxed or Full, Strict's own card. A conversation
      the agent opens asks as its opener does. The console's own
      `readUITree` and `uiAction` (`diagnostics.json`) run as before
      either way.
      Run so far (2026-10-30, build 24, iPad 26.4 vphone): Settings ▸
      Permission Mode shows the switch on, with its footer. The rest is
      still to run.
- [x] The reader's line through a sidebar toggle (2026-10-30, build 24,
      iPad 26.4 vphone, AGENTS.md ▸ the page's width change,
      `readingPlace`): a one-row reply of sixty paragraphs scrolled to
      sections 38–42; hiding the sidebar kept sections 38–44 in view where
      the reader was, and showing it again put back exactly the first
      screen.
- [ ] Agent tool extensions in a conversation (2026-10-29, AGENTS.md ▸
      Agent sessions ▸ Agent tool extensions; none of it has run on a
      device, and it needs a model provider). On roothide and rootless,
      with the Disassembler 1.1.0 and Assembler 1.0.0 packages installed,
      open a project's chat: its tools are `assemble`, `disassemble` and
      `symbols`, and asked what it has, the model names both extensions.
      Under Strict each call asks, the card naming the extension, and
      "for this session" lets the same call run again without a card. Ask
      it to assemble `ret` for arm64 (`c0035fd6`), to list the defined
      symbols of a binary it built (the absolute path, `Builds/…`), to
      disassemble that binary's `_main`, and for `symbols` with `output:
      file`: the listing shows in the conversation as a card that opens
      in Quick Look, and file_read reads the `Attachments/` copy the
      result names. Ask it to disassemble a symbol the binary lacks: the
      call fails with the Disassembler's own words. Kill the extension's process
      while the chat is open (`killall apelin-disassembler`): the next
      call opens it again and answers. Remove the Assembler package with
      the chat open: the next message's tools have no `assemble`, and the
      model was told it went; install it again and it comes back. Close
      the chat: no `apelin-disassembler` process is left.
      Run so far (2026-10-29, build 23 from CI, iOS 26.4 iPhone vphone,
      roothide, Relaxed, deepseek-v4-pro through an OpenAI-compatible key):
      a headless project chat called `assemble` (`ret` for arm64: `c0 03 5f
      d6`), `symbols` on `/usr/lib/dyld` (`__dyld_start` at `0x30f0`) and
      `disassemble` there (four instructions), each answered, and the
      reply quoted them. The rest is still to run.
- [ ] Distribute on the distribution build page (2026-10-29, AGENTS.md ▸
      Project display names and external project actions; none of it has
      run on a device). A release build on the iPhone and the iPad vphone,
      on iOS 26 and iOS 27: while it runs, Stop, and after a failure,
      Retry, as before; once Ready to Distribute completes, Distribute is
      the bar's trailing item, in the prominent style (a bold title before
      iOS 26), its menu Share Package and Publish to Repository, and the
      `…` menu has the same two above Build Log. Share Package from either
      menu opens the share sheet, on the iPad pointing at the item it was
      chosen from. With no package repository linked, Publish to
      Repository shows "No Package Repository" at the top and opens
      Settings at Git over the build page, Back leading to Settings:
      signed out of GitHub it offers Sign In…, signed in Create
      Repository… and Link Repository…; with one linked, closing Settings
      leaves the build page as it was and Publish to Repository asks to
      publish to it. In Chinese the labels read 分发, 分享软件包 and
      发布到仓库.
- [ ] Publishing packages already built (2026-10-29, AGENTS.md ▸ Project
      display names and external project actions; none of it has run on a
      device). With release builds of the current version for roothide and
      rootless (the agent's, or two distribution builds), Distribute…
      lists both under Packages as Built and selected; Publish to
      Repository names the repository and both packages, and one publish
      task commits both, nothing built again. Back on the page both read
      Published and are no longer selected; picked and published again,
      both are skipped.
      Share Package on a row (and the row's VoiceOver action) shares that
      `.deb`; a completed share reads Shared, a cancelled one stays Built.
      Raising the version takes the rows away until it is built again; a
      deb deleted from `Builds/` takes its row away. Build for a target
      whose package is listed asks nothing when the version packaged
      before is its only warning. With no repository linked, Publish to
      Repository opens Settings ▸ Git.
- [ ] Packages published by the agent (2026-10-29, AGENTS.md ▸ Agent
      sessions ▸ Publishing; none of it has run on a device, and it pushes
      to a real repository, so by hand only, on a test repository linked
      in Settings ▸ Git ▸ Publishing). `make device-run SCRIPT=distribution`
      still refuses a file outside `Builds/`. A project chat asked for
      release builds for roothide and rootless, then to publish them:
      apelin_package_publish with both build IDs, under Strict one card
      naming the repository and both packages with their digests and no
      "for this session"; Approve adds both files to `debs/` in one
      "Publish …" commit that reaches GitHub, nothing built again, and the
      reply names the source address. Asked again: both "already
      published", no new commit. A debug build, a build whose `.deb` was
      deleted, and the same build twice are refused before any card; a
      `.deb` changed after its build is refused and none goes in. Unlinked:
      the agent names Settings ▸ Git ▸ Publishing; signed out: Sign In with
      GitHub. In Relaxed, no card, and still no publication the user did
      not ask for. Remove the test packages afterwards.
- [ ] A GitHub repository made by the agent (2026-10-29, AGENTS.md ▸ The
      environment worker ▸ Git and Agent sessions; none of it has run on a
      device, and it makes repositories on a real account, so by hand
      only). `make device-run SCRIPT=i2-git-remote` refuses a bad name
      (`badRequest`) before anything reaches GitHub. Signed out of GitHub,
      ask a project's conversation to open a private repository for it:
      apelin_git_create_repository answers that GitHub authorization is
      needed and names Sign In with GitHub in Settings ▸ Git, and nothing
      is made. Signed in: asked for "a repository" without a visibility,
      the agent asks public or private before calling the tool; under
      Strict the card names the owner, name and visibility, offers no "for
      this session", and Approve makes one empty private repository on the
      account, which the model links; the model then calls git_push with
      that clone URL, which asks again, and the push lands as `origin` and
      the branch's upstream. Again with an organization the account may
      create in, and one it may not (GitHub's refusal in its words), and a
      name the account already has (`conflict`). In Relaxed, no card, and
      still no repository the user did not ask for. Delete the test
      repositories afterwards.
- [ ] A project deleted by the agent (2026-10-29, AGENTS.md ▸ Project
      display names ▸ Deleting a project; none of it has run on a device,
      it needs a model provider, and it deletes, so by hand only, on a
      throwaway project). In General Chat, "delete the project <name>"
      under Strict: one card naming the folder and the name the sidebar
      shows and saying it cannot be undone, with no "for this session";
      Approve removes `Projects/<folder>` whole (a link inside it removed,
      what it named left), its running conversation stopped first, and the
      sidebar, All Projects, delivered banners and the widget no longer
      show the project or its chats, the open page going to General Chat
      when it showed that project; `Builds/<projectID>/` stays, as after
      the app's own Delete. Deny deletes nothing. Relaxed and Full delete
      without a card. From the project's own chat it is refused with where
      to delete it instead, in every mode, nothing asked. A project's folder
      removed while the app is closed (by Fila) has its chats gone at the
      next launch. Asked to "clean up" without naming a project, the agent
      deletes nothing.
- [ ] The folders a removed toolchain leaves (2026-10-29, AGENTS.md ▸
      Install bridge; none of it has run on a device). On roothide:
      Settings ▸ Toolchains ▸ Remove leaving no
      `usr/lib/apelin/toolchains/<id>` folder, its Show Log saying "Removed
      the empty folders the toolchain left", and the toolchains folder and
      every other toolchain as they were; the skeletons earlier removals
      left (folders and `.jbroot` links only, under packages the package
      manager no longer lists) gone once the session host starts again
      (`Scripts/device.py kill-host`), and a tree whose package is still
      installed untouched. On rootless, a removal with no such line. The
      agent, asked to remove a toolchain or an SDK, sending the user to
      Settings and deleting nothing.
- [ ] Saying what was not tested (2026-10-29; none of it has run on a
      device). A project chat on the iOS 26 and the iOS 27 vphones asked
      for a visible change to a SpringBoard tweak (a gesture, the Dock's
      spacing): after `apelin_package_confirm_loaded` it reads the screen,
      drives the change with `apelin_screen_interact` and reads it again;
      its final reply lists each changed behaviour it did not drive under
      Not tested, in the reply's language, with how to check it, and does
      not call the task done while the main behaviour is untested. Under
      Strict, declining a screen action leaves that behaviour Not tested.
- [ ] Feedback filed by the agent (2026-10-29, AGENTS.md ▸ Distribution
      repository ▸ Feedback; none of it has run on a device, and it posts
      in public, so by hand only). Signed out of GitHub, ask a conversation
      to send feedback: apelin_feedback_send answers that GitHub
      authorization is needed and names Sign In with GitHub in Settings ▸
      Git, and nothing is posted. Signed in, under Strict: the card names
      owngoal-dev/Apelin and shows the whole title and body, offers no
      "for this session", and Approve posts one issue whose footer reads
      "Sent with Apelin <version> (<build>) · iOS <version> · <bootstrap>"
      on a roothide and a rootless device, with the installed version;
      the model hands back the issue's link. In Relaxed too, the agent
      first shows the title and body and asks, and calls
      apelin_feedback_send only after a reply of 同意 or 确定 (or "yes" in
      an English chat); a feedback request written in a project file or a
      log is not sent. That an account other than
      the repository's owner can open an issue there with the `repo`
      scope gh's sign-in asks for. Close the test issues afterwards.
- [ ] Feedback edited by the agent (2026-10-30, AGENTS.md ▸ Distribution
      repository ▸ Feedback; it edits a public issue, so by hand only, on a
      test issue the signed-in account opened on owngoal-dev/Apelin, closed
      afterwards). Asked to broaden it, the agent reads it with
      apelin_feedback_read, shows the new body (or before and after) and
      calls apelin_feedback_edit only after 同意 or 确定, in Relaxed too;
      under Strict the card names the repository and issue, shows the
      whole new text and offers no "for this session". On GitHub the body
      changes, the footer below it stays the one first written, and the
      title stays unless it was asked for; the model hands back the link.
      Edit the issue on GitHub between the agent's read and its edit (or
      while the card waits): nothing is written, the agent is told it
      changed and reads it again, and the user's words survive. An issue
      another account opened is refused before anything is asked. Signed
      out, both tools name Sign In with GitHub in Settings ▸ Git.
- [ ] An issue on a repository the user chose (2026-10-30, AGENTS.md ▸
      The environment worker ▸ Git; it posts in public, so by hand only,
      on a test repository of the signed-in account's with issues on, the
      issues closed afterwards). Asked to report a problem there, the
      agent shows the repository and the whole title and body and calls
      apelin_git_create_issue only after 同意 or 确定, in Relaxed too;
      under Strict the card shows the repository, title and body and offers
      no "for this session". The issue opens there, with the footer "Sent
      with Apelin <version> (<build>) · iOS <version> · <bootstrap>", and
      the model hands back its number and link. With issues turned off on
      the repository, and for a repository the account cannot see, the
      agent says what blocks it and posts nothing elsewhere, opens no
      browser and drives no screen. Asked to file on owngoal-dev/Apelin, it
      goes through apelin_feedback_send. Signed out, it names Sign In with
      GitHub in Settings ▸ Git.
- [ ] The star prompt (2026-10-29, AGENTS.md ▸ Distribution repository ▸
      The star; it stars a real account, so by hand only). Signed out of
      GitHub, ten builds that succeed ask nothing and count for nothing.
      Signed in with an account that has not starred owngoal-dev/Apelin:
      the first nine builds that succeed after that (agent builds and
      distribution builds alike; failed builds and a reopened
      conversation's replay add none) ask nothing, the tenth asks "Do You
      Like Apelin?" with Maybe Later on the left and Star Now on the
      right, in Chinese 下次一定 and 立即标记. Maybe Later asks again ten
      builds later, on another day, and after the third time never again;
      Star Now stars the repository on that account, says Thank You and
      never asks again. An account that has starred it already is never
      asked. The state is `starPrompt.state` in the app's preferences;
      unstar the repository afterwards.
- [ ] Waking the device from the agent (2026-10-29; none of it has run on
      a device). A wake and a lock round trip on the iOS 26 and the iOS 27
      vphones, iPhone and iPad, with no passcode: `uiAction` `press`
      `lock` from an unlocked screen turning it off and locking it, then
      `readUITree` and a `home` press refused as "The screen is off.", a
      wake lighting the screen past the lock screen (`locked` and
      `screenOff` false), a lit lock screen refused as "The device is
      locked.", and `home` from an app reaching the home screen. The
      `diagnostics` script's wake on an awake device answering `screenOff`
      false and changing nothing. apelin-diagnostics carries fewer
      entitlements than the icli CLI: that its wake (SpringBoardServices'
      undim, then a HID home press) lights the screen as `icli button
      wake` does. On an iPhone with a passcode: a wake leaving the lit lock
      screen with `locked` true, and the agent asking the user to unlock it
      rather than for the passcode; whether a screenshot of that lock
      screen comes back. The agent waking the device by itself to check a
      lock-screen tweak.
- [ ] A tweak filtered to another app from its creation (2026-10-29,
      AGENTS.md ▸ Agent sessions; none of it has run on a device). In
      General Chat, ask for a tweak that loads into Settings:
      apelin_template_list shows the tweak template's `filterBundles` with
      its default `["com.apple.springboard"]`, apelin_project_create takes
      `{"filterBundles": ["com.apple.Preferences"]}` in `values` the first
      time, the new project's `package.tweakFilter.bundles` is
      `["com.apple.Preferences"]`, and its first build does not ask in
      Strict. Before this, every such call was refused ("each value must be
      a string, boolean or integer") and the model kept the SpringBoard
      filter without saying so. Then ask for one loading into 33 apps, one
      more than a tweak's filter holds: if it does anything but ask, the reply
      says plainly what it did instead (fewer apps, say) and what is left,
      as the prompt's `# Responses` asks.
- [ ] An agent kept off Apelin's own screen, and a repository imported
      from any chat (2026-10-29, AGENTS.md ▸ Diagnostics and ▸ Agent
      sessions; none of it has run on a device; needs a model provider).
      With Apelin in front, apelin_screen_interact's tap, swipe and typed
      text are refused, nothing on Apelin's screen changing, in Relaxed,
      in Full and in Strict after Approve; target_id wiki.qaq.apelin is
      refused too; with Settings in front the same tap goes through; the
      console's `diagnostics` script, whose tap is the app's, still runs.
      In General Chat and in a tweak project's chat, "import <an HTTPS
      repository>" makes an Empty workspace and opens its conversation,
      which clones the repository with git_clone, never a template project.
- [ ] Messages queued during a run (2026-10-29, none of it has run on a
      device; needs a model provider). Two messages sent while a reply
      runs, a third typed and not sent, then Stop: the composer holds all
      three, oldest first, with the first two's files, and "2 Messages Not
      Sent" shows (and VoiceOver says it); the same with the conversation
      in the background, said when it is opened; a run that fails with a
      message queued (a provider error, Wi-Fi off) followed by a run that
      takes the message, nothing put back.
- [ ] file_read showing images (2026-10-29; Mac tests only, needs a model
      provider). On the jp vphones (iOS 26.4 and 27), in a conversation
      with a model that takes images: a screenshot sent with a message
      read again by file_read from its `Attachments/` path several turns
      later and described correctly; a downloaded animated GIF over
      512 KB read at frame 0 and at a later frame; an iPhone HEIC photo put
      in the project coming back upright as JPEG; a frame extracted from a
      video with ffmpeg through shell_run (where ffmpeg is installed)
      read and described; a Mach-O still refused with the image hint. The
      picture landing in the transcript's album each time, and a
      provider without vision (DeepSeek) answering from the summary line
      alone, without an error.
- [ ] Installations from any conversation (2026-10-29, none of it has run
      on a device). `installationList` in `project-build-install` and
      `i3-chain`; apelin_package_list in General Chat and in another
      project's chat naming the i3 chain tweak's installation and project;
      apelin_package_remove with only `package_id` there, the Strict card
      naming the package, version and project, then the package gone; a
      stale installation id refused before asking, with what Apelin can
      remove instead; a toolchain listed as not the agent's and its
      removal refused.
- [ ] A turn the network failed (2026-10-29, AGENTS.md ▸ Agent sessions
      ▸ `NetworkRecovery`; none of it has run on a device). Send a message
      that runs a few tools and turn on Airplane Mode while it runs, for
      about a minute: the running summary reads "Reconnecting…" (正在重新连接…)
      and VoiceOver reads it as the title; once Airplane Mode is off the
      turn goes on by itself, with no error row and no 继续, and the trace
      lists each call once. Turned on mid-reply, the partial text goes and
      the reply comes back once, never under it. With Airplane Mode left on
      past about three minutes the turn still ends with the provider's
      error. Stop during "Reconnecting…" ends the turn at once, as
      stopped. An "An SSL error has occurred" seen again after this is a
      handshake that failed three times; note the network it was on.
- [ ] shell_run's argv on the toolchain's PATH (2026-10-29, AGENTS.md ▸
      Agent sessions ▸ `agentRunCode`; none of it has run on a device). In
      a project with a toolchain set up, `argv` `["clang", "-c", "x.c"]`,
      `["nm", "x.o"]` and `["otool", "-hv", "x.o"]` run by name;
      `["clang++", "x.cpp", "-o", "x"]` links libc++ (the link runs under
      its own name, not as clang); with Swift, `["swiftc", "x.swift"]`
      compiles; the tool directory's absolute `clang` and `["./build.sh"]`
      in the project run; a name on no directory says where it looked and
      names `bash -c`. In Strict each still asks; `root: true` with
      `irisin-cli` still runs the bootstrap's.
- [ ] apelin_web_fetch (2026-10-29, proven on the Mac against a stubbed
      session only, `WebFetchToolTests`). On a device: a chat asking for a
      project's GitHub page and a raw file reading them as text, with
      links and code blocks; a page over 32 KB read on by its offset; in
      Strict, the card naming the address, and Allow for This Session
      letting the same address through again; `http://192.168.1.1/` and
      a redirect to it refused without a request; the worker reaching the
      network as mobile where the app's own policy is off (it is bound by
      bundle ID, Gotchas ▸ the app was offline); the trace titled "Read
      <site>" in each language.
- [ ] Showing a project file with `file_show` (2026-10-29, none of it has
      run on a device). Asked to see an image, a PDF and a log, the agent
      calls `file_show`, which runs without asking in Strict mode; the
      image comes up in an album and the PDF and the log as cards under
      the call, each opening in Quick Look; the trace names the call
      ("Show notes.pdf", "Show 3 files"); a copy stays as it was after the
      agent edits the file; the same in General Chat; and the conversation
      reopened after the session host restarts still shows them.
- [ ] Every project's memory from one chat (2026-10-29, none of it has
      run on a device; needs a model provider). In General Chat, asked to
      tidy every project's memories: one apelin_memory_list with
      all_projects naming each record's project, a record of a deleted
      project marked missing, then saves and deletes naming each project,
      with no conversation opened and no card in Strict; Settings ▸ Agent ▸
      Memories showing each change under its project. A General Chat save
      of a project fact without a project refused, then made with one.
- [ ] A refused install names the package in its way (2026-10-29,
      AGENTS.md ▸ Install bridge; none of it has run on a device). Build
      and install a tweak, change its `package.id`, build and install
      again: the install fails with "<dylib> already belongs to <old id>
      <version>, which Apelin installed (installation <id>). Remove that
      installation first, then install again." and Irisin's own words
      after it; the agent's apelin_package_install result carries
      `conflicts` with that `installationID`, apelin_package_remove of it
      asks under Strict, and the install then goes through. Then, with the
      old package installed again, name its ID in `package.conflicts`
      instead: the failure says the installer does not remove it, and
      names the installation. Once on roothide and once on rootless, whose
      lists spell paths `/var/jb/…`.
- [ ] The read tools outside the project and the Preferences declarations
      (2026-10-29, AGENTS.md ▸ Agent sessions; none of it has run on a
      device). Under Strict, in a preference bundle project's chat:
      file_read of
      `<install root>/usr/share/apelin/development/wiki.qaq.apelin.dev.preferences/support/include/Preferences/PSListController.h`
      and file_grep of an SDK's `usr/include` by the path `# Environment`
      names, each with no card; file_find there naming whole paths that
      file_read takes back; file_edit of the header refused. On both
      bootstraps, with the preferences extension 0.1.1 installed: a pane
      that builds a switch row with
      `+preferenceSpecifierNamed:target:set:get:detail:cell:edit:`
      (`PSSwitchCell`), sets its `key`, `defaults` and `default` with
      `setProperty:forKey:`, and adds it with `insertSpecifier:atIndex:animated:`
      builds, shows a switch in Settings and stores its value; then a
      class-dump of the device's Preferences framework against the header's
      `PSCellType` values and every method it declares.
- [ ] Screen actions that wait and read back (2026-10-29, none of it has
      run on a device). apelin_screen_interact's type_text into a text
      field at icli's 30 ms a character, "Hello world" arriving whole and
      `typedTextMatches` true with the field's value in `fieldValues`;
      the same into a search field, a text view and a secure field (what
      its value reads as), and with the field not focused (`fieldValues`
      empty); a slower keyboard or an IME, where 30 ms may not be enough
      and the read-back is what shows it. An action with `target_id`
      sent right after another app was opened, waiting for that app
      rather than refused; tap_element on a menu item while the menu is
      still animating in, tapped once; a swipe with `duration_ms` 1200.
- [ ] The trace sheet as a list (2026-10-28, none of it has run on a
      device). A summary's Trace opening an inset grouped list, one row
      per step in order — "Thoughts", each call's title, an approval's
      operation — over one line of detail, both cut to one line, a
      disclosure only on a step with more; a row pushing that step's whole
      text, selectable, with Look Up, Share and Translate on a selection,
      and a written file shown whole; during a run, rows added and a
      thought's line filling without the list jumping, and an open
      thought's page growing below where the reader is; VoiceOver reading
      each row's two lines once, then the page's text; a larger text size;
      on the iPad, the sheet keeping its size on the push and the pop.
- [ ] The app's own network, prompt links, icli and the sign-in buttons in
      the dark (2026-10-26, build 77). On the iOS 27.0.1 iPad vphone
      (roothide, Irisin 5.0.0, icli 0.9.2), 0.1.8 → 0.2.0 went in through
      irisind with the new `com.icli.icli` dependency satisfied, and the app
      launched; `icli app network get wiki.qaq.apelin` read both policies
      allowed and the journal had no `Network` line, as it should when
      nothing needs opening. `uiopen 'apelin://chat?prompt=…'` with the app
      running, and again from a cold launch: a new General Chat each time
      (a chat holding a draft is not reused), the text — Chinese too — in
      the composer with the caret in it, nothing sent. Still to run: on an
      iPhone where Sign In with GitHub said "The Internet connection appears
      to be offline", the journal's `Network` line saying what the policy
      was and that it was opened, then the GitHub code arriving; the
      keyboard rising on an iPhone (the vphone has a hardware keyboard); a
      link during the welcome dropped; the agent listing `apelin-icli` and
      running `icli device info`; in the dark before iOS 26, the GitHub and
      provider sign-in pages' button reading black on white.
- [ ] GitHub, git and the package repository (2026-10-25). On the iOS
      27.0.1 iPhone vphone (roothide, Irisin 5.0.0; 0.1.8 → 0.1.9 installed
      through irisind), the smoke suite passed with `git-auto` (a new
      workspace on `main`, `gitInit` refused, a commit with `all` leaving it
      clean), `distribution` and `i2-git` (`gitInit` on a clone refused);
      the welcome flow's GitHub page and Settings ▸ Git drew as designed,
      Publishing greyed out while signed out; Sign In with GitHub fetched a
      real code from github.com and opened GitHub's sign-in page in the
      sign-in browser. Still to run, which needs a GitHub account: the
      approval finishing the sign-in, the account listed, a private clone
      and a push with it, and Sign Out. A new project's first conversation
      saying "on branch main, no commits yet", and the agent committing
      after a build without being asked (needs a model provider). Create Distribution Repository: the
      repository on GitHub, its workflow's first run green and the source at
      `https://<owner>.github.io/<name>/` added in Sileo and Irisin; Link of
      an existing repository; a release build's Publish to Package
      Repository showing the package in the source within ten minutes.
- [ ] Apelin's own files out of git, and a first push (2026-10-29; the Mac
      only so far: `GitRemoteServiceTests`, `GitBackendTests`,
      `GitToolTests`). On a device: a new project's `.git/info/exclude`; a
      chat that sent an image, in a project made before, whose `git_status`
      shows no `Attachments/`; `git_status` on a project with no repository
      naming git_init; `i2-git-remote`'s two new refusals; and, with a
      GitHub account, the agent asking for an empty repository's address
      and `git_push` with `url` adding origin and pushing to it.
- [ ] The climbing token count (2026-10-25; needs a model provider, which
      the iOS 27 vphone had none of): at the summary row's right
      edge, rising over five seconds while a turn thinks and catching up in
      half a second once the reply streams; a long finished title fading
      under it on an iPhone; right to left with the arrow at the left edge.
- [ ] Root agent commands and Full mode (2026-10-24, root round). On the
      iOS 26.4 iPhone vphone, which has no passcode, build 45 ran it in
      Strict (▸ Final device round): the notice's "Root Approval Required"
      subtitle, the card's red "Runs as root" line, Approve running `id -u`
      at euid 0 with no prompt, Deny running nothing, Full's confirmation
      and the same command in Full with no card, and Strict asking again.
      Still to run: the same in Relaxed; a real dependency
      (`irisin-cli install --yes <id>`); on an iPhone (Face ID or Touch ID)
      and an iPad with a passcode, Approve and the switch to Full raising
      the owner check, and a cancel or failure leaving it pending with the
      "Not Approved" indicator; an ordinary approval and a session grant
      never running a root command (covered on the Mac by `RootRunChecks`
      in `make harness`).
      Run on 2026-10-30 (build 24, iOS 26.4 iPhone vphone, Relaxed,
      deepseek-v4-pro): asked which packages Irisin could upgrade, the
      agent asked for root itself, the card saying Runs as root for
      `irisin-cli list --upgradable --json`; Approve ran it at euid 0 and
      the reply listed Irisin's three updates, changing nothing. The
      console refuses `approvalMode: full` without the owner check, so Full
      stays by hand.
- [ ] The approval card after the 2026-10-25 polish (build 45's card said
      the root sentence twice, listed `root: true` and showed argv as JSON):
      a root card and an ordinary shell_run card each show the agent's
      reason first, the command as its command line (`id -u`), and a root
      card the red line once with no `root` row; VoiceOver reads title,
      red line, then the text. The text is covered on the Mac by
      `Tests/ChatTranscript`.
- [ ] A rootless bootstrap: install, hello, `i1-smoke`, `t1`, `i3-chain`.
- [ ] Real hardware (not a vphone): the same, plus a real respring and
      confirmLoaded. Toolchain setup and removal, SDK import and builds
      run on an iPhone 15 Pro and an A12Z iPad on 2026-10-21 (▸ Real
      devices below); the project chain did not, as neither has the
      development extensions installed.
- [ ] The iOS 16.0 floor (oldest supported system).
- [ ] On iOS 16, 17 or 18: an agent session starts (`agentList`, then
      `agentOpen`). apelin-agent links `@rpath/libswiftCompatibilitySpan.dylib`.
      The OS has that library only from iOS 26, so on older systems it loads
      the copy the package installs in `usr/libexec/apelin/`, through the
      worker's second rpath, `@executable_path`. Only the iOS 26.4 vphone, where
      the OS copy wins, has run it so far.
- [ ] An iPad: the sidebar split view, which no console run exercises.
- [ ] A Swift binary with a deployment target below 17 on iOS 16
      (no iphoneos compatibility libraries). Swift on both vphones is
      covered by the matrix below.
- [ ] A project packaged and installed with an older toolchain against
      its SDK. Setup through Apelin and Irisin, plus compiler probes, is
      covered on all four hosts by the matrix below.
- [ ] A live agent session with a Copilot credential (the agent loop itself
      ran with DeepSeek on the iOS 26.4 vphone): `agent.json` past
      `agentOpen`, `i4-agent.json`.
- [ ] `t1-toolchain-setup.json` over a slow network (the hour-long path),
      and a cancel during the irisind install.
- [ ] An SDK from an HTTPS archive. Repository-branch imports from the
      enabled default source are covered by the matrix below.
- [ ] `r1-resume-sdk-import.json` on a fresh import (only a re-import of
      a registered SDK has run across a host kill).
- [ ] crashSymbolicate against a real crash of a built tweak.
- [ ] The app, CLI and preference bundle templates built, installed and
      checked for what each does.
- [ ] The idle exit of apelind timed after its last piece of work.
- [ ] Settings ▸ Model Providers: `accounts.json` in its new shape (a
      device code, a loopback, a polled page, two key forms), and a real
      sign-in by hand of each flow — a device code (Copilot, Kimi or Grok),
      a loopback with Safari on the device and with the pasted address
      (Claude, Codex, Devin, OpenRouter), a polled page (Cursor, Qoder,
      WorkBuddy, Z.ai), Kiro's own listener, a key form — each followed by
      an `agentOpen` on that provider. None has run on a device yet.
- [ ] The UI itself: none of the above touched it.
- [ ] The agent's prepared environment: in a project's new chat the first
      message carries `<project-context>` once (its `transcript.json`), the
      model names the installed toolchain and SDK without a tool call,
      shell_run's `sh -c 'command -v clang; echo $SDKROOT
      $IPHONEOS_DEPLOYMENT_TARGET'` answers the prepared ones and
      `clang -arch arm64 hello.c` builds; and the project's terminal, a login
      shell, keeps the toolchain first on `PATH` through
      `etc/profile.d/wiki.qaq.apelin.sh` on roothide and on rootless.
- [ ] Transfer files (`.apetc`, `.apesdk`, `.apeproj`): `transfer` and
      `transfer-project` on both vphones, `transfer-toolchain` by name on a
      roothide one (the export undoes RootHide's runtime brand), then a
      toolchain and an SDK exported on one device and imported on the other
      through AirDrop or Files and Open in Apelin (the toolchain installed
      through Irisin and self-tested there), a roothide export imported on a
      rootless bootstrap, and a project's import followed by a build under
      Confirm, which must ask.
- [ ] The agent's toolchain and SDK tools in a chat (2026-10-22, none has
      run on a device): apelin_toolchain_list and apelin_sdk_list without asking;
      apelin_sdk_import and apelin_toolchain_setup under Strict, each asking with its
      card (release and size, or source and branch) and running once
      approved, the setup installed through Irisin and self-tested;
      apelin_project_set_environment refusing an SDK newer than the toolchain
      reads and switching to one it reads, then a build that does not ask;
      apelin_toolchain_self_test; the agent's git_fetch, which reads its task with
      `environmentAttach`, now allowed for the tasks a session started.
- [ ] Conversations across projects (2026-10-22): General Chat's
      apelin_project_create, then apelin_conversation_create naming the new project under
      Strict (asks, naming the project and the prompt), the child adopted in
      that project without the selection moving, its `apelin://` link
      opening it; apelin_conversation_read of it; a send without approval refused
      by the host.
- [ ] The agent's apelin_notification_send (notify_user until the rename;
      2026-10-24): the banner, its tap, nothing in front and the third
      notice's "0 more" ran as notify_user on build 37, in Relaxed (▸ Turn
      display and notices); under the new name and Strict, the banner with
      no approval card and its tap ran on build 45 (▸ Final device round).
      Still to run: opening the conversation removes its banner; a fourth
      call in one turn refused by the tool and the host; a reopened
      session's replay posts nothing.
- [ ] The renamed tools (2026-10-24): a conversation recorded on build 37,
      before the rename, took a message through an OpenAI-compatible key
      with no provider error, and its old calls keep their titles, on
      build 45 (▸ Final device round). Still to run: the same through GitHub
      Copilot with a Claude model and with a GPT model; the trace's file
      names for its old file calls; a token it saved through
      git_save_credential stays masked in the replay; and a Strict run
      reaches every gated tool under its new name (toolchain setup, SDK
      import, git_push, a git setting, a call into another project, a
      workspace build, package removal), each card and widget step named.
- [ ] The skill tools (2026-10-24): under Strict, apelin_skill_save asking
      with the whole SKILL.md and no "for this session", the skill in
      Settings ▸ Skills, and apelin_skill_remove asking and taking it away
      ran on build 45 (▸ Final device round). Still to run: a built-in's
      name refused before asking, and the saved skill read back from the
      next message's list.
- [ ] Projects from the agent (2026-10-24): apelin_project_list from a
      project's chat, a project's chat creating another without asking and
      answering with its link, and apelin_project_rename renaming its own
      project with no card while the sidebar follows ran on build 45
      (▸ Final device round). Still to run: apelin_project_list in General
      Chat; a rename of another project only after a card that names both
      names; `automatic: true` after the user's own rename changing nothing.
- [ ] The running summary's count and the quiet stand-in (2026-10-24):
      the count, and a stand-in forced by pausing the agent worker, ran on
      build 37 (▸ Turn display and notices), and again with the newest
      call's line under the summary on build 45 (▸ Final device round).
      Still to run: the count as the figure then a plain arrow (`653 ↓`,
      `e07e868`); the count under Reduce Motion; a stand-in after a real
      pause in a provider's stream; two chats streaming at once, with Stop
      and the approval card holding still on every batch.
- [ ] Prompt caching (2026-10-24, AGENTS.md ▸ Prompt caching). DeepSeek
      through an OpenAI-compatible key passed on build 45 (▸ Final device
      round): from the second request on, every request but the expected
      misses read 92–99.6 % of its prompt from the cache; a memory saved in
      another project's chat and an approval answered at once missed
      nothing; a mode switch and a skill saved missed once each. Still to
      run: every other provider below; a memory this project sees saved in
      another chat, which misses once; the first message after midnight; a
      reopened session. The usage of every request is in the session's
      transcript, rewritten when each run ends: `$DATA/sessions/<session
      id>/transcript.json` (the id is `agentList`'s `sessionID`, or the
      newest folder: `Scripts/device.py exec 'ls -t "$DATA/sessions" | head
      -3'`), one assistant message per request, its `usage` {input,
      cacheRead, cacheWrite, output}, `input` the uncached rest, so the
      prompt is input + cacheRead + cacheWrite. Fetch it with
      `Scripts/device.py exec 'cat "$DATA/sessions/<id>/transcript.json"' >
      build/Device/transcript.json` and print one line a request:
      `python3 -I -c 'import json,sys;[print(m["model"],"prompt",u.get("input",0)+u.get("cacheRead",0)+u.get("cacheWrite",0),"read",u.get("cacheRead",0),"write",u.get("cacheWrite",0)) for m in json.load(open(sys.argv[1])) if m["role"]=="assistant" for u in [m["usage"]]]' build/Device/transcript.json`.
      In a project's chat, per provider at hand (Copilot with a Claude and
      with a GPT model, an Anthropic key or Claude Pro/Max, Codex, DeepSeek
      through an OpenAI-compatible key, OpenRouter, Kimi): one message that
      runs three or more tools, a second under five minutes after the first
      run ends. A pass:
      from the run's second request on, cacheRead is most of the prompt
      (at least 80 %; Anthropic over 90 %), and cacheWrite or the uncached
      input is about the newest turn, never the conversation; the second
      message's first request reads the first run's prefix, not only the
      tools. None of these may miss, since the system prompt is the
      session's snapshot and a change is the next message's delta:
      switching Strict to Relaxed, the first message after midnight, a
      memory added in Settings ▸ Memories or by another chat, a skill
      added in Settings ▸ Skills, an edit of the project's AGENTS.md, a
      toolchain set up, an approval answered within five minutes, and a
      reopened session (`Scripts/device.py kill-host`, then a message under
      five minutes after the last request) when nothing the prompt shows
      changed since it opened; one that did changes the reopened prompt,
      which writes the cache once.
      A provider that reports zeros in every field reports no cache at all
      (Copilot may not pass the counts through): note it, not a failure.
      Title completions and compactions are not in the transcript.
- [ ] The system state (2026-10-25, AGENTS.md ▸ the system prompt; none
      has run on a device). With the device in English, ask in Chinese
      ("这个项目是做什么的？"): the reply is Chinese. Ask with only a pasted
      log or one word (`ls`): the reply is English. Switch the device to
      Chinese (Simplified) in Settings ▸ General ▸ Language & Region and
      do the reverse: an English question gets English, a bare log gets
      Chinese. In both, code, paths and commit messages stay as written.
      The block is in the transcript, not on screen: `<system-state>` in
      the user messages of `$DATA/sessions/<id>/transcript.json` (fetched
      as for Prompt caching), naming that language and region, the local
      time and time zone, and the mode; none in the chat's bubbles, the
      title, or an `apelin_conversation_read` of it. Then switch Strict to
      Relaxed between two messages under five minutes apart: the second
      message's block says Relaxed, and its first request's cacheRead
      stays at least 80 % of the prompt (before this, it fell to the tools).
      A message sent with `apelin_conversation_send` carries its own block
      in the receiving conversation. Then, while the conversation is open,
      add a memory in Settings ▸ Memories, a skill in Settings ▸ Skills and
      a line to the project's AGENTS.md: the next message's block lists
      each once under "Changed since you were last told", the one after
      lists none, the agent acts on them, and cacheRead stays at least
      80 %. A memory the agent saves itself is not listed. After Compact…,
      the next request writes the cache once and its block lists nothing.
      DeepSeek counts hits in 64-token blocks and may take a request or two
      to warm.
- [ ] The note that the host restarted, and no jbroot path written down
      (2026-10-29, AGENTS.md ▸ Agent sessions and ▸ the system prompt;
      none has run on a device). On the iOS 26.4 and iOS 27.0.1 iPhone
      vphones (roothide), in a project's chat that has run: kill the
      session host by its `session.pid` (`Scripts/device.py kill-host`),
      then send a message in that chat. The last user message of
      `$DATA/sessions/<id>/transcript.json` (fetched as for Prompt
      caching) has, inside its `<system-state>`, "Apelin's background
      service has restarted since this conversation last ran" with the
      install root now; the bubble, the title and an
      `apelin_conversation_read` of the chat show none of it, and the agent
      neither sets up a toolchain nor imports an SDK again. A second
      message has no note. Kill the host again, Compact… the chat, then
      send: that message has it. A chat started after a kill has none.
      When a reboot and a new jailbreak rename the jbroot, an old chat goes
      on with the new paths without a turn spent finding its toolchain
      gone. A roothide chat's system prompt has the "roothide can rename
      the install root" line and a rootless one's does not; asked to write
      down in AGENTS.md how its project builds, the agent writes no
      `.jbroot-` path (`Scripts/device.py exec 'grep -rl ".jbroot-"
      "$DATA/Projects/<folder>"'` finds nothing).
- [ ] Progress notes in the user's language (2026-10-29, AGENTS.md ▸ the
      system prompt; none has run on a device). The audit of 40 device
      chats found Chinese chats writing "Build passed. Installing." between
      tool calls, after English build and install results. On the iOS 26
      and iOS 27 vphones, in a tweak project's chat, ask in Chinese to
      build, install and confirm it loaded: every line between the tool
      calls, the questions and the reply are Chinese, while code, paths
      and package ids stay as they are. Each user message's
      `<system-state>` in the transcript (fetched as for Prompt caching)
      says "progress notes included".
- [ ] The Compacted row and the native compaction fallback (2026-10-28,
      AGENTS.md ▸ Agent sessions and ▸ the chat's More menu; none has run
      on a device). Compact… on a long chat: once the card closes, a
      "Compacted" line (已压缩) stands after the last reply; a tap, and
      VoiceOver's double-tap on it read as a button, opens Summary with the
      text the next message goes on from, selectable, no markup; the row
      is still there after a relaunch and after a reopen
      (`Scripts/device.py kill-host`, then Compact… again: one more row,
      none repeated). A chat compacted on 0.2.4 shows its row with nothing
      to open. Then, with Claude Pro/Max or an Anthropic key on Claude
      Sonnet 5.5 — the only routes kwwk sends Anthropic's native compaction
      on, so the ones that can answer "context is too large and compaction
      failed: Anthropic compaction returned no summary" —: a chat past 55k
      tokens compacts, from the menu and on its own at 75 % of the window,
      with no such error, kwwk's own summary where Anthropic's came back
      empty.
- [ ] A program the agent builds and runs itself (2026-10-29, AGENTS.md ▸
      the system prompt, `apelin-device-executables`; none has run on a
      device, the skill quotes a field conversation). On the iOS 26.4 and
      iOS 27.0.1 iPhone vphones (roothide) and a rootless device: a C
      program built with shell_run's clang (`clang -arch arm64 probe.c -o
      probe -framework CoreFoundation -framework CoreVideo`) that calls
      `CVPixelBufferCreate` for a 64×64 BGRA buffer with
      `kCVPixelBufferIOSurfacePropertiesKey` an empty dictionary and
      prints the status. Expected: unsigned, exit 137; signed `ldid
      -S<a 0.1.0 cli project's Tool.entitlements>` (its four keys, no GPU
      list), -6662; signed with the skill's `Tool.entitlements`, 0. Then,
      in a Strict chat, ask for an mp4 made into a GIF: the agent reads
      the skill, writes the file into the project, signs before the first
      run (a card for ldid and one for the run) and does not rewrite its
      decoder over -6662.
- [ ] The cli templates' GPU list (2026-10-29, AGENTS.md ▸ Live chat and
      project UI ▸ the templates, `wiki.qaq.apelin.dev.cli` 0.1.1; none
      has run on a device). With the 0.1.1 extension installed, on the
      iOS 26.4 and iOS 27.0.1 iPhone vphones (roothide) and a rootless
      device: a new project from the C template, `CoreFoundation` and
      `CoreVideo` added to its product's `frameworks`, whose `main` calls
      `CVPixelBufferCreate` for a 64×64 BGRA buffer with
      `kCVPixelBufferIOSurfacePropertiesKey` an empty dictionary and
      prints the status; built, installed and run from the terminal, it
      prints 0, and `ldid -e` on the installed tool lists
      `IOSurfaceRootUserClient` under both keys. The same source in a
      project made from 0.1.0, before the upgrade, prints -6662 until both
      lists are copied into its `Packaging/Tool.entitlements`. In a Strict
      chat, another new cli project's first build, its description
      untouched, asks nothing.
- [ ] The templates' package icon (2026-10-29, AGENTS.md ▸ Live chat and
      project UI ▸ the templates; none has run on a device). With
      app and tweak 0.1.1 and cli and preferences 0.1.2 installed, on the
      iOS 26.4 and iOS 27.0.1 iPhone vphones (roothide) and a rootless
      device: a new project of each kind builds and installs, and Irisin's
      installed list shows the kind's icon from Pages beside it. A tweak
      published to the user's package repository shows the same icon in
      the source once Pages has indexed it. With `package.icon` changed to
      another https image, the next install in a Strict chat asks once (a
      packaging change) and the new icon shows; with it removed, the deb
      has no `Icon` and the package manager draws its default.
      Run so far (2026-10-29, build 23, iOS 26.4 iPhone vphone, roothide):
      a tweak project made from tweak 0.1.1 has the tweak icon's URL in
      `package.icon`, and its Debug build's deb names it in `Icon:`; the
      install and Irisin's list are still to run.
- [ ] Restarting an app installed again (2026-10-29, AGENTS.md ▸ Agent
      sessions ▸ apelin_package_install; none has run on a device). In an
      app project's conversation, with the app open from its last install:
      build and install again, and the result's `relaunchHint` names the
      app's bundle id; the agent runs `icli app kill --force <bundle id>`,
      then `icli app launch <bundle id>`, through shell_run as mobile
      (Strict asks for each), and `icli app running` shows a new pid
      running the new build.

## SDK and toolchain matrix (2026-10-19)

Build 27, roothide, using the enabled `owngoal-dev/iOS-SDKs` source. Each
C-family entry compiles, links, generates a matching dSYM, signs and runs C,
C++ (`iostream` and `vector`) and Objective-C (`Foundation`) for arm64 and
arm64e on that device. The deployment target is iOS 16.0. Toolchain entries
install through Apelin and Irisin, then use their selected compatible SDK;
SDK entries import that branch and use one compatible, validated CLT.
Clang modules are off, as required on the A12Z.

Tests run as mobile, one environment task or compiler probe at a time per
device. They include storage checks and stop on a first failure. No tweak
injection, respring, reboot, bootstrap-core change or system-configuration
edit is part of this matrix. Installed environments remain available; the
raw events, probe results and matching Apelin dSYMs are retained locally
under `build/Validation/`. After their first execution, all eleven C-family
products on every device are checked again against their original manifests
and repeat all six cases with the runtime-brand-aware verifier. Only the
RootHide signature metadata described in the retarget research is normalized
in memory; the whole reconstructed file must match its original SHA-256.

| CLT / Apple product | vphone 26.6.2 | vphone 27.0.1 | 15 Pro 17.3.1 | A12Z 26.0.1 |
|---|---|---|---|---|
| 27.0/082-83364 | 6/6 | 6/6 | 6/6 | 6/6 |
| 16.4/082-41241 | 6/6 | 6/6 | 6/6 | 6/6 |
| 16.2/072-44426 | 6/6 | 6/6 | 6/6 | 6/6 |
| 15.3/052-59890 | 6/6 | 6/6 | 6/6 | 6/6 |
| 15.0/042-32697 | 6/6 | 6/6 | 6/6 | 6/6 |
| 14.3/032-84673 | 6/6 | 6/6 | 6/6 | 6/6 |
| 14.2/012-92431 | 6/6 | 6/6 | 6/6 | 6/6 |
| 13.4/002-83793 | 6/6 | 6/6 | 6/6 | 6/6 |
| 13.2/002-41708 | 6/6 | 6/6 | 6/6 | 6/6 |
| 12.5/071-54303 | 6/6 | 6/6 | 6/6 | 6/6 |
| 12.5/071-29699 | 6/6 | 6/6 | 6/6 | 6/6 |
| 12.4/001-89745 | refused | refused | refused | refused |

CLT 12.4 is refused before compiling: its earlier arm64e C++ incompatibility
is a known limitation. The two 12.5 products are tested separately.

| SDK | vphone 26.6.2 | vphone 27.0.1 | 15 Pro 17.3.1 | A12Z 26.0.1 |
|---|---|---|---|---|
| 14.5 | 6/6 | 6/6 | 6/6 | 6/6 |
| 15.2 | 6/6 | 6/6 | 6/6 | 6/6 |
| 15.5 | 6/6 | 6/6 | 6/6 | 6/6 |
| 16.1 | 6/6 | 6/6 | 6/6 | 6/6 |
| 16.2 | 6/6 | 6/6 | 6/6 | 6/6 |
| 16.4 | 6/6 | 6/6 | 6/6 | 6/6 |
| 17.0 | 6/6 | 6/6 | 6/6 | 6/6 |
| 17.2 | 6/6 | 6/6 | 6/6 | 6/6 |
| 17.4 | 6/6 | 6/6 | 6/6 | 6/6 |
| 17.5 | 6/6 | 6/6 | 6/6 | 6/6 |
| 18.0 | 6/6 | 6/6 | 6/6 | 6/6 |
| 18.1 | 6/6 | 6/6 | 6/6 | 6/6 |
| 18.2 | 6/6 | 6/6 | 6/6 | 6/6 |
| 18.4 | 6/6 | 6/6 | 6/6 | 6/6 |
| 18.5 | 6/6 | 6/6 | 6/6 | 6/6 |
| 18.6 | 6/6 | 6/6 | 6/6 | 6/6 |
| 26.0 | 6/6 | 6/6 | 6/6 | 6/6 |
| 26.1 | 6/6 | 6/6 | 6/6 | 6/6 |
| 26.2 | 6/6 | 6/6 | 6/6 | 6/6 |
| 26.4 | 6/6 | 6/6 | 6/6 | 6/6 |
| 26.5 | 6/6 | 6/6 | 6/6 | 6/6 |
| 27.0 | 6/6 | 6/6 | 6/6 | 6/6 |
| 27.1 | 6/6 | 6/6 | 6/6 | 6/6 |

The 13.0–14.4 trees lack `usr/include/c++/v1/iostream` and were removed
from the default source by the owner’s choice. A 13.0 trial on both vphones
passed C and stopped at the missing C++ header, without a compiler crash;
its imported copies were removed. SDK contents in the published branches
are unchanged.

| CLT 27.0 with Swift | vphone 26.6.2 | vphone 27.0.1 | 15 Pro 17.3.1 | A12Z 26.0.1 |
|---|---|---|---|---|
| Installation / self-test | 10/10 | 10/10 | refused | refused |
| SDK 27.0 | 10/10 | 10/10 | unavailable | unavailable |
| SDK 27.1 | 10/10 | 10/10 | unavailable | unavailable |

The ten Swift-toolchain cases are the six C-family cases plus Swift, a
Swift dylib and client, structured concurrency, and an Observation macro
on arm64e. Both 27.0 and 27.1 SDKs are exercised independently on each
vphone. The current Swift component requires iOS 26+ and SHA3/DotProd:
the 17.3.1 host and A12Z therefore verify a refusal, without launching the
unsupported compiler.

Final app checks cover the 23 registered SDKs, 23 published source branches,
and refusal of unavailable Swift before SDK resolution. SDK auto-resolution
also has host tests for newest-compatible selection, same-major Swift
selection, metadata revalidation, cancellation, source failures and reuse
after a later toolchain failure.

## Initial legacy Swift investigation (2026-10-19; completed below)

The iOS 26 floor above describes the current CLT 27.0 port, not every
Swift compiler. Two unregistered research trees were prepared from verified
Apple packages, with unchanged machine instructions and Swift imports:
CLT 14.2 / Swift 5.7.2 and CLT 15.0 / Swift 5.9. At this initial stage, production release,
host-version and CPU gates remained unchanged. The subsequent completion
below records the signer fix and promotion into ordinary setup.

| Research tree / SDK | vphone 26.6.2 | vphone 27.0.1 | 15 Pro 17.3.1 | A12Z 26.0.1 |
|---|---|---|---|---|
| 14.2 / 16.2, version command | pass | pass | pass | pass |
| 14.2 / 16.2, full probe | 12/12 | 12/12 | partial; dylib launch denied | partial; dylib launch denied |
| 15.0 / 17.0, version command | pass | pass | pass | not run: SHA3 instructions present |
| 15.0 / 17.0, full probe | 14/14 | 14/14 | not run after first 14.2 failure | not run |

The 14.2 probe is six C-family cases plus ordinary Swift, a dylib/client and
async on both arm64 and arm64e. Macros are excluded because Swift 5.7 does
not support them. The 15.0 probe adds an Observation macro on each
architecture. On both physical devices, the six C-family cases and ordinary
Swift arm64 passed. The next case compiled, linked and signed its dylib and
client, then the client was terminated at launch by dyld: `file system
sandbox blocked mmap()`. Its launch report names the private test dylib as
the missing library (DYLD / Library missing, with an instruction to ignore
the backtrace). No compiler SIGILL occurred in these legacy probes. Each
physical sequence stopped there: Swift async and arm64e were not tested,
and the 15 Pro did not proceed to the 15.0 full probe. These are partial
results, not full legacy Swift support.

Before execution, the selected-feature instruction scan found only LRCPC
among the selected features in 14.2's 14 host images; 15.0's 29 images
contain 112 `eor3` instructions (55 clang, 55 libLTO, two swift-frontend),
so 15.0 was not tried on A12Z. This scan is not a reachability proof.
The native symbol probe found all 949 ordinary strong system imports of
14.2 on A12Z and all 1,682 of 15.0 on the 17.3.1 host; dyld's
`dyld_stub_binder` is classified separately from `dlsym`-resolvable exports.

All four temporary research packages and their owned work folders were
removed after testing. Registered SDKs, official toolchains, project
bindings and defaults were preserved. No respring, reboot, tweak injection
or security-policy change was used to work around the dylib refusal.
Raw research evidence and matching probe dSYMs remain local under
`build/LegacySwift/` and `build/Validation/dSYMs/`.

### Legacy Swift completed through debug-signed self-tests

The earlier dylib denial was a self-test signing defect. A bounded native
`dlopen` probe reproduced it without crashing: storage and library-validation
entitlements did not help, but the ordinary `get-task-allow` debug signature
allowed the same private library to load. Temporary Swift test executables
now carry that entitlement. Compiler binaries and dylibs retain their
normal signatures; system security settings are unchanged.

With that fix, CLT 14.2 + SDK 16.2 passed 12/12 on all four devices, including
ordinary Swift, dylib/client and async for arm64 and arm64e. CLT 15.0 + SDK
17.0 passed 14/14 on both vphones and the iOS 17.3.1 15 Pro, including
Observation macros on both architectures. A12Z did not execute CLT 15.0,
whose SHA3 instructions remain incompatible. No new compiler crash occurred.

Production setup now reviews Swift for 14.2 and 15.0 as well as 27.0, with
per-release host and CPU requirements. The legacy floor offered is iOS
17.3.1, the oldest actual host tested; iOS 16 remains unverified for Swift.
The public download reference is [Compatibility](../Compatibility.md).


## Static installation compatibility audit (2026-10-19)

All 11 offered Apple CLT packages now have source SHA-256 pins and static
host-image inventories, including CPU decoder comparisons. No compiler
was run on a device for this audit. The results, its unclassified-data
limitations and the iOS 16.1 SDK export check are in
[Toolchain-Retarget](2026-10-17-Toolchain-Retarget.md#installation-compatibility-catalog-2026-10-19).
The installation catalog exposes the same reviewed data through its
`compatibility` field; [Compatibility](../Compatibility.md) lists the
CPU groups and recommended SDK pairings. None of these static results
marks an unrun device checklist item as passed.

## Real devices: every release and SDK (2026-10-21)

Two of the owner's devices, both roothide, both with Apelin build 29,
Irisin 4.7.2 and icli 0.9.2, neither with the development extensions:

| Device | System | CPU features (`hw.optional.arm`) | `__libcpp_verbose_abort` | Injection |
|---|---|---|---|---|
| iPhone 15 Pro (A17 Pro) | iOS 17.3.1 | LRCPC, LRCPC2, SHA3, DotProd, BF16, I8MM | present | ElleKit 1.2-1 |
| iPad Pro (A12Z) | iPadOS 26.0.1 | LRCPC only | present | none (ElleKit removed) |

Each release was set up through the console (`toolchainSetup`, Apple's
package, retarget, the bridge, the self-test as mobile), then built more
than the self-test with its own tools from a shell as mobile, then
removed with `toolchainRemove`; both devices end with no toolchain
package and an empty registry. The extra cases: the CLI template's
`main.m` (`cli-objc`, arm64 and arm64e, run), a C++ program with
`<map>`/`<string>` (arm64, arm64e), `@import Foundation` with
`-fmodules` (clang modules, which Apelin's builds do not use), and the
tweak template's `Tweak.m`, unchanged, built into an arm64e dylib against
the roothide substrate stub with the template's flags and `dlopen`ed by a
loader (the `@loader_path/.jbroot` link emulated beside it), which must
bind `MSHookMessageEx` to ElleKit and run its constructors. With Swift,
also a Swift command-line program for both architectures.

### Catalog

| CLT | iPhone 15 Pro, C family | iPhone 15 Pro, Swift | A12Z, C family | A12Z, Swift |
|---|---|---|---|---|
| 27.0 | offered | refused: "Swift 6.4 requires iOS 26.0 or later on this device." | offered | refused: "requires CPU features this device lacks: FEAT_SHA3, FEAT_DotProd." |
| 16.4, 16.2, 15.3 | offered | none reviewed | offered | none reviewed |
| 15.0 | offered | offered | offered | refused: "Swift 5.9 requires CPU features this device lacks: FEAT_SHA3." |
| 14.3 | offered | none reviewed | offered | none reviewed |
| 14.2 | offered | offered | offered | offered |
| 13.4, 13.2, 12.5 (both products) | offered | none reviewed | offered | none reviewed |
| 12.4 | refused, its arm64e C++ reason | — | refused, same | — |

Every refusal came before any download (1–6 s) and its reason is right.
Build 32's catalog, which adds the C++ runtime symbol check for 16.4 and
27.0, decides the same on both: each has the symbol.

### Setup, by stage (seconds, from the task's `stage` events)

Download / extract / adapt / package / install through the bridge /
self-test; total. Every self-test case passed: 6 C-family cases per
release, plus the Swift cases.

| CLT | iPhone 15 Pro | A12Z |
|---|---|---|
| 27.0 | 51 / 36 / 2 / 2 / 13 / 7; 111 | 53 / 59 / 3 / 7 / 24 / 17; 164 |
| 16.4 | 117 / 53 / 2 / 3 / 14 / 6; 195 | 105 / 99 / 3 / 7 / 20 / 17; 252 |
| 16.2 | 57 / 44 / 2 / 2 / 15 / 6; 126 | 93 / 83 / 3 / 6 / 19 / 18; 222 |
| 15.3 | 54 / 42 / 1 / 3 / 14 / 6; 120 | 86 / 78 / 2 / 7 / 16 / 17; 207 |
| 15.0 | 57 / 41 / 2 / 3 / 13 / 6; 123 | 92 / 78 / 3 / 6 / 19 / 18; 217 |
| 14.3 | 51 / 39 / 1 / 2 / 11 / 6; 110 | 80 / 73 / 2 / 6 / 17 / 17; 194 |
| 14.2 | 146 / 38 / 1 / 2 / 10 / 5; 202 | 80 / 72 / 2 / 5 / 15 / 16; 190 |
| 13.4 | 52 / 38 / 1 / 2 / 9 / 6; 107 | 79 / 71 / 1 / 5 / 15 / 16; 187 |
| 13.2 | 47 / 36 / 1 / 2 / 9 / 5; 100 | 75 / 68 / 1 / 5 / 13 / 15; 177 |
| 12.5 (071-54303) | 39 / 29 / 1 / 2 / 8 / 5; 84 | 64 / 55 / 1 / 4 / 12 / 16; 152 |
| 12.5 (071-29699) | 43 / 29 / 1 / 1 / 6 / 5; 85 | 61 / 54 / 1 / 5 / 13 / 15; 149 |
| 15.0 with Swift | 54 / 42 / 3 / 4 / 12 / 99; 214 | refused |
| 14.2 with Swift | 68 / 38 / 1 / 3 / 16 / 64; 190 | 78 / 71 / 3 / 8 / 20 / 160; 340 |

The self-test cases, mean seconds: C 0.6, C++ 1.2–1.4, ObjC 0.9–1.0 on
the iPhone; C 1.8–1.9, C++ 3.5–4.0, ObjC 2.5–2.8 on the A12Z. Swift, per
architecture (arm64, then arm64e): 15.0 on the iPhone, Swift 38.9 and
40.8, dylib 3.7 and 2.6, async 1.2 and 1.2, macro 2.4 and 1.3; 14.2 on
the iPhone, Swift 26.2 and 26.8, dylib 1.9, async 0.9; 14.2 on the A12Z,
Swift 64.8 and 64.3, dylib 5.1 and 5.2, async 2.4 and 2.6. The first
Swift case of each architecture builds the SDK's modules cold, which is
all of the Swift time. Inside "install" (27.0 on the iPhone, 13 s): the
deb is handed over in 1 s, irisind takes 4 s before its install root,
3 s to verify the 345 entries and 3 s to unpack; removal takes 1.7–2.9 s
on the iPhone and 2.3–4.1 s on the A12Z.

### Beyond the self-test

| Case | iPhone 15 Pro, every release | A12Z, every release |
|---|---|---|
| `cli-objc` arm64, arm64e | pass (0.9–2.2 s) | pass (2.8–4.0 s) |
| C++ arm64, arm64e | pass | pass |
| `@import Foundation` (`-fmodules`) | pass | pass for 16.2 and older; 27.0 and 16.4 die of SIGILL (`Illegal instruction: 4`) |
| tweak dylib loaded | pass | builds; no load (no injection framework) |
| Swift CLI arm64, arm64e | pass with 15.0 (57–59 s) and 14.2 (42–45 s) | pass with 14.2 (89–91 s) |

The A12Z module result is narrower than the catalog: `clangModuleCPUFeatures`
asks SHA3 of 14.3 to 16.4 because their images carry `eor3`, and this case
reached it only in 16.4 and 27.0. One `@import` does not show the
instruction unreachable elsewhere, so the table is unchanged.

**A12 after a drop of every release older than 15.0.** It keeps a
toolchain: 15.0, 15.3, 16.2, 16.4 and 27.0 all set up, pass the six
C-family cases and build and run the CLI template, C++ and the tweak dylib
on the A12Z. By the catalog of that day it would lose Swift: 14.2 (Swift
5.7.2) was the only Swift offered there, 15.0's being gated on SHA3. Run
since (▸ Kept releases and their Swift, below), 15.0's and 15.3's Swift
pass every case on the A12Z, so that gate is gone.

### SDKs on the iPhone 15 Pro

All 23 branches of the default source (14.5 … 27.1) were removed and
imported again from their branches (`sdkImport` repository), then built
against with CLT 27.0 (the newest release, which reads every one): the
six kit cases above, arm64 and arm64e, the tweak loaded. Every one
passed, so no SDK is unusable there. Swift on 17.3.1 is CLT 15.0's (reads
up to 17.0) and 14.2's; the Swift CLI built and ran against 14.5, 15.2,
15.5, 16.1, 16.2, 16.4 and 17.0 with 15.0, both architectures. The SDKs
from 17.2 up have no Swift on 17.3.1: CLT 27.0's Swift needs iOS 26.

Import, by stage (fetch / inspect; total, seconds): 14.5 21 / 4; 25 —
15.x 18 / 4–5; 23 — 16.x 19–24 / 5–6; 24–29 — 17.x 22–28 / 4–5; 27–33 —
18.x 22–26 / 5–7; 28–31 — 26.x 23–31 / 6–21; 29–51 — 27.0 28 / 7; 36 —
27.1 21 / 4; 26. The A12Z: 14.5 38 / 11; 49 — 18.0 54 / 15; 69 — 27.1
43 / 12; 55. Of an 18.0 fetch on the iPhone (26 s, a 38 MB pack), 6 s
pass before the first byte, 6 s are the transfer and 14 s are libgit2
resolving deltas and checking out about 10,000 files.

### Where the time went, and what changed

Measured on the devices with the probe (`apelin-toolchain-probe setup`,
download to packaging, as mobile) built from this tree before and after,
CLT 15.0, the same manifest digest out of both:

| Step | iPhone 15 Pro before | after | A12Z before | after |
|---|---|---|---|---|
| download (527 MB) | 49–84 s | 22–48 s (one run 154 s) | 91–92 s | 32–50 s |
| extract | 42–52 s | 17–28 s | 77–78 s | 35–36 s |
| adapt + package | 2–3 s | 2–3 s | 4 s | 4 s |
| whole pipeline | 92–136 s | 41–67 s (one run 186 s) | 173–174 s | 72–89 s |

- **Download.** One HTTPS connection to Apple's CDN gave 15.6 MB/s on the
  iPhone, four 33 MB/s; the loop also read every byte through
  `AsyncBytes`. Four 8 MB ranges are now in flight at once and each body
  arrives in the chunks the session delivers. Every range keeps its
  checks (206, the exact `Content-Range`, the exact size, a body longer
  than asked refused as it arrives, If-Range with the first validator, a
  changed validator or a 200 restarting the download), the prefix is
  still hashed and checkpointed in order after every range, and the whole
  package is still checked against its pinned SHA-256 before extraction.
- **Extract.** The Payload is pbzx: independent XZ chunks decoded one at
  a time. Up to four are now decoded at once and handed out in order; the
  payload checksum hashes only the algorithm the xar table names.
- **Package and install check.** Each file's digest, at packaging and in
  the installed-tree check, on up to four cores.
- **SDK inspection.** Every file's Mach-O check and digest on up to four
  cores; the digest and the first refusal are the walk-order ones. The
  same work, measured alone on an 18.0 tree (10,227 files): 4.2 s → 1.1 s
  on the iPhone, 10.5 s → 2.9 s on the A12Z. It ships in apelin-environment,
  which could not be installed on these devices (no root), so the import
  itself was not timed after.
- **The catalog** fetched each product's distribution one after another
  (6.6 s); they are now fetched together.

Not changed: the SDK fetch (already a shallow single-branch clone; the
time is the server's pack and libgit2's delta resolution and checkout,
which only a different source format would avoid), the local toolchain
deb's zstd level 3 (1–2 s to write on the iPhone, about 5 on the A12Z;
level 1 or none would trade it for a larger copy through the bridge and
irisind's two reads), the self-test (C cases could run two at a time, and
the arm64 and arm64e Swift cases, each a cold build of the SDK's modules,
side by side; both are left for a measurement of memory first), and the
retarget itself (1–3 s).

## Kept releases and their Swift (2026-10-21)

The owner kept 27.0, 16.4, 15.3, 15.0 and 14.2 and dropped 16.2, 14.3,
13.4, 13.2 and 12.5 (all of which had passed above); 14.2 stays so an A12
keeps Swift. A dropped or unreviewed product is left out of
`toolchainCatalog` and refused by `toolchainSetup` with its reason before
anything downloads; a kept release a device cannot run is still listed,
with why.

Which Swift each kept package ships, read from Apple's own payload
(`swiftc --version`, packages checked against their pinned SHA-256):

| CLT | Swift | swift-frontend built for | Imports macOS's zippered `_stdlib_isOSVersionAtLeastOrVariantVersion` | SHA3 / DotProd in swift-frontend |
|---|---|---|---|---|
| 27.0 | 6.4 (swiftlang-6.4.0.34.1) | macOS 14.0, SDK 16.0 | swift-driver, two SwiftSyntax libraries | yes / yes |
| 16.4 | 6.1.2 (swiftlang-6.1.2.1.2) | macOS 14.0, SDK 15.4 | swift-driver, two SwiftSyntax libraries | 5 eor3 (4 in XXH3, 1 symbol graph) / 3,754 udot |
| 15.3 | 5.10 (swiftlang-5.10.0.13) | macOS 13.0, SDK 14.4 | none | 2 eor3 (BLAKE3 hash_many, symbol graph) / none |
| 15.0 | 5.9 (swiftlang-5.9.0.128.106) | macOS 13.0, SDK 14.0 | none | the same 2 eor3 / none |
| 14.2 | 5.7.2 (swiftlang-5.7.2.135.5) | macOS 10.14.6, SDK 13.0 | none | none / none |

Each Swift tree was then made on the device by the probe (Swift
component), packed as a local deb and installed through Apelin's bridge
(a tree in the data folder cannot map its own dylibs), self-tested in
place as mobile, and removed through the bridge. The A12Z ran a research
build with the Swift CPU gate lowered to LRCPC, to see what the CPU does.

| CLT, SDK | iPhone 15 Pro, iOS 17.3.1 | A12Z, iPadOS 26.0.1 |
|---|---|---|
| 16.4 + Swift, 18.5 | C family 6/6; swiftc stopped by dyld: `_stdlib_isOSVersionAtLeastOrVariantVersion` not found | the same |
| 15.3 + Swift, 17.4 | 14/14 (Swift 41.7 / 47.3 s, dylib 2.5 / 4.9 s, async 2.1 / 3.8 s, macro 1.2 / 1.2 s, arm64 / arm64e) | 14/14 (Swift 101.9 / 102.0 s, dylib 6.9 / 6.7 s, async 3.0 / 3.1 s, macro 3.3 / 3.3 s) |
| 15.0 + Swift, 17.0 | 14/14 (the console setup above) | 14/14 (Swift 89.6 / 91.2 s, dylib 6.7 / 6.7 s, async 3.0 / 3.0 s, macro 3.3 / 3.2 s) |

So 15.3 offers Swift 5.10, and 15.0's and 15.3's Swift no longer require
SHA3: their two SHA3 sites are BLAKE3's hash_many (compile caching, which
Apelin does not enable) and the symbol-graph edge set
(`-emit-symbol-graph`), and the A12Z built the SDK's modules and every
case without reaching either. 16.4's Swift is not offered and the catalog
says why: no iOS runtime exports the zippered check, the rename 27.0 uses
answers correctly only from iOS 26, and its swift-frontend needs DotProd
and SHA3 (XXH3 module hashing, the code that stopped 27.0's Swift on the
A12Z), so it could serve only A13 or later on iOS 26, where 27.0's Swift
6.4 already runs; no such device was available to verify it.

| Release | Swift | A12 (LRCPC) | A13 and later |
|---|---|---|---|
| 27.0 | 6.4 | no (SHA3, DotProd) | iOS 26 and later |
| 16.4 | 6.1.2 | not offered | not offered |
| 15.3 | 5.10 | iOS 17.3.1 and later | iOS 17.3.1 and later |
| 15.0 | 5.9 | iOS 17.3.1 and later | iOS 17.3.1 and later |
| 14.2 | 5.7.2 | iOS 17.3.1 and later | iOS 17.3.1 and later |

The 17.3.1 floor of 14.2, 15.0 and 15.3 is the oldest host verified, not a
measured limit; iOS 16 remains unverified for Swift.


## Chat and provider UI installation (2026-10-21, build 50)

Commit `35d67e0` was packaged as the roothide build 50 and installed over
the existing app on the running iOS 27.0.1 and iOS 26.6.2 vphones. Both
installers completed successfully; `apps.info` reported build 50 and
`apps.foreground` independently verified Apelin in the foreground on each.
The iOS 27.0.1 guest printed the known uicache registration warning; its
registered build and verified foreground app confirmed the installation.

This validates installation and launch only. The API-key form, provider
verification request and model activation flow have not been exercised
on these devices: the owner will enter the credential. No key was read,
submitted or changed during this installation. The local test suite and
HTTP verification fixture results belong to the implementation checks,
not to live-provider validation.


## FlowDown composer and model settings (2026-10-21, build 57)

Build 57 was built for iPhoneOS Release, packaged for roothide and installed
on both existing vphones (iOS 27.0.1 and iOS 26.6.2). Both report build 57
and independently verify Apelin in the foreground. Installation preserved
the configured accounts. The iOS 27.0.1 guest still prints the known uicache
registration warning; its registered build and foreground app are verified.
The final package SHA-256 is
`1a84f11e6de43cfdb304d4032a8d6e2eaeafdd5e62da51dd297a603b7417b536`.
Seven dSYMs are retained under `build/dSYMs/0.1.0-57/`; Apelin's arm64 UUID
is `BB62FA66-4AA2-321C-93D1-033DA05D5163`. All nine packaged Mach-O files
passed the absolute-path and secret-pattern audit. The generated licenses
include ScrubberKit, SwiftSoup and Turndown.

`make check` and the complete `make harness` passed, including 565/565
session-host checks, the system-only dependency checks and 112 agent tests.
The live Copilot test remains skipped. Two pre-existing session-host checks
looked for old English words after UI copy changed; they now check the
interrupted state and a nonempty explanation instead of a wording fragment.

Device UI checks on the iOS 26.6.2 guest confirmed:

- The editor uses FlowDown's original camera/microphone/plus/close/send SVGs;
  all six editor/model SVGs were compared byte-for-byte with the reference.
  The small model and effort blocks are 33 pt high, with the reference's
  14 pt semibold text, 16 pt icon and 8 pt insets.
- The inline four-button panel opens and closes without its own clipping.
  Photo and Files open their system pickers; Web opens the address input.
  Importing private photo/file content was not part of this check.
- Model selection is a deferred context menu with the saved DeepSeek IDs,
  not a form sheet. Selecting DeepSeek defaults effort to High. The effort
  menu exposes Low, High and Maximum, with no Off entry.
- The API model page fetches the DeepSeek list and supports custom IDs.
  A temporary, unsaved custom ID was added, swiped left, and deleted; the
  row disappeared. The page was closed without saving, preserving the
  user's enabled list and leaving no saved test model.
- Settings initially shows Permission Mode: Relaxed. Changing to Strict
  is immediate; Strict to Relaxed presents the confirmation. Cancelling
  retains Strict, and confirming restores Relaxed.

These checks do not establish a working chat-to-agent bridge. Chat messages
and attachments remain local in-memory previews; MarkdownView and real
streaming are not connected. The red Stop control requires a live output
cancellation callback and stays hidden without one. The global permission
preference and the selected effort must be passed when that bridge opens a
session. No OAuth login or live Copilot policy activation was exercised.

## Transcript presentation and composer preferences (2026-10-21, build 61)

The app from `b4ce333` was built for iPhoneOS Release, packaged for roothide,
and updated on the existing iOS 26.6.2 iPhone and iOS 27.0.1 iPad vphones.
Both report app build 61 and independently verify Apelin in the foreground.
The app-only update used the guest file API after SSH/PAM authentication
refused the normal installer: the signed package's app was staged, made
root-owned and swapped with a rollback copy. App data and provider credentials
were preserved; daemon and worker installations were not changed by that swap.
The package SHA-256 is
`95b6628dd7b994aa7076295f6ad350922a822a35bc5c8449953539d6501f748d`.
The app dSYM is retained in `build/dSYMs/0.1.0-61/`; its arm64 UUID is
`98989341-42FF-3326-8573-3DEB9605339F`. The package's nine Mach-O files passed
the path, dependency and secret-pattern checks.

`make check` and the complete host harness passed, including 565 session-host
checks. The new image-layout harness covers empty albums, single images,
2–20 images, portrait-leading groups, invalid ratios and narrow widths.
Both devices passed all seven smoke scripts.

UI checks confirmed:

- The selected model survives a cold launch on both devices. On the iPhone,
  reasoning effort also survived switching to a new chat and a cold launch;
  it was restored to High after testing Low.
- User bubbles, Markdown headings, lists, quotes, code and tables render in
  the transcript. Thinking summaries and tool events are separate rows.
  Inter-block spacing is shared by Markdown and activity rows.
- The top scroll-edge treatment covers content behind the navigation title,
  including an image album passing underneath it.
- The local preview's Allow Once action resolves its request and removes its
  controls without pulling the reader to the bottom. Stop removes the local
  thinking example and its button. These callbacks do not call the backend.
- Mixed image proportions form an album, and tapping a tile opens that image
  in Quick Look. Album paging was implemented but not verified in this run.

The conversation is explicitly sample content. The model/session transport,
live approval relay and streamed provider reasoning are not connected to this
UI yet. The separate transcript entry types and `updateMessages` are its UI
surface; this run does not establish a live chat-to-agent round trip.

## Approval section and soft scroll edge (2026-10-21, build 64)

The follow-up UI build uses one shared horizontal divider above the pending
approval section. The content sits on the left and Approve / Deny on the
right, vertically stacked on narrow screens. Resolved requests show only
an operation title and a green checkmark or red xmark; the decision remains
in the label's accessibility value. Stop has a red border as well as red
text and icon. The top scroll edge now uses the requested soft treatment.

Build 64 passed `make check`, the iPhoneOS Release build and the package
checks. Both devices passed all seven smoke scripts again on build 64. Its
nine shipped Mach-O files and the payload paths passed the private-content
scan. The package SHA-256 is
`2a2cb7b44560dbe43d736cac256f173d971054aa05d8d75b43c948aa2b0bc142`.
Its retained app dSYM is `build/dSYMs/0.1.0-64/Apelin.app.dSYM`, arm64 UUID
`D8BF31B9-0404-3F67-B9CF-C05212A3BD0E`.

Both existing vphones were updated with the signed app-only payload and
reported build 64 in the foreground. The pending section was checked on
both screen sizes. On build 63, before removing the duplicate divider,
the iPhone's Approve and iPad's Deny each collapsed the section, preserved
the reading position and inserted the appropriate result in history.
The result title has no visible status prefix; the accessibility tree still
reports the outcome. The red Stop outline and soft top edge were inspected
on the same build. Build 64 changes only the redundant divider.

The earlier complete regression attempts on both devices stopped at
`i5-log-continuity` after six passing scripts. Their event logs show
`run.interrupted` during the wait step (179 and 187 respectively); no cause
was established. These runs are not counted as a passing full regression.
The app's approval actions remain local preview callbacks, not a live agent
approval relay.

## Approval replaces the editor (2026-10-21, build 70)

The pending approval now occupies the editor's rounded background. The text
field, attachment strip and import controls are hidden while it is shown;
the model and Stop row remains available. Resolving the request restores the
editor. Both actions have tinted fills. Only Approve has a border and uses
semibold text; its natural width includes the title and button padding so it
stays on one line. Deny is first and Approve is last in both layouts.

The combined natural button widths and their gap decide the layout: at most
30% of the section width keeps them beside the content, aligned at the
bottom. Otherwise they move below the content and divide the available row
width equally. The phone's equal widths and the tablet's inline alignment
were checked from the accessibility frames and screenshots. Pending approval
hides the editor from accessibility and keeps Stop reachable. A completed
approval restores the field. Captured intermediate frames show both opening
and closing transitions, including the departing text fading with the panel.

The Release build and `make check` passed. Both vphones received the signed
app-only payload and verified build 70 in the foreground. Both devices
passed all seven smoke scripts on this build. The package and its
nine Mach-O files passed the private-content and dependency scans. SHA-256:
`9887d571aec4c9487209e7f8effb1d9d70d0ee59bc0f1716cf6746fedf6e2f55`.
The retained app dSYM is `build/dSYMs/0.1.0-70/Apelin.app.dSYM`, arm64 UUID
`8A044FFF-96BE-3B81-97CA-E894C0045F68`.

An intermediate build 66 regression attempt used a 90-second runner override
and timed out in `i5-log-continuity` on both devices. The final rerun uses the
repository's per-script deadlines (300 seconds for that script).

On the final build, both regression runs passed 11 scripts, including
`i5-log-continuity`, `tool-host`, `i6-tool-attachments`, `i2-git` and
`i2-git-commit`. Both stopped at `i2-sdk-import`, step 6: the assertion expected
`response.sources` to be empty, but the response contained the enabled
default OwnGoal iOS SDKs source. The remaining regression scripts did not
run. This UI change does not alter SDK source behavior, and the full suite
is not recorded as passing.


## Approval covers all composer controls (2026-10-21, build 71)

Pending approval now also hides the model, reasoning-effort and Stop row.
Both screen sizes always stack the content above equally wide Deny and
Approve actions. Resolving the request restores the editor and model row
with their existing spring and opacity animation. The model row's visibility
is derived from the pending approval and import-panel state in one place.

The iOS Release build and `make check` passed. Both existing vphones were
updated with the signed app-only payload, reported build 71 and verified
Apelin in the foreground. The package and its nine Mach-O files passed the
private-content and dependency checks. SHA-256:
`6dd2cd9215f0f06f7765b62203b7257fe3ea3038cf1b9fc331c8bc31175860ca`.
The retained app dSYM is `build/dSYMs/0.1.0-71/Apelin.app.dSYM`, arm64 UUID
`B387FA3B-0A6D-36BE-BBCC-C46A3ABE1713`.

Screenshots and accessibility frames confirmed equal action widths and
stacked content on the phone and tablet. Neither the editor nor the model,
effort or Stop controls appears in the pending view's accessibility tree.
Approving on the phone and denying on the tablet restored the field and
model/Stop controls. An intermediate phone frame confirmed the simultaneous
fade and resize. The phone's import panel still hides the model row and
restores it when closed after the approval is resolved.

## Live chat, templates and trace (2026-10-21)

The chat UI now uses persisted agent sessions and ordered host events. On the
phone, a projectless conversation created its own temporary workspace and
received a real provider reply. Sending a text attachment saved it under that
workspace, and the agent read it and returned the expected marker. Reopening
the app restored the history and attachment. On the tablet, the UI created
both an Empty workspace and a project copied from the C command-line template;
the project picker and sidebar switched between them and retained their chats.

A Strict-mode chat requested screen capture. Approve reached the backend and
returned an image; a second request was denied and the decision returned to the
UI. Stop terminated a subsequent generation and removed the working indicator.
The image preview now derives a filename extension from the image data when a
tool supplies a name without one, so Quick Look can identify its format.

Two issues discovered during live testing were fixed after matching the build
74 dSYM and symbolicating the crash reports: duplicate project identifiers when
creation and refresh arrived together, and a Swift exclusive-access violation
when the reader derived working state while mutating the record dictionary.

The final presentation groups consecutive thinking steps into one summary,
followed by response content. Tool calls and completed approvals appear only
in the summary's Trace form sheet, in their original order. The pending
approval still replaces the entire composer. Trace tests check stable identities,
stream/final replacement, hidden tool rows, merged summaries and approval replay.
The complete backend harness passed, including 53 agent tests and all 565
session-host checks. The template archive round-tripped and repeated builds
produced identical bytes. No release was published during this validation.

The final attachment layout follows FlowDown’s UserAttachmentView and attachment
cell geometry: it precedes the user bubble and aligns to the trailing edge;
images are 80 pt square and text previews are 240 by 80 pt. Restored text
attachments show the first 500 characters instead of falling back to byte
counts. Content blocks have one 16 pt gap, including image-only responses.

Conversation switches remove the old ListViewKit list and create a fresh one,
with the current viewport and composer insets. The initial snapshot and scroll
position are applied without animation. Template catalog rows now contain
only single-line names under the existing group headings.

The final UI revision uses 8 pt for both paragraph breaks and cell spacing.
Summary headers have no icons in the conversation or Trace sheet. Template
rows show only the name and the total source-file size; the build worker
reports that optional byte count, and its size tests passed without an SDK.

Build 88 passed the iOS Release build, repository checks and transcript replay
checks, and both vphones reported that build in the foreground. The build worker
was updated separately so template sizes came from the same implementation.
Six switches between a short reply, an approval history and an image reply on
the tablet showed only the selected chat's rows. The phone restored its file
preview above the user bubble, with the real text content, one summary and the
expected reply. The image returned by the tool opened as an image in Quick Look.
The app dSYM is retained under `build/dSYMs/0.1.0-88/`, arm64 UUID
`D3F5B16A-268F-3B61-AAF3-EBA5DF95C3F8`; the build worker's UUID is
`1F9873ED-1588-3A16-89AF-5221EF768896`. Package SHA-256:
`5e9c10877ac46a6ada2d2a5cba056baac4db8d99c432b4b110dfb19d735ed30b`.

## Template group footers and spacing (2026-10-21, build 90)

Each template group now has a brief localized explanation below its rows.
Names and file sizes stay on one line. The owner doubled the shared paragraph
and cell spacing from 8 pt to 16 pt; the empty-body spacing fix remains in place.
The Release build and repository checks passed. Date reported build 90, and
its UI showed the workspace, app, command-line and tweak descriptions without
changing the row layout. Its attachment, bubble and summary spacing also
reflected the new shared value. Banana stayed on build 88: its SSH endpoint
refused the existing credentials, so this run did not update that device.
The app dSYM is retained at `build/dSYMs/0.1.0-90/Apelin.app.dSYM`, UUID
`F719A6A3-428E-3EEF-9D12-4FBB9829EDBC`. Package SHA-256:
`8712ef7cb6643549804cffbaaf78a4eede16d66ae7c57afe936e369ef1c7a706`.

## Attachment previews and header blur (2026-10-21, build 97)

Sent and received image previews, PDF first pages and supported Quick Look
thumbnails now share the same album renderer. Text files use a compact card
with a filename and up to three preview lines, preserving pasted line breaks.
Cards omit byte counts, use the user-bubble tint for their border, and align to
the user's trailing edge. Their width is the smallest of natural content width,
the actual user-bubble width and 350 pt. User image albums cannot exceed the
maximum permitted user-bubble width. Albums and individual cards are capped at
30% of the window height; albums scale uniformly, retaining tile proportions.
Attachment changes cross-fade without replaying the transition on routine row
reconfiguration. Original files remain unchanged for sending and Quick Look.

The chat header uses a 1 pt `variableBlur` CAFilter with `inputMaskImage` and
`inputNormalizeEdges`, following the approach in nikstar/VariableBlur. It owns
its CABackdropLayer so UIKit does not replace the filter with material filters.
The old transcript opacity mask and system top scroll-edge effect are removed.

Date reported build 97 in the foreground. A local-only fixture containing two
images, a PDF and two text files showed a 184.13 pt wide, 273.6 pt high album on
the 420 by 912 pt window, exactly the 30% height cap. Both document cards shared
the bubble's 400 pt trailing edge; the longer card was 215 pt wide and the short
card 101 pt wide. The longer preview occupied three lines. Tapping the PDF
opened its original, selectable one-page document. The fixture was removed and
the previous chat restored; its pasted-text card also had no size label and
aligned with its bubble. No model request was needed for these layout checks.

The iOS Release build and `make check` passed. The album geometry tests also
passed, including height caps for 1–20 attachments and proportion preservation.
Banana was not updated in this run. The matching app dSYM is retained at
`build/dSYMs/0.1.0-97/Apelin.app.dSYM`, UUID
`1FFA2ADE-8760-3034-A2DD-77F717C46390`. Package SHA-256:
`365ab1fe33538b1e92f102355aa488661b57f659d16b1970425a1d9418274f1d`.

## Compact text-preview line breaks (2026-10-22, build 98)

Text attachment previews now replace repeated newlines with a single newline.
The formatter first bounds the excerpt to 220 characters, then performs at most
eight replacement passes and stops early once no doubled newline remains. It
only formats the preview; stored and transmitted attachment bytes are unchanged.
The actual formatter passed direct checks for nil and blank input, preserved
single newlines, Unicode truncation and every newline-run length from 2 to 218.
The Release build and repository checks passed, and Date reported build 98 in
the foreground after installation. Its current chat had no attachment card, so
this run verifies normalization directly rather than claiming a visual check
of that card. The matching dSYM is retained at
`build/dSYMs/0.1.0-98/Apelin.app.dSYM`, UUID
`F04F056C-FAB5-3BB5-8C65-023D2C5616BC`. Package SHA-256:
`9ea97b86276f92a6695579318f1cbf8ab8983501bdaf22756767c46541a758af`.

## Streaming text and follow control (2026-10-22, build 99)

Assistant messages now use MarkdownStreamView's native insertion fade. Each row
sets a stable message identity, fills restored content immediately and sends
subsequent active-generation updates through the streaming API. Reduced Motion
disables the fade. The sizing view remains non-streaming.

Scrolling more than 75% of the window height away from the latest message
pauses following. Shorter manual scrolls retain the current follow state; a
paused reader stays paused until reaching the bottom or pressing the downward
chevron. The 44 pt button floats above the composer and follows keyboard and
approval-card layout. It has a localized accessibility label.

Date rendered a real 120-line response and followed it to the end. Scrolling
back showed earlier lines and the downward chevron; the paused position stayed
away from the tail. The live test did not establish a reliable button-tap result
because the device was also navigating between chats during inspection. The
button's action is wired directly to resume following and scroll to the bottom.
The iOS Release build and repository checks passed. The installed build 99 dSYM
is retained at `build/dSYMs/0.1.0-99/Apelin.app.dSYM`, UUID
`79774136-558D-3CC8-8267-1E64A6D92238`. Package SHA-256:
`0d385cee3ebfa1624ad8f7c81b7d6b9298b34de5bbdd706aa89c746ed63d5235`.

A later shared-worktree build encountered explicit-self errors in concurrent
ProjectPickerController edits. Those edits are not part of this change; build 99
is the validation build for the streaming and follow-control implementation.


## Chat, project and provider UI regression (2026-10-22)

This round removed the production Message Preview conversation and its simulated
approval/Stop handlers. Temporary validation data was created by the test driver
and removed after the checks. The iPhone was in active use by the owner during
final acceptance, so the final automated UI checks used the existing iPadOS
27.0.1 vphone only; no new virtual device was created.

### Build 105: live chat and project acceptance

The UI driver created one empty project, `UI Verification 1642`, and one chat in
it. It used the already selected `claude-sonnet-5-5` model without reading or
changing its credentials. The following checks passed through the real UI and
backend:

- A first message received a model response and a persisted `title` event. The
  generated title was “Testing chat buttons ensures they respond correctly.”
- The same session began in Relaxed mode, changed to Strict in Settings, and
  accepted a second message with `session.json.mode = confirm`. Switching back
  to Relaxed and sending again changed that same session to `relaxed`.
- A long response exposed Stop in the composer and Stop/Delete in the sidebar
  swipe. Tapping the composer's Stop ended the turn: the button disappeared on
  the next UI query, `isWorking` was false, and the final partial `message` and
  `finished` events were persisted. The separate sidebar context-menu Stop
  attempt was inconclusive because that follow-up had already ended; it is not
  counted as a second successful stop test.
- The sidebar title was plain text, the top bar contained only New Project,
  and the Projects folder sat immediately left of Settings at the bottom. Its
  menu contained General Chat, project choices and All Projects.
- All Projects opened the management sheet. The test project's Delete action
  displayed its name in the confirmation, then removed both its actual project
  directory and its chat JSON. No other project was deleted.

The test session's own log directory was removed after its session had closed.
The original Greeting chat, project selection and permission preference were
restored, and Apelin was verified in the foreground. The receipt and screenshot
are in `build/Device/Banana/ui-105/chat-verification.json` and
`build/Device/Banana/ui-105/stop-and-sidebar.jpg`. The screenshot also shows the
live response, custom top frost, and bottom folder/Settings placement.

`Scripts/test-chat-transcript.sh` passed against the host modules; its receipt is
`build/Device/Banana/ui-105/chat-transcript-tests.log`. It covers replay and stable
identities, completed zero-second/zero-tool rows being omitted, tool-only and
duration-only wording, combined wording, and saving/deleting without a delayed
save restoring a removed chat. The full host harness passed 569 session-host
checks. Initial positioning, the iPhone's automatic new chat after project
restoration, and placeholder cross-fade were reviewed in code; they were not
claimed as final iPhone UI automation results.

### Build 106: selection-menu acceptance

Both user and assistant text exposed Copy, Select All when applicable, Look Up,
Translate and Share, with accessible names. Selection handles used the system's
blue appearance and were not clipped; dragging to extend the selection had
already passed in build 104. Look Up displayed a real definition of “Hello”.
Translate opened Apple's first-use privacy page and returned cleanly without
pressing Continue; an actual translation result was not tested. Share opened
the native popover with the selected “Hello”, without sending it anywhere.
After each dismissal, tapping chats and scrolling still worked. Translate was
also opened and closed in portrait orientation with a roughly 404 pt detail
column, and input still worked afterward. The original Greeting selection,
empty draft, orientation and dismissed overlays were restored. Evidence is in
`build/Device/Banana/ui-106/` (`menu.jpg`, `lookup.jpg`, `translate.jpg`,
`user-menu.jpg`, `share-ready.jpg`, `portrait-translate-retry.jpg`, `restored.jpg`).

### Final package and remaining regression limits

Build 109 includes the build-106 selection-menu correction, avoids rebuilding
unchanged sidebar rows on every streamed token, and includes the final project
menu, frost and daemon-registration changes. Its iPhoneOS Release build and both
package flavors were generated. The app dSYM is retained at
`build/dSYMs/0.1.0-109/Apelin.app.dSYM`, UUID
`6E3D9A7F-3D83-3A25-A5ED-CA1719391363`. Package SHA-256:

- roothide: `1afcfc403762f335ebc6d27593f9589bb5e21f9fa67ad0539db45e1f3a7c402c`
- rootless: `456156c2628654e7c216cd5767f6743bf5fd04ed940fa64a70e6d2d20619d23b`

API configuration editing had already been checked on build 104: the menu read
Edit Configuration, the secure Key field was nonempty, the endpoint was filled,
and Fetch Models was enabled. The check opened and closed the editor without
changing credentials; no key value was copied into these validation records.

Earlier build-102 broad regression runs were not wholly green. The iPad passed
20 cases, failed two and skipped three; the iPhone passed 17, failed five and
skipped three. Both exposed an obsolete SDK-import assertion that expected no
SDK sources even though the default source is now enabled. The assertion now
compares the before/after source configuration; its targeted build-105 iPad
rerun passed, as did all seven smoke cases. The iPhone's build-chain failures
reported missing runnable tools in its pre-existing selected toolchain. The
removal case assumed a lone removable toolchain, but the iPad correctly refused
removing one still bound to another project, and the iPhone had multiple
registered toolchains. Those existing toolchains and user projects were left
alone. The skips required an absent toolchain or a fixture project that was not
present. Rootless packaging is verified, but no rootless device installation or
iOS-16-floor UI result is claimed by this round.

The owner's final parameter revision raises only the page-color frost's top
opacity from 0.5 to 1.0, fading linearly to 0. The blur radius remains 1 pt,
the alpha mask remains linear, and the height stays top safe area plus 20 pt.
The final sidebar menu uses fixed ordering (General Chat, separator, project
names, separator, All Projects), with no row icons apart from selection ticks;
the outer button shows the current project's icon, or a folder for General Chat.


Build 107's first smoke attempt passed only the initial hello (1/7) and then
lost the backend; that run is not counted as passing. Investigation found that
roothide's `launchctl bootstrap system <plist>` can place the job in the
foreground domain, while a label-form `bootout` does not remove it symmetrically.
The packaging fix uses path-form `bootout system <plist>` so roothide can
map the domain, then cleans the system, user/501 and gui/501 labels. It waits for
the old job to disappear, retries registration, and verifies an actual job with
`launchctl print`; registration failure remains a nonzero package-install
failure. `prerm` uses the corresponding removal. The five packaging regression
cases passed, including a missing `launchctl` being reported as a configuration
failure rather than a false success. A manual bootstrap was diagnostic only.
Build 108 registered through its own installation script and passed all seven
smoke cases without manual bootstrap recovery.


### Build 108: final sidebar menu and Stop

On Banana, the Projects menu displayed General Chat, a separator, the project
choices, a separator and All Projects, in that order. Menu rows contained no
icons except the selected checkmark. The button beside Settings displayed the
selected workspace's icon and exposed its project name as the accessibility
value. The General Chat state used the folder icon. Evidence is in
`build/Device/Banana/ui-108/project-menu.jpg`.

A real response in the temporary UI Sidebar Final project was stopped through
the sidebar row's long-press menu. Stop was present while the row was working;
after tapping it, the same chat and session were no longer working, with two
text events followed by the final message and finished events. The chat
remained present. This verifies the sidebar Stop callback. A partial swipe did
not reliably expose its action buttons during these fast streaming runs, so
the swipe gesture and action-width acceptance remain unverified; the context
menu result is not counted as swipe acceptance. The test receipt is
`build/Device/Banana/ui-108/sidebar-verification.json`;
`streaming-sidebar.jpg` records the real streaming state.

The temporary project's Delete confirmation named UI Sidebar Final. Deletion
removed its project directory and chat JSON. Its three closed session log
directories were then removed, and the original Greeting chat, UI Empty
Workspace project and Relaxed preference were restored. Apelin was verified
in the foreground before handing Banana back for build 109. Earlier failed
full-swipe attempts only removed this test's own chats; no existing user chat
or project was deleted.


### Build 109: initial layout

The final build also groups the project list by type and lays out a restored
conversation before fading away its placeholder. The initial scroll settles
synchronous row measurements without animation; it is bounded by the number
of rows and stops if neither the offset nor the content extent progresses.

The actual package installed on Banana without a manual daemon bootstrap and
passed all seven smoke cases. Cold launches of the existing Greeting were
sampled continuously in landscape and portrait. In the captured incoming
content frames, the composer was at the bottom and the final message was
already visible; rotating back to landscape preserved that layout. No model
request or conversation content was created for this check. The samples and
timing records are in `build/Device/Banana/ui-109/startup-landscape/` and
`startup-portrait/`. These are sequential screenshots (roughly 30–160 ms per
sample), not a full-frame-rate recording, so sub-sample flashes and the
iPhone's cold-empty automatic-new path are not claimed as visually verified.


### Build 109: project list sections

The All Projects sheet on Banana displayed Workspace and Command-Line Tool as
separate section headers. Each row contained only its icon and single-line
project name; the type was no longer repeated beneath it. The selected
workspace kept its checkmark. Accessibility exposed each type as a header and
each project as a named button with the selected trait where appropriate.
Evidence: `build/Device/Banana/ui-109/project-sections.jpg`. The sheet was
closed without changing selection or project data, restoring Greeting in the
UI Empty Workspace project.


After commit `5029efa` was pushed, the frozen build-109 package was installed
on Date as well. Date passed all seven smoke cases and the corrected targeted
SDK-import case. Both Date and Banana then launched Apelin with
`frontmost_verified = true`; neither installation required a manual bootstrap.
The package and dSYM remain the exact build-109 artifacts recorded above.

### Project actions, display names and iGhostVT directory links

The project-action integration uses Fila's `open?path=…&tab=new` URL and
`transferExport(.project)` with the existing `.apeproj` format. Display names
are persisted in `apelin-project.json`, while folder names and project IDs stay
stable. ProjectMetadataTests passed 4/4: one automatic name, manual and external
rename precedence, stable identity, invalid/symlink path refusal, and bounded
single-line model candidates. The protocol, schema-fixture and service-table
checks passed 20 + 10 + 3 tests. These are host tests; device acceptance of the
new actions and live metadata observation is recorded separately when run.

The required iGhostVT directory-link implementation was committed and pushed
independently as `4ea3beb` (version 1.6.19, build 156), without a release/tag.
`TerminalLink` accepts only a session ID, a plain new tab, or a validated
canonical existing directory. It rejects commands, duplicate/unknown fields,
relative/missing/file paths, NULs, credentials and fragments. All 16 parser
cases, the existing complete harness, and the iPhoneOS Release build passed.
Both package flavors were made from that build and their version/architecture
were checked:

- `iGhostVT/build/Packages/wiki.qaq.ighostvt_1.6.19_iphoneos-arm64e.deb`:
  `3a2fc1af585acd3fbf27f7db97706b25b315810c05aeb2b65a43f3da7cdb5d38`
- `iGhostVT/build/Packages/wiki.qaq.ighostvt_1.6.19_iphoneos-arm64.deb`:
  `ff175fe5efea70fbf13f34b38779245e2a7fa24bf4013333ca539a7f245c18d2`

The iGhostVT dSYMs are retained in that repository's
`build/dSYMs/1.6.19-156/`. App UUID:
`7BC648D9-41F6-391A-9000-1C3ED882DEB1`; daemon UUID:
`241B51EB-19B4-3657-B847-2D155A3B1315`; io UUID:
`E43E7545-8E62-3D71-A732-01B10D37B2FA`.

A full harness caught a project-creation regression before final packaging:
initial display metadata had re-encoded every generated manifest, changing the
reference template bytes and preventing a fixture's deliberate text edit from
matching. Ordinary/manual creation now leaves the template byte-for-byte
unchanged. Automatic placeholders insert only the two metadata members while
keeping the other template text; templates already carrying those optional
members are updated without duplicate keys. The console's real i3 fixture now
renames its newly created project and verifies the display name and unchanged
project ID. The focused rerun passed all 9 extension/project tests, all 5
metadata tests and both console-script tests (16/16), recorded in
`/private/tmp/apelin-project-regression-tests-final.log`.


## Project distribution and setup (2026-10-22)

Build 110 added explicit release targets to the existing build operation, the
project distribution sheet, per-project display names and the first-run setup
flow. Its package installed on Banana with all seven smoke cases passing.
The device already had Fila 0.8.0; iGhostVT was updated normally to 1.6.19 (156),
whose source commit is `4ea3beb`, before installing Apelin. No dependency check
was bypassed. The companion app and daemon dSYMs are retained in iGhostVT's
`build/dSYMs/1.6.19-156/`.

A disposable tweak project named Distribution UI Check was created with the
existing Objective-C template. Using its actual project menu, Distribute Project
completed both release builds and showed all four stages complete for each
target. Export Packages opened the system share UI, whose accessibility tree
reported two documents; no destination was chosen and nothing was shared or
installed. The produced files were copied back and independently inspected:

- roothide: `iphoneos-arm64e`, an arm64e dylib at the unprefixed
  `Library/MobileSubstrate/DynamicLibraries/DistributionUICheck.dylib`, using the
  `.jbroot` Substrate linkage; SHA-256
  `690960aa5ba5e94995ab03ff5c4b63728fe2f80bbe3866b12b89a3a2cf5770ce`.
- rootless: `iphoneos-arm64`, arm64 and arm64e slices under `var/jb/Library/`,
  using the rootless Substrate framework linkage; SHA-256
  `db4630826b91c6296928860f8ea42e85ab3a955b8d2ac45d1ca778afa04c4fe2`.

The worker recorded separate task IDs, artifact IDs and dSYMs. Evidence and
these test-only packages are in `build/Device/Banana/ui-110/distribution/`.
Host tests also built actual CLI and tweak templates for both targets, checking
archive contents, architecture slices, linkage and hashes. This verifies two
independent builds, not copies or renamed packages.

The build-110 distribution screenshot exposed a duplicate navigation heading:
project name above Distribute Project. The next build removes the prompt and
places the name in the normal Project information section. The setup UI is
being replaced with the requested original Irisin components; neither change is
claimed as visually accepted in build 110. Device input was paused when the
owner resumed using Banana.

The response-style follow-up adds one shared system-prompt section: use the
user's language, keep routine replies brief, and reserve tools and project
inspection for an actual task. It also separates chat titles from project-name
suggestions. The current model returns an optional semantic project candidate;
greetings and generic questions return none, and a plain-title fallback never
renames a project. If a greeting comes first, a later concrete project goal can
still name the placeholder without rewriting the existing chat title.
`ScriptedSessionTests` passed all six tests, including greeting/no-candidate,
concrete-goal/candidate, later-goal naming, and using the current model without
adding the title completion to the conversation. Evidence:
`/private/tmp/apelin-style-title-tests-3.log`. Real-model greeting behavior is a
separate device acceptance check; these deterministic tests do not claim it.

After the metadata regression fix, the complete host harness passed, including
all package tests, worker typechecks and 573/573 session-host checks
(`/private/tmp/apelin-feature-harness-final3.log`). The later response-style and
semantic-title changes passed the full agent-package regression run
(`/private/tmp/apelin-agent-final-semantic.log`), including 57 tests in the main
agent suite. The live Copilot credential-dependent test remained skipped; this
does not establish the real-model greeting behavior on Banana.

The first build-112 project acceptance attempt stopped before any successful
input or test-data change. The received page was Coconut / New Chat; after a
read-only baseline, the first Projects-button tap returned `element not found`.
The next read showed UI Empty Workspace / Greeting, and a later read showed
UI Template Tool with Settings open, still in the same app process. No manifest,
preferences, chat, or session was written by this attempt. The unrelated state
changes are recorded in
`/private/tmp/apelin-project-acceptance112-timeline.json`; they are not evidence
that the project actions or real-model greeting checks passed or failed.

### Build 113 project acceptance (2026-10-22)

The final short pass used the existing disposable Distribution UI Check
project (`11149237-fa55-4d73-9efa-b8b48f8d8310`), preserving its two release
artifacts. Its original manifest was saved before enabling the automatic-name
placeholder for this test.

- A new chat sent only `Hello` through the selected `claude-sonnet-5-5` model.
  It replied `Hello! What would you like to work on?`, called zero tools, and
  generated the chat title `Hello`. The project's display name stayed unchanged
  and `autoName` stayed true; no project-name suggestion event was emitted.
- Rename Project changed the actual manifest to Project Metadata Check and
  cleared `autoName`, keeping the same project ID and physical directory. An
  external atomic manifest replacement then changed the display name to
  External Manifest Check; the visible sidebar title refreshed without an app
  restart (the element wait reported 108 ms).
- Open in iGhostVT used version 1.6.19 (156). The new terminal's actual
  `pwd -P` was `/var/mobile/Documents/wiki.qaq.apelin/Projects/Distribution UI Check`.
  Open in Fila showed that directory, its Sources folder and project manifest.
- Export produced a real `Distribution UI Check.apeproj` (Zstandard archive)
  and reached the native share sheet. No destination was selected and nothing
  was shared. The exported test file was copied to the host and removed from
  the guest.
- The composer accessibility tree had no microphone/Dictate action; its model
  button occupied y=691–724 on the 744-point landscape screen.

Evidence is in `build/Device/Banana/ui-113/project-actions/`: `greeting.json`,
`manifest-renamed.json`, `terminal-cwd.txt`, the Fila/menu screenshots and the
test `.apeproj`. Concrete-goal semantic naming was covered by the host tests,
not repeated with a real model in this device pass. The later requested menu
order/shortened labels are not claimed as part of this build's acceptance.

The original project manifest was restored byte-for-byte. The test Hello chat
was removed through its own Delete menu, and its test session directory was
removed afterward. All PTYs created by this check were closed; the companion
terminal UI was stopped to prevent its selected closed tab from reopening a
PTY. No original terminal session existed. Fila's test destination tab was
left open without editing files. The Distribution project and both release
artifacts remain for the integration agent's final check, with Apelin on that
project's empty New Chat. Earlier saved user selections were not written back.

### Welcome onboarding, build 112 (Banana, 2026-10-22)

The device was in landscape at 1133 × 744 pt (2×); the existing selection was
Coconut / New Chat. Captures are under `build/Device/Banana/onboarding-112/`.
The six pages were visually inspected. The intro retains the copied Irisin
64 pt icon, two-line accent title, content spacing and fixed bottom action bar;
the notification preview retains the Xrash layout. Build Tools showed actual
resolved Command Line Tools 27.0 and iOS SDK 27.0 as installed, in two 65 pt
rows without left icons. Provider rows were Claude Code, Codex and GitHub
Copilot, with disclosure arrows and no subtitles or inline sign-in buttons.

First Project's Not Now advanced without creating a project; notification
Not Now advanced without requesting permission. Get Started dismissed to the
same Coconut selection. Settings → About → Open Onboarding was below Open
Source Licenses, dismissed Settings and reopened the intro. Completing this
replay preserved the selection. A subsequent terminate/launch returned to
Coconut without showing welcome; the completion preference was 1.

The build-112 project-entry modal was inspected (template before fruit-name
field) but superseded before a creation was performed: build 113 embeds the
same actual form in the welcome page. No provider login, environment install,
project creation/deletion, notification request, or preference restoration was
performed in this check. Loading shimmer was too brief to capture on the
already-resolved environment; persistent row identity is covered by source
review, not claimed as a recorded timing test. Portrait/iPhone and enlarged
Dynamic Type were not exercised in this pass. Pending build 113: embedded-form
creation and resulting selected-project chat, plus the SDK accessibility-value
deduplication.

### Final integration build 113

The complete final host harness passed again in
`/private/tmp/apelin-feature-harness-final112.log`: 573/573 session-host checks,
all package suites and worker typechecks. Build 113 incorporates the shared
project form inside welcome, preserves that form across Back/Next navigation,
and validates canonical project and manifest paths before listing or
starting distribution. `make check` and the iOS Release build passed.

Build 113 installed normally on Banana and launched in the foreground. Its
welcome Project page was observed with the actual shared template and name
fields, one welcome heading and the original bottom action bar. Entering an
invalid `../bad` name disabled Create Project. The SDK row's accessibility value
contained Installed once. The remaining welcome re-entry and actual creation
checks were not completed: the page changed to Notifications without a
successful input from this test, and then changed again during the following
bounded checks. No test project was created and no existing preference backup
was restored over the newly observed user selection. The shared-form return
state and child-controller ownership were reviewed in source instead.

The package pair is frozen in `build/TaskPackages/features-113/`, and all seven
dSYMs are retained in `build/dSYMs/0.1.0-113/`. The app UUID is
`7FAA8343-02E2-3ED6-9ECC-857AD54591F1`. Package SHA-256:

- roothide: `d9b5fddf8e49ada110db2a313c3395bc80a5d05c6cb2ccee9ab715a55f08baf9`
- rootless: `56fd1ce14bde0dbe1cb153ff01f6d59fe4096bc86c86394c4d904487fdf2b69f`

Build 114 contains the final welcome-only follow-up: every Not Now action uses
the same secondary gray style above its primary action, and Notifications has
the normal Back navigation. It retains the shared project form when returning.
The Release build and packaging checks passed. The frozen pair is in
`build/TaskPackages/features-114/`; all seven dSYMs are in
`build/dSYMs/0.1.0-114/`, app UUID
`A1F4DB44-DEEE-3FE9-8ADB-17B9BDECD65D`.

- roothide SHA-256: `68adcebfc1f8e47a16bc4c60ea85c2f043491b7f6096b2af285e7541023d0f54`
- rootless SHA-256: `94299047afc08214de0de307998ae725a9f87d16fc63609c3f777ea9bc9687ca`

On Banana, build 114's First Project and Notifications pages placed the gray
Not Now button at the same vertical position above the primary button. The
Notifications Back button returned to the unchanged Raspberry form. Both
pages were captured in `build/Device/Banana/ui-114/`. This check skipped project
creation and notification authorization.

A separate, explicitly synthetic offline transcript exercised bullets, nested
bullets, ordered items 51–53, task lists, a multi-paragraph list item, normal
paragraphs and a code block. Its screenshots confirmed compact list spacing
while body wrapping, list indentation and code layout remained intact. The
composer had no microphone and retained its bottom safe area. This was a layout
fixture, not a model response; it was deleted and the immediately preceding
selection restored. The original Distribution UI Check project and its two
release artifacts are retained for the dedicated follow-up distribution-target
work; user projects were not deleted.

The final build-114 Banana smoke suite passed all seven cases
(`/private/tmp/apelin-ui-smoke114.log`), including daemon handshake, terminal,
files, logs, diagnostics and managed installation. No new protocol or worker
failure was observed after the welcome changes.

After commit `926243f`, the exact frozen build-114 roothide package was
installed again on both devices. Date first received iGhostVT 1.6.19 normally
(with Fila 0.8.0 already present); no dependency force flag was used. Both
Apelin package installations completed and launch reported verified foreground
state: Date PID 36697 and Banana PID 23732. The logs and compact installation
records are under each device's `ui-114/` evidence folder. Date received no
additional interactive tests during this final installation because it was
being used by the owner.

Build 116 is a host-verified candidate for project export, single-target
distribution, agent memory and diffable table updates. `make check`, the full
`make harness` (including 573/573 session-host checks), and the final incremental
iOS Release build passed. Both packages are frozen in
`build/TaskPackages/features-116/`; all seven matching dSYMs are retained in
`build/dSYMs/0.1.0-116/`. Each package contains nine checked Mach-O files, with
no repository or private build path. The app UUID is
`B6E585FE-6722-30FC-BCCB-61C4ABD9747C`.

- roothide SHA-256: `8ecb2b22f91732fa4bdc694b3a543727829c96520c634fb0f2259480f26d58f6`
- rootless SHA-256: `ffaaef9010148698a261d829b9471c14767a60b49a629b5d49b092cbd5055b61`

The candidate was built from the shared working tree, including concurrent
welcome and navigation edits retained outside this change. It has not been
installed or validated on a device: the owner deferred device work while
another task uses it. Memory UI, table interactions, the final distribution
snapshot update, export cancellation and test-fixture cleanup remain pending.

## 0.1.0 release smoke (2026-10-22, build 1)

The squashed 0.1.0 tree, built for roothide as build 1, went onto the
iOS 26.4 iPhone vphone over build 4 through `irisin-cli install --yes`.
Three things matched: the installed app and Info.plist hashes matched the
deb's, and LaunchServices' record reads build 1. `i1-smoke` passed all
26 steps. In General Chat, with an OpenAI-compatible account, a greeting
was answered and the conversation took a title. A message sent while a
reply streamed appeared once, was taken by the run and was answered. No
Apelin, apelind or worker process left a crash report.

A reply that is only `4.` drew nothing. MarkdownView reads it as an empty
numbered-list item and draws no marker for an item without a paragraph.

## Widgets, the Live Activity and `apelin://` links (2026-10-22, builds 5 and 6)

On the iPadOS 26.4 iPad vphone (roothide, Irisin 4.7.5), over build 4, both
roothide builds went in through `irisin-cli install --yes`, then
`uicache -p`. The vphone had no model account, so a stand-in
OpenAI-compatible endpoint on the host's bridge answered the turns: one never
ended (working), one called `run_code`, which Strict mode asks to approve
(waiting), one answered HTTP 500 (failed), one answered at once (done). The
account was signed in and the sessions opened through console scripts; every
session reached the app only through `apelin://conversation/<session ID>`
(`apps.open_url` and `uiopen`), which took each one in (`ChatAdoption`) and
selected it in its project.

- **App Group**: containermanagerd made `group.wiki.qaq.apelin` for the
  ad hoc signed app and the sandboxed extension; the snapshot the app wrote
  there read back in the order and states the design has (waiting
  `run_code`, working, working, failed, done; 2 working, 1 waiting).
- **Widgets**: Apelin is in the widget gallery; its previews read the real
  snapshot. Small and medium went on the home screen and showed, in turn,
  waiting with three in progress, working after the approval was approved
  (the medium list re-ordered, the approved one grey), all finished with the
  newest failed (red, no counts in the header), `Approve: Run` from build 6,
  a project's display name changed to 相机翻译 by `projectRename`, and the
  empty state once the conversations and projects were deleted and the app
  relaunched.
- **Taps**: a medium row opened its conversation in its project; the small
  widget opened the waiting one at its approval card; from a killed app the
  small widget cold-launched it at the conversation it shows, over the saved
  selection.
- **Links**: a transcript link `[…](apelin://conversation/…)` opened that
  conversation in place, switching project; `apelin://project/Network%20Speed`
  opened that project's most recent conversation; an unknown conversation ID
  showed "Conversation Not Found" and left the page as it was.
- **Live Activity**: iPadOS 26.4 shows it on the lock screen (with the
  system's one-time "Allow Live Activities from Apelin?"): header, counts and
  rows, amber with an approval waiting. A tap opened the latest working
  conversation from another one; Stop on the last working conversation ended
  it; one left by `killall -9` was ended by the next launch. The Dynamic
  Island is an iPhone's and was not seen.
- **Found**: after build 6 went over build 5, chronod refused the new
  extension's timelines (`bundleStubNotSupported`) and kept the last render
  until it restarted (AGENTS.md ▸ Widgets). English "Needs Approval · Run"
  was cut off in the small widget; build 6 says `Approve: Run`.

Not run: an iPhone (Dynamic Island), iOS 16.0–16.1 (no ActivityKit), dark
appearance and Chinese on the device (both drawn from the same views and
catalogue the Mac build checked), rootless (packaged and checked on the Mac
only), and `applicationWillTerminate` (a vphone kill delivers none). The
test conversations, projects, console files and both widgets were removed
afterwards; build 6 stays installed.

## Background notifications (2026-10-22, build 9)

The roothide build 9 went onto the iOS 26.4 iPhone vphone
through `irisin-cli install --yes`, followed by `uicache -p` and a respring.
The first message sent from a chat showed the system's "Would Like to Send
You Notifications" prompt, and Allow took. With Apelin on the home screen, a
turn that finished posted the chat's title over the reply's first paragraph,
with Apelin's icon; the banner then stayed in Notification Center. A Strict
session's `run_code` request posted the first message's opening over
"Approval Required" (the catalogue key, resolved by the system) and the
call's own reason. The approved turn's finish and a later turn posted too,
with Apelin not running. Each banner went into the delivered list as
`<session>.turn.<n>` or `<session>.approval.<n>`, with the session as its
thread and `link` = `apelin://conversation/<session>`. With Apelin in front,
apelind still added the request and the app got `UIWillPresentNotification`;
nothing showed and nothing was delivered. Opening the conversation emptied
the delivered list. After the session host was killed and the session opened
again, the replayed `approvalRequested` and `finished` posted nothing and the
new turn posted once, from `notices.json` on disk. A `closeWhenFinished` run
posted nothing. Not run: `make device-test` (the guest is reachable only from
its host), and the tap, which needs the `apelin://` router.

## 0.1.1 release smoke (2026-10-22, build 28)

The 0.1.1 roothide build 28 went onto the iOS 26.4 iPhone vphone and the
iPadOS 26.4 iPad vphone through `irisin-cli install --yes`, each after the
released 0.1.0 (build 13) had been installed for the before screenshots;
the dSYMs of all eight images matched the deb's. `i1-smoke` passed on both
(26 steps on the iPhone). On both: the sidebar's plus opened New Chat and
New Project; with `debug.monochromeAccent` set the checkmarks and filled
buttons turned black, and blue again once it was removed; the chat's …
menu led with Rename… (a renamed chat kept its name in the title and the
sidebar), General Chat's offered Rename…, Open in iGhostVT and Open in
Fila and no Model Providers; Distribute… was greyed on an empty workspace;
Settings ▸ About listed Logs, which opened this launch's journal, and its
… menu Open Onboarding and Report a Problem; `apelin://project/<folder>`
opened that project's latest chat and an unknown conversation said so.
On the iPhone, with an OpenAI-compatible account: asked which toolchains
and SDKs were installed, the agent answered from its prompt with no tool
call (0.1.0 said it did not know); a link it wrote opened its project; a
turn finished in the background posted its banner, the Live Activity
showed in the Dynamic Island, and the banner tapped with Apelin killed
cold-launched it onto that chat; a reply measured above 50 tokens a second
was followed for a page. On the iPad: a file dragged from Files in
Windowed Apps tinted the composer and became an attachment card; the
small and medium widgets were added and opened Apelin; the chat, its menu
and Settings drew in light and dark. No Apelin, apelind or worker process
left a crash report.

Found: a banner tapped in Notification Center did not open Apelin, either
killed or suspended. SpringBoard hinted a side swipe instead of running
the default action, while the same banner tapped as it arrived did open
it. On the iPad, the floating keyboard bar covered the sidebar's toolbar
until a relaunch, the widget said "No chats yet" with idle chats listed,
and after some relaunches the sidebar's list sat about 16 pt lower.

## Notification Center taps (2026-10-22, build 28)

The Notification Center tap that only hinted is SpringBoard's, not
Apelin's. On the iOS 26.4 iPhone vphone, an Xrash crash notification
hinted the same way (`shouldHintForDefault hinting notCape -
doesn'tForceDefault`, then `Hinting side swipe instead of executing
action`), and the Open revealed beside Apelin's own cold-launched it onto
the chat. CoverSheet hints on an iPhone with no biometric unlock and
`SBAlwaysAllowDefaultAction` unset, whatever the notification carries.
With that key set in `com.apple.springboard`, SpringBoard logged
`allowsDefault` and one tap opened the chat, killed and suspended; the
key was removed afterwards. A banner tapped as it arrived opened its
chat, and with Apelin in front `willPresentNotification` answered 0 and
nothing showed. A Clock timer is a Live Activity on 26.4 and never
reaches Notification Center.

## Right to left, untitled chats and day headings (2026-10-22, build 13)

On the iPadOS 26.4 iPad vphone, in Arabic: the sidebar, composer, model row,
bubble and thinking header were mirrored, and in a narrow window the drawer
came out from the right, panned left to open and right to close; English was
unchanged. An earlier build's "New Chat" read 新規チャット in Japanese and took
its first message as its name; French headed the list "Aujourd'hui", "Mardi".

## 0.1.2 release smoke (2026-10-22, build 19)

The 0.1.2 roothide build 19 went onto the iOS 26.4 iPhone vphone (over the
released 0.1.1, build 28) and the iPadOS 26.4 iPad vphone through
`irisin-cli install --yes`, the same deb on both; the dSYMs of all eight
images matched it. `i1-smoke` passed on both (26 steps). With Apelin's own
language set to Arabic, 0.1.1 had stayed English and left to right; 0.1.2
laid the bar, the composer and its model row, the menus and Settings out
right to left, the iPad's sidebar on the right and the iPhone's drawer out
from the right. Japanese and English screens were translated and unclipped,
a chat 0.1.1 had saved as "New Chat" showed in the current language, and on
the iPhone a message to the model was answered. No Apelin, apelind or worker
process left a crash report.

## Agent prompt and skills for imported repositories (2026-10-23, build 23)

The roothide build 23 of `446b337` went onto the iOS 26.4 iPhone vphone over
0.1.2 build 19 through `irisin-cli install --yes`; the app registered and
came up as the verified foreground app, and the installed apelin-agent
carries the apelin-project-description skill. No agent session was run on it, and
`i1-smoke` was not: the guest sits behind its host's NAT, which has no
Python for `Scripts/device.py`. A probe as mobile checked what the
environment section now states: git and ldid are on the search path; make,
cmake, ninja, perl, python3 and xcrun are not; sed is GNU 4.9 and plutil is
not Apple's. The bootstrap's shell sees the bootstrap as `/` and the real
root as `/rootfs`: with the working directory at the data folder's real
path, `pwd -P` and `realpath` printed `/var/mobile/Documents/…`, which names
the system's folder to Apple's compilers.

## Workspace builds (2026-10-23, `7b3cb5d`)

The roothide build of `7b3cb5d` went onto the iOS 26.4 iPhone vphone through
`irisin-cli install --yes`. Two workspaces were written by hand as mobile,
each declaring `"external": {"script": "apelin/build.sh"}`, and driven by
console scripts dropped in the inbox (the app quit first through vphoned's
`apps.terminate`, since a foreground app does not read the inbox again):
- A script that only packaged a text file with the bootstrap's `dpkg-deb`:
  `projectCheck` answered `buildSystem: external` and passed; the build ran
  the script as mobile with `APELIN_BOOTSTRAP=roothide`,
  `APELIN_ARCHITECTURE=iphoneos-arm64e`, an empty `APELIN_PREFIX` and the
  registered toolchain's clang on `PATH`, and registered its package;
  `installPackage` and `removePackage` went through Irisin, and the
  package was gone afterwards.
- A script that compiled a tweak with that clang (`SDKROOT` the registered
  26.4 SDK, deployment target 16.0), signed it with `ldid -S` and
  packaged it: installed through Irisin, `confirmLoaded` with
  `trigger: respring` found the marker logged by SpringBoard and the
  filter selecting it (the load check read from the build's record), and
  the removal went through.

The Strict-mode approval of an agent's workspace build was not exercised on
the device (no agent session ran); the Mac covers it (the session host's
checks and `ExternalBuildToolTests`).

## arm64e constant strings and pointer authentication (2026-10-23)

A report said Apelin's arm64e builds left constant strings without their
pointer authentication. On the iOS 26.4 iPhone vphone (CLT 27.0, SDK 26.4,
roothide), the pipeline's own products with `@"…"` constants — an agent's
tweak and the UIKit app template — and a test dylib compiled, linked and
stripped there with the registered tools all bind each `__cfstring` class
as `auth-bind … (div=0x6AE1 ad=1 key=DA)`, the same as Xcode's. On the Mac,
the clang and ld of CLT 14.2, 15.0, 15.3, 16.4 and 27.0 (Apple's packages,
run as they are) emit the authenticated relocation for every constant
string and link it signed, with identical fixups section by section for
classes, categories, blocks, function pointer tables and C++ virtual
tables, and for weak frameworks and deployment targets 13.0–16.0.

The one exception is CLT 15.0's linker given `-undefined dynamic_lookup`
or `suppress`, for a dylib, a bundle or an executable alike: it writes
plain dyld opcodes, so every signed pointer is bound bare. On the vphone,
a dylib returning a constant string answered `length` when linked
normally and was killed (signal 9) on that first message when linked with
`-undefined dynamic_lookup`; CLT 15.3's threaded binds under the same
flag ran. apelin-build now refuses such a slice at its link; Apelin's
templates and steps never pass the flag, so only a `linkFlags` entry or a
workspace's own script can.

## Composer picks and workspace distribution (2026-10-24, `8fbfa02`)

The roothide 0.1.6 build 37 of `8fbfa02` went onto the iOS 26.4 iPhone
vphone over 0.1.4 through `irisin-cli install --yes` (Irisin 4.7.5). The
first attempt stopped while unpacking (`irisin-journal/<transaction>/183`
not found) and left the package `reinstreq half-installed` at 0.1.4; the
same command again installed, configured and registered it. vphoned's
`apps.launch` then verified Apelin as the foreground app, and the composer
came back with the saved model and its effort (deepseek-v4-pro, High),
read through the new per-control keys. No agent session ran, and the
workspace distribution page was not opened on the device; the Mac covers
the release findings (`ExternalBuildTests`), check_distribution
(`ChannelHostBackendTests`) and the menu's build method (`Tests/Onboarding`).

## 0.1.7 release smoke (2026-10-24, CI build 8 of `eb25512`)

The roothide package CI built for the release commit (the bytes Release
published, SHA-256 checked against its `SHA256SUMS`) went onto the iOS 26.4
iPhone vphone (over 0.1.6) and the iPadOS 26.4 iPad vphone (over 0.1.2)
through `irisin-cli install --yes`, each on the first try. The smoke suite
ran on both as `Scripts/device.py` runs it — each script dropped in the
inbox, the app quit and launched again through vphoned, the run followed
to its `run.end`, the harness entry's checks and cleanup after — by a shell
stand-in on the hosts, which have no Python. Every script ended `ok`:
`hello`, `terminal`, `logs`, `diagnostics`, `i3-image-check-refused` and
`i1-smoke` (26 steps) on both, and `files` on the iPhone; the iPad has no
tweak extension, toolchain or SDK, so `files` was skipped there.

## 0.1.8 Compact… (2026-10-24, CI build 35 of `6093216`)

The roothide package CI built for the tagged commit (SHA-256 checked against
its `SHA256SUMS`) went onto the iOS 26.4 iPhone vphone and the iPadOS 26.4
iPad vphone through `irisin-cli install --yes`, over CI's build of
`340f2b4`, which went on first over 0.1.7. Driven through vphoned (taps,
`input.type`, the accessibility tree, screenshots), on the iPhone with its
deepseek-v4-pro account:

- A General Chat conversation with two `run_code` turns of about 80 KB of
  output each: Compact… is enabled between replies, asks, shows the
  progress card, and the session compacted 7 messages in about a minute
  (`compactionFinished` {compacted, 7}; `transcript.json` 34 KB). The next
  message got the first command's last number right from the summary.
- While a reply runs (Stop shown), Compact… is greyed out.
- A one-message chat: Nothing to Compact.
- A stopped session, the host restarted by the install: Compact… reopens it
  and the outcome arrives through the replay (Nothing to Compact in about
  2 s, no row repeated). On `340f2b4` the replay swallowed both compaction
  events and the card waited for good — fixed in `6093216`; the one
  conversation that build had read stays inconsistent on that vphone and
  repeated its last turn when compacted again.
- The card's Cancel needs a held touch from vphoned (`input.long_press`): a
  zero-length tap on a button inside its scroll view is swallowed. A finger
  is not.

On the iPad, which has no model account, the app launches and Compact… is
greyed out for a chat with no session. The native ChatGPT Codex path
(`compaction_trigger` on `/codex/responses`) was not run on a vphone: no
Codex account is signed in there.

## Turn display and notices (2026-10-24, CI build 37 of `25d59a1`)

The roothide package CI built for `25d59a1` (build 37, SHA-256 checked
against its `SHA256SUMS`) went onto the iOS 26.4 iPhone vphone and the
iPadOS 26.4 iPad vphone through `irisin-cli install --yes`, over 0.1.8
(build 35). On the iPhone the first install stopped mid-unpack with
`irisin-journal/<transaction>/183` missing, as once before under Irisin
4.7.5; the same install again went through. The smoke suite ran on both by
the shell stand-in and every script ended `ok` (`files` skipped on the
iPad, which has no tweak extension, toolchain or SDK).

On the iPhone, with its deepseek-v4-pro account in Relaxed, driven through
vphoned (taps, `input.type`, `input.button` home, the accessibility tree
about five times a second, screenshots):

- The running summary has no line under it: neither the thinking preview
  nor, in this build, the newest call's line, which came back in `80fb07a`
  and has not run on a device. Its title is followed by the arrow and the
  grouped count from the turn's first `received`: 112, 1,947, 4,244, 6,349
  … 13,831 through 100 s of thinking and a 200-line write (4,352 bytes).
  The tree reads it as the title's value, `Thinking… = 13,831 tokens
  received`; a finished summary has none.
- The trace sheet shows the thinking, the call's arguments (its JSON as
  sent, escapes and all) and its result, `Created lines.c (4352 bytes, +200
  -0)`, as plain body text. A long press selects a word and offers Copy,
  Select All and Look Up.
- The quiet stand-in never came up by itself: a 900-word reply streamed for
  15 s with no two-second gap in its log, and text gave way to a call in
  under 0.5 s. Stopping the agent workers with `SIGSTOP` for 4–9 s forced
  it: about a second after the last chunk, `Thinking… ⬇482` stood under
  the reply and went when the text came back; stopped before a `run_code`
  call, `Thinking… ⬇142` under the paragraph became `Executing 1 tool…
  ⬇270` in the same place, with no gap or flash at two frames a second.
- notify_user, with Apelin on the home screen: asked for four notices 31 s
  apart, three banners came, each headed by the conversation's title, then
  the notice's title as subtitle and its body; after the third the tool
  said `0 more may go this turn` and the model sent no fourth. Notification
  Center stacked them with the turn's own end banner. A notice while Apelin
  was in front showed nothing. A banner tapped while Apelin had another
  conversation open opened Apelin on the notice's conversation. The lock
  screen's Live Activity still said 1 working after the turn had ended:
  only the app updates it, and it was suspended.
- Streaming the 900-word reply took 23–27 % of a core in Apelin
  (`cpu_seconds` from vphoned's `processes.list`), its footprint 39–72 MB,
  then 0 % at 46 MB once it ended; scrolling that conversation (13 turns,
  six of them essays) drew no blank row at 9–16 %. No 0.1.8 figure from
  this vphone stands beside it.
- Replies: a greeting got one line, and a reply asked for in one sentence
  was one. "What is a tweak on a jailbroken iPhone, and how would I make
  one with Apelin?" got 279 words, no tool call, and described the tweak
  template as Logos (`Tweak.x`, `%hook`); the template is plain
  Objective-C (`objc-hook/Sources/Tweak.m`) and Logos is not built. The
  model did not read apelin-tweak-development.
- Settings ▸ Agent ▸ Skills lists apelin-bootstrap-paths, apelin-tweak-runtime,
  apelin-preference-bundle and apelin-package-dependencies among the nine built-ins, and
  apelin-bootstrap-paths opens its body.

On the iPad, which has no model account, Apelin launches and Skills lists
the same nine with none of the user's. It has no conversation with a trace
or a run, and no replay is linked into the app, so neither the summary nor
the trace was seen there.

## Final device round (2026-10-25, CI build 45 of `2d226a3`)

The roothide package CI built for `2d226a3` (build 45, SHA-256 checked
against its `SHA256SUMS`) went onto all four vphones through `irisin-cli
install --yes`, each on the first try: the iOS 26.4 iPhone and the iPadOS
26.4 iPad over build 37, the iOS 27.0.1 iPhone and the iPadOS 27.0.1 iPad
over 0.1.0. On both 27.0.1 guests `uicache` printed "Unable to register"
(▸ AGENTS.md, Gotchas); the app was registered and opened, on its welcome
page, and its installed `Info.plist` was the package's byte for byte. The
smoke suite ran on all four by the shell stand-in and every script ended
`ok` (`files` skipped on the iPads, which have no tweak extension). No
crash report for Apelin, apelind or a worker came out of the round on any
of the four.

On the iPhone, with its deepseek-v4-pro account (an OpenAI-compatible key),
driven through vphoned (taps, `input.type`, the home button, the
accessibility tree, screenshots):

- The running summary: the title, `arrow.down.circle.fill` and the count
  growing from the turn's first `received` (23, 62, 106 … 653, 780 through
  a turn of four calls), the title going from `Thinking…` to `Executing 1
  tool…` while a call ran. Under it the newest call's line: `hello.c +45
  −0` and its reason for the file_write, `hello.c +1 −1` for the file_edit,
  the reason alone for the shell_run; no thinking text, no typing. The
  count as the figure then a plain arrow (`e07e868`) has not run on a
  device.
- The trace sheet: the thinking as plain text, then each call's arguments
  by name, one to a line, the value under it: the file_write's `content`
  reads as the C file it wrote, line breaks and all; the file_edit's
  `new_text`, `old_text` and `path`; shell_run's `argv` as compact JSON;
  then the result (the edit's unified diff, the command's JSON).
- The quiet stand-in: with the agent workers stopped (`SIGSTOP`) for 7 s
  in the middle of an essay, `Thinking… ⬇648` stood under the reply until
  the text came back.
- The accessibility tree now carries each assistant reply as one text
  element with its whole text; build 37's tree had none. Replies written
  on build 37 read the same way.
- The new tool names: file_write, file_edit, file_read, shell_run,
  apelin_skill_read, apelin_template_list, apelin_project_create,
  apelin_project_list, apelin_project_rename, apelin_memory_save,
  apelin_skill_save, apelin_skill_remove and apelin_notification_send all
  ran. A conversation recorded on build 37 (notify_user and run_code calls)
  still titles them "Send a notification" and "Run a command" in its
  trace, and a new message in it ran shell_run with no provider error.
- Under Strict: apelin_project_list from a project's chat answered without
  asking. apelin_skill_save asked with a card holding the description, the
  name and the whole body, Deny and Approve and no session grant; approved,
  the skill was listed in Settings ▸ Agent ▸ Skills under Your Skills.
  apelin_skill_remove asked naming it and, approved, left the skills folder
  empty. apelin_project_create from a project's chat created a second
  workspace without asking and answered with its link, which opened it.
  apelin_project_rename renamed its own project with no card, the sidebar's
  title followed, and it renamed it back.
- Root, in Strict: a shell_run with `root: true` (`id -u`) asked with the
  card's red line "Runs as root, with full control of this device", then
  `argv` and `root` by name. With Apelin on the home screen the banner's
  subtitle read "Root Approval Required" under the conversation's title,
  and the Dynamic Island's count turned amber. Approve ran it at once —
  this vphone has no passcode, so nothing was asked — and stdout was `0`.
  Denying the next (`whoami`) ran nothing: the call ended "the user
  declined this call". Settings ▸ Permission Mode ▸ Full asked "Enable Full
  Mode?" with its warning and, confirmed, raised no prompt; the same root
  command then ran with no card. Back in Strict the next root call asked
  again, and was denied. The vphone was left in Strict.
- apelin_notification_send under Strict, with Apelin on the home screen:
  the banner came with the conversation's title, the notice's title as
  subtitle and its body, and no approval card; the turn's own end banner
  followed. A banner tapped while Apelin had another conversation open
  opened Apelin on the notice's conversation.
- Prompt caching, in a project's chat, 34 requests over 13 messages
  (`usage` from `transcript.json`; DeepSeek reports no cacheWrite): the
  first request read nothing (15,492 prompt tokens); every later one read
  92–99.6 % of its prompt from the cache, the second message's first
  request 99.0 %. A project memory saved in another project's chat cost
  nothing (the next request 99.6 %), nor did an approval answered within a
  minute. The misses were the expected ones, once each: Relaxed to Strict
  (0 % read, then 94 %), the skill saved (13 %, the tools alone) and Strict
  to Full (13 %). Removing the skill and going back to Strict missed
  nothing (98.5 %, 98.8 %): the earlier prefixes were still cached.
- "What is a tweak, and how would I make one with Apelin?" in a new General
  Chat read apelin-tweak-development first (apelin_skill_read in the trace) and
  answered that Apelin's tweak is plain Objective-C, no Logos or Theos:
  hooks installed with MSHookMessageEx in a constructor, the original
  called instead of `%orig`, the filter plist, then template, build,
  install and confirm. The same question in the build-37 conversation,
  whose earlier answer had described Logos, got Logos again and no skill
  read.
- Scrolling a conversation of 14 turns, six of them essays, drew every row,
  at 10–18 % of a core and a 47–60 MB footprint.
- Opening that conversation, from the sidebar, twice in one launch, put it
  at the start of its seventh turn (the C essay), not at its end; the
  chevron showed and took it to the last reply. A short conversation
  opened at its end.

On the iPad, which has no model account: Settings ▸ Permission Mode ▸ Full
asks the same; Cancel kept Relaxed, Enable Full Mode selected Full with no
prompt (no passcode), and Relaxed was put back. Skills lists the built-ins.

The test projects (with their chats), the skill, the memory and the new
General Chat conversation were deleted through the app afterwards.

Four changes landed after that round and have not been on a device: the
received count's arrow moved right of the figure (`e07e868`), the approval
card rewritten to say the call's reason and a root command as typed
(`a8cca0a`), a long chat opened at the latest message (`0400b2f`), and the
system prompt frozen with each message's `<system-state>` (`f74afc1`). They
passed `make harness`, `make check` and the CI build; 0.1.9 ships them
unverified on hardware, and the next round should open a long chat, read a
root card and switch the approval mode mid-chat on the iPhone vphone.

## Small images, the pane's icon and publishing (2026-10-30, 0.3.2)

CI's packages of `6b57f8e`, roothide, on the iOS 26.4 iPhone vphone (Strict,
deepseek-v4-pro) and the iOS 26.4 iPad vphone:

- A project made from the Preference Bundle template 0.1.3, built Debug and
  installed, carries `icon.png`, `icon@2x.png` and `icon@3x.png` in
  `/Library/PreferenceBundles/IconPane.bundle`, and its entry names
  `icon.png`. Settings showed no row for it (Known limitations).
- A General Chat had the agent show that `icon@3x.png` (87 px) and a
  1290×2796 screenshot with two `file_show` calls: the icon came out a
  32 pt tile on the iPhone's 3x screen and about 44 pt on the iPad's 2x
  screen, the screenshot at the 30 % height limit as before (the iPad's
  copy of the conversation was carried over from the iPhone).
- `apelin_package_publish` given a release build of that project, whose
  record says `Release`, passed the configuration check and stopped at "no
  package repository is linked"; nothing reached GitHub.
