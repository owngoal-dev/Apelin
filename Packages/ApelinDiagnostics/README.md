# ApelinDiagnostics

Milestone 1 plan §8 (respring and confirming a load) and §9 (debugging), as a
standalone Swift package. iOS 16 and macOS 13; everything but the IcliKit
link builds and tests on a Mac:

```sh
swift test --scratch-path /private/tmp/apelin-spm-w7
```

## Products

| Product | Runs in | Links | What it does |
| --- | --- | --- | --- |
| `ApelinDiagnostics` | `apelin-diagnostics` (mobile) | `IcliKit` 1.0.0, iOS only | Logs, crash report list and read, screenshot, UI tree, UI actions, foreground app, running apps, respring fallback — every one through icli |
| `ApelinLogReader` | `apelin-log-reader` (root) | system libraries only | The live unified log through a fixed `LogFilter`: one bounded read, or one stream kept open for a whole window (`listen`) |
| `ApelinCrash` | mobile | Foundation | Xrash's report decoder, symbolicator and blame; dSYM matched by image UUID; package owners through a protocol |
| `ConfirmLoaded` | mobile or host | system calls only | Marker log line and static filter match, each answered apart; never the image list |

Two more products are the workers themselves, so `make harness` tests what
runs: `ApelinDiagnosticsWorker` (apelin-diagnostics: `crashList`,
`crashSymbolicate`, `confirmLoaded` as a task, `captureScreen`,
`readUITree`, `uiAction` and, through the shared pump, `logStream`) and
`ApelinLogReaderWorker` (apelin-log-reader: `logStream` over
`SystemLogReader`; system code only, checked by
`Scripts/check-system-only.py`). Both depend on `../ApelinKit` for the wire.

`ApelinDiagnosticsCore` (in every product but `ApelinCrash`) holds the
request and result types: `LogFilter`, `LogEntry`, `UIAction`, `Screenshot`
and the rest. Foundation only.

### The closed surface

Nothing takes a command, a predicate or a free path:

- `Diagnostics.readLogs(LogFilter)` — subsystem (and its dotted children),
  exact process name, message substring, minimum level, 0.1–60 s window,
  1–5000 entries. `Diagnostics.listen` takes the same filter for a stream
  as long as `logStream`'s window.
- `listCrashReports(CrashReportListRequest)`, `readCrashReport(path:maxBytes:)`
  — the path must `realpath(3)` to a `.ips` or `.crash` directly inside one
  of icli's three crash directories; icli reads at most `maxBytes` (≤ 4 MB),
  cut back to a whole character, and refuses anything but a regular file.
  Protected reports stay the host's: it opens them by report id.
- `screenshot()` — JPEG bytes in memory, capped at 2 MB; never a path.
- `uiTree(UITreeRequest)` — 1–2000 elements.
- `perform(UIAction)` — `.tap(point)`, `.tapElement(selector)` (after
  waiting for the element), `.swipe(from:to:seconds:)`,
  `.type(text:delayMilliseconds:)`, `.press(button)`, each range checked,
  refused while locked but for a wake. It answers a `UIActionOutcome`: a
  wake the `LockState` it left, a `type` its `TypedText` (the values that
  changed while it went in, and whether one holds the text), every other
  action nil. Binding the action to a verified
  target is the host's job (`settledForegroundApp(expecting:)`).
- `foregroundApp()`, `runningApps()`, `respring()`.

`IcliSurface` is the seam: `IcliKitSurface` calls IcliKit (iOS only); the
tests pass a fake that answers with dictionaries in icli's own shapes.

### Crash symbolication and blame

Ported from Xrash at 9dcfb4d (MIT, `LICENSE` beside each ported folder, a
header on each file). Changes:

- `Symbolicator(dsyms: any DSYMLookup, openImage:)`. `ProjectDSYMs` indexes
  the dSYMs a project's builds kept, by image UUID, read in place;
  `DSYMStore` (Xrash's copying store) still conforms. A UUID that does not
  match is never symbolicated.
- Xrash's `SystemSymbolStore` (shared cache extraction) is not ported: it is
  the only part that needed MachOKit, and system frames keep the names the
  report already has. So `ApelinCrash` adds no dependency.
- `DpkgDatabase` (a reader of `<root>/var/lib/dpkg/info`) is replaced by
  `PackageOwnerLookup`. `StaticPackageOwners` takes the session host's
  installation record (file → package); `PackageOwnerPaths.spellings` keeps
  Xrash's rootless / roothide / `/private` spelling rules.

### No image list

Nothing here reads another process's image list. On the iOS 27.0.1 vphone
(roothide, 2026-10-17), reading SpringBoard's image list from
apelin-diagnostics panicked the kernel ("VM entry … lock is invalid",
`vm_entry_lock.c:168`, panicked task apelin-diagnostics): twice while
Inspector's dyld `all_image_infos` read through `task_read_for_pid` and
`mach_vm_read_overwrite` was still in place, then once more through the
kernel's region paths (`proc_pidinfo PROC_PIDREGIONPATHINFO`) alone. Both
readers, ported from Inspector, are removed, and apelin-diagnostics no
longer carries `com.apple.system-task-ports.read`. A `confirmLoaded` that
still sends `imageCheck` is refused with `badRequest` before a task exists.

### ConfirmLoaded

`ConfirmLoaded(logs:).run(request, trigger:, stage:)` starts the marker
read, runs the trigger (a respring) half a second later, waits for the
window, then evaluates the filter plist. `marker` and `filter` each come
back as `confirmed`, `absent` or `unavailable` (no source, no plist —
never reported as absent); `image` is always `notRead`. `stage` reports
`listening` and `trigger` as it goes. The filter follows
MobileLoader's reading: `Bundles`, `Executables`, `Classes`, `Mode = Any`,
`CoreFoundationVersion` as `[min, max)`; a framework bundle id or a class
is `undetermined` statically.

In apelin-diagnostics, `confirmLoaded` is a task the session host owns: the
worker checks the request (a bad one is the reply), accepts, runs the check
on its own thread, emits each `stage`, asks the host for the respring when
the request says `trigger: respring`, and ends the task with `state`
`succeeded` carrying the `ConfirmLoadedResponse` as `result`. The respring
takes the app down, not the host or this worker, so the answer is kept with
the task whether or not anyone is attached.

The marker is heard only while listening: the live log has no history here
(see below), and a tweak logs its marker once, from its constructor, when
the target starts. A SpringBoard tweak therefore needs `trigger: respring`;
an app target needs relaunching during the window. Without either, the
marker reads `absent` unless the target happens to start inside it.

## Privilege matrix

What each capability needs, read from icli 0.9.0's source and
[`docs/entitlements.md`](https://github.com/owngoal-dev/icli/blob/0.9.0/docs/entitlements.md),
and checked again against
[1.0.0's](https://github.com/owngoal-dev/icli/blob/1.0.0/docs/entitlements.md):
the keys 0.9.1 through 1.0.0 added (`com.apple.private.xpc.service-attach`,
`IOHIDResourceDeviceUserClient`, `com.apple.keystore.device`) belong to
calls Apelin does not make — kickstart, the virtual pointer and the keybag
unlock — so no row changed.
icli has verified its complete profile together, never one key at a time;
its acceptance runs are the signed CLI on the rootless vphone.
**No row has been run from an Apelin process on a device.** "Verified"
below means verified by icli's own acceptance or by this package's Mac tests,
as stated.

| Capability | Call | uid | Entitlements | Status |
| --- | --- | --- | --- | --- |
| Live log | `SyslogStream`, `captureSyslog` → `OSLogEventLiveStream` | mobile | `com.apple.private.logging.stream`, `com.apple.diagnosticd.stream`, `com.apple.private.logging.diagnostic` | Unverified in Apelin. icli acceptance `unified_log_events` passes with the full profile |
| Crash list / read | `crashLogs`, `readCrashLog` (plain file reads) | mobile | `com.apple.private.security.no-sandbox`; `com.apple.private.security.storage.DiagnosticReports.read-write` is in icli's profile | Unverified in Apelin; icli acceptance `crash_report_roundtrip` passes. Root-only reports go through the host's report-id fd |
| Screenshot | `takeScreenshot` | mobile | `com.apple.QuartzCore.global-capture`, `.displayable-context`, `.secure-mode`, `com.apple.private.allow-explicit-graphics-priority`, `com.apple.private.IOSurface.protected-access`, `com.apple.security.iokit-user-client-class` with `IOSurfaceRootUserClient`, `IOSurfaceAcceleratorClient`, `IOMobileFramebufferUserClient`, `AppleJPEGDriverUserClient` | Unverified in Apelin; icli acceptance `screenshot_coordinates` passes |
| UI tree | `uiElements` | mobile | `com.apple.private.accessibility.inspection`, `com.apple.accessibility.api`; frontmost pid needs `no-sandbox` | Unverified in Apelin; icli acceptance `ax_tree_and_tap` passes. Turns the system accessibility switches on; icli turns them back when the worker exits |
| Tap / swipe / type | `tap`, `swipe`, `typeText` | mobile | `com.apple.private.hid.client.event-dispatch`, `com.apple.hid.manager.user-access-device`, `com.apple.backboard.client`, iokit classes `IOHIDLibUserClient`, `IOHIDEventServiceFastPathUserClient` | Unverified in Apelin; icli acceptance `touch_tap`, `touch_swipe`, `unicode_input` pass |
| Tap element | `tapElement` | mobile | UI tree's plus tap's | Unverified in Apelin |
| Foreground app | `frontmostApp` | mobile or root | `com.apple.private.security.no-sandbox` | Verified by icli on the iOS 26.4 roothide vphone (mobile and root); without it `source` is `unavailable` |
| Lock state | `lockState` | any | none | Verified by icli on iOS 26.4 |
| Running apps | `runningApps` | mobile | `no-sandbox` (RunningBoard); `com.apple.private.coreservices.canmaplsdatabase`, `.lsaw` for app metadata | Unverified separately |
| Respring fallback | `respring` | root for the launchd half | FrontBoard relaunch: `com.apple.frontboard.shutdown` (with the `launchapplications` keys); launchd stop: `com.apple.private.xpc.service-configure`, and launchd's own caller checks | Unverified in Apelin; icli acceptance `springboard_restart` passes. The normal respring is apelind's closed operation |
| Root log read | `SystemLogReader` | root | diagnosticd may still want `com.apple.private.logging.stream` / `com.apple.diagnosticd.stream` from root | Unverified on iOS. On macOS 27 an unentitled user process receives its own lines (test passes) |
| Filter match, symbolication, blame | pure | any | none — reads the project's own dSYMs | Verified by tests |

`OSLogStore` is not an option on iOS: its only scope there is
`.currentProcessIdentifier` (`.local()` and `.system` are macOS-only). Both
readers therefore use the live stream, which sees only what is logged while
it listens; `ConfirmLoaded.run` starts listening before it triggers.

A `logStream` has no seam. Both readers are a `LiveLogSource` and keep one
stream open for the window: the root reader LoggingSupport's live stream,
`Diagnostics` one icli `SyslogStream`, which hands entries over one at a
time in arrival order and delivers none once `cancel()` has returned.

What goes to icli and what stays here: subsystem (with its dotted
children), message substring (case-sensitive) and minimum level mean the
same in icli's `SyslogFilter` as in `LogFilter`, so icli applies them
before it counts or delivers anything. Process does not —
icli keeps a case-insensitive substring, `LogFilter` the whole name — so
icli gets it only as a narrowing; `since` has no icli field. Every entry
icli hands over still passes `LogFilter.matches`, and the limit is counted
here, after it, so icli's own `maxEntries` is not used.

icli's stream does not throw when the system refuses this process; it ends
`interrupted`. Ended that way within the first second with nothing heard,
the stream is a refusal: `listen` throws `unavailable`, the worker answers
`denied`, and the host starts the root reader. Ended that way later, it
lost the rest of its window, and ends `truncated` with `reason: source`
rather than claim it is complete.

## icli

Depends on `from: "1.0.0"`; `Package.resolved` records 1.0.0. 0.9.1 through 1.0.0 added calls Apelin does not
make (`kickstartService`, the `pointer` calls, the probe, `unlockDevice`,
`withInterfaceGeometry`) and left the ones it makes as they were on iOS.
Gaps found and filled in icli 0.9.0:

- `captureSyslog` filtered only by process substring and level, so a busy
  device filled `max-lines` with other subsystems before a marker arrived.
  0.9.0 takes subsystem (and dotted children), category, pid, message and
  every level before the cap; `Diagnostics` still asks for the full 5000
  lines when process or `since`, which only it checks, is set.
- There was no open-ended stream, so `logStream` stitched overlapping
  bounded reads together. 0.9.0's `SyslogStream` is one listen.
- `readCrashLog` returned the whole file. 0.9.0 takes `maxBytes`.

Not filled, for later: a loaded-images call that is safe on iOS 27, and a
subsystem-aware historical log read. No public iOS API gives the history:
`OSLogStore` is current-process only and there is no `log` tool on iOS.
LoggingSupport's archive reader is private, wants logging-admin
entitlements and is untried, so it is not used; until something gives the
history, `confirmLoaded` needs its trigger.

## Licences

Linking `ApelinDiagnostics` brings icli (MIT), `Lakr233/libarchive.xcframework`
(statically linked into IcliKit) and, as a pin only, `swift-argument-parser`
(icli's CLI target) into the app's `Package.resolved`. Their notices go into
`Licenses/` and `review.json` in the commit that links the product, per
`Licenses/README.md`. The ported Xrash code is OwnGoal's own MIT.
