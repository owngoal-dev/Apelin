# Console

Apelin runs headless from a script: the permitted operations on the wire, in order,
through `ApelinService` — the same typed surface the UI and the agent's tools
call. `agentAPIConfiguration` is restricted to the provider editing form: the
console refuses it before sending so a saved API key never enters its output or logs.
It refuses `feedbackStar` too: a star on the reader's GitHub account comes only
from their tap in the app.
The console is the app itself, not a second peer of apelind, so "No
CLI" holds. It never draws anything and never quits the app.

The runner is `ApelinConsole` (`Packages/ApelinKit/Sources/ApelinConsole`),
parameterised on an `ApelinService`, a `DataFolder` and a log sink, and
tested on the Mac by `make harness` (`Packages/ApelinKit/Tests/ApelinConsoleTests`) against a
fake transport. The app keeps only the binding — `ApelinService.app`,
`DataFolder.app`, the unified log — and the launch and foreground hooks
(`Apelin/Console/ConsoleLaunch.swift`).

## Start a Run

- **Launch argument**: `-apelin-console <path>`. An absolute path is read in
  place; a relative one is under `~/Documents/wiki.qaq.apelin/console/`.
  The file is left where it is.
- **Inbox**: drop `*.json` into `~/Documents/wiki.qaq.apelin/console/inbox/`.
  The app checks the inbox at launch and every time it comes to the
  foreground, runs the scripts one at a time in name order, claims each into
  `console/running/<runID>-<name>` while it runs and moves it to
  `console/done/<runID>-<name>` after. Names starting with `.` are skipped,
  so write `.x.json` and rename it to drop a script in atomically.
- **After the app went away**: at the next launch an inbox script still in
  `running/` is picked up again, into the same `out/<runID>.jsonl` (a
  `run.resumed` line marks it), with the earlier steps' results read back
  from that file so `${…}` and `expect` still work, in two cases:
  - **mid-follow** — the output stops while a step was following its task
    (its `step.task` line is written, its `step.result` is not): a task
    outlives the app, so the console attaches to the same task again after
    the last event it wrote (`afterSeq` = that event's `seq`), writes the
    rest as `step.event` lines, finishes the step and goes on with the
    script. This is what carries a step whose task resprings, or a run
    whose app was killed from the app switcher;
  - **after a respring** — the output ends right after a `respring` step
    that succeeded (SpringBoard takes the app down with it): the run goes on
    at the step after it. Open the app again after the respring. `respring`
    answers before SpringBoard goes, so after one that succeeded the run
    waits up to 15 s for the app to go before it starts the next step; an
    app still running then writes a `step.note` (`respringSurvived`) and
    goes on. A failed respring, allowed or not, does not wait. This is
    tried once: a run whose next step had started, or that an earlier launch
    already resumed from that respring, is interrupted, so a step, a panic
    or a reboot that keeps taking the app down is never run in a loop.

  A script left in `running/` for any other reason gets `run.interrupted`
  and a failed `run.end`, and moves to `done/`. A script run from the
  launch argument is never in `running/`, so it is never resumed.
- **A load check that resprings**: `confirmLoaded` answers a task handle
  (kind `confirmLoaded`) and the step follows it. With `trigger: respring`
  the task listens for the marker, then resprings, which takes the app
  down mid-follow; the task carries on in the session host and keeps its
  answer, `result` in its final `state` event, whether or not anyone is
  attached. Its first event (`stage` `listening`) is written before the
  respring, so the `taskID` is in the step's `step.event` line; read the
  answer afterwards with `{"op": "confirmLoadedAttach", "request":
  {"taskID": "…"}}` if the run did not pick it up again itself.

`~/Documents` is mobile's: `<jbroot>/var/mobile/Documents` on roothide,
`/var/mobile/Documents` on rootless.

## From the Mac

`Scripts/device.py` does all of the above over ssh and follows the run as
it writes, so a device run is one command:

```sh
make vphone                      # build, package and install on the vphone
make device-test                 # the smoke suite (SUITE=regression for all)
Scripts/device.py run i1-smoke   # scripts by name, or a path to any script
Scripts/device.py call sdkList '{"includeSources": true}'
```

**The target**: `--machine <name>` or `VPHONE` names a vphone as
vphone-launchpad does, and its address is read from the guest;
`--host`/`VPHONE_HOST` gives an address on port 22; `DEVICE_HOST` (with
`DEVICE_PORT`, 2333) a phone behind `iproxy`. With none of them, the one
vphone that is running. `DEVICE_USER` (mobile) and `DEVICE_PASSWORD`
(alpine; empty for ssh keys) log in. Every call shares one ssh connection,
so a poll costs milliseconds.

**A run**: the script is dropped into the inbox under a name of its own
(`dh<time>-<script>.json`, so its `runID` is found in `running/` or
`done/`), and the app is quit, if idle, and launched again: a launch reads
the inbox. Going through another app to bring Apelin to the foreground
does not work on an iPad, where iPadOS 26 leaves that app beside it with the
focus. While the run writes, each `step.result` is printed (`✓`, `✗`, `~`
for an allowed error), and `stage`, `resumed` and `approvalRequested`
events. When the app goes away without a `run.end` — a respring, a kill —
it is opened again, up to four times, and the run resumes as above. When the
output stalls and the app is not in front (vphones only), it is brought
back, and the result says so: a suspended app's follow never ends. The
lines are kept in `build/Device/<target>/<runID>-<script>.jsonl`.

**What each script needs and gets** is
`Documents/Console/device-harness.json`, one entry per script in
`scripts/` (`make check` runs `device.py lint`):

| key | meaning |
|---|---|
| `needs` | skip the script unless the device has these: `package:<id>` (optionally `>=`, `<=`, `>>`, `<<`, `=` a version; `Provides` count), `!package:<id>`, `toolchain` / `!toolchain` (registered), `installed-toolchain` (one installed through irisind, with an installation to remove; a toolchain registered by hand has none), `sdk` (registered), `sdk-source` (an SDK registered or `inbox/iPhoneOS.sdk`), `project:<name>` |
| `before` | setup actions, in order: `{"root": sh}`, `{"mobile": sh}` (`$DATA` is the data folder and `$JB` the install root, both as the ssh shell sees them), `{"push": <repository path>, "to": <path in the data folder>}`, `{"removeProject": <name>}`, `{"stageSDK": <inbox name>}` (a copy of a registered SDK when the inbox has none, removed after the run; an SDK already in the inbox is left alone) |
| `during` | `{"when": {"start" \| "result" \| "task": <step label>}, "delay": s, "do": "killSessionHost" \| "killApp"}`, run on the device by a watcher started before the drop, so it fires within 50 ms of the line |
| `verify` | actions that must succeed after a passing run |
| `after` | cleanup actions, whatever the result (`--keep` skips them) |
| `expectOutput` | checks on the output the console cannot make: `{"step": <label>, "event": <kind>}` (that step saw such an event; for a resume test, `resumed`) or `{"line": <type>, "min": n}` |
| `timeout` | seconds before the harness gives up (default 900) |
| `manual` | why it cannot run unattended; it runs only when named |

`suites` groups them; `regression` holds every script that is not manual,
in an order where each leaves what the next needs. `device.py list --check`
shows which ones the device can run now.

Before a run the harness refuses a folder in `SDKs/` with no record:
apelin-environment deletes every unregistered folder there when it starts
(`SDKStore.sweepOrphans`), so an SDK copied in by hand is lost at the next
`sdkList`. Move it to `inbox/iPhoneOS.sdk` and import it.

The rest of `device.py`: `status` (packages, the installed build against
this checkout, apelind and its session host, toolchains, SDKs, projects,
the console folders), `install` (the built packages for the device's
architecture; a deb whose `Depends` the device lacks is skipped and named),
`out` (the device's latest runs, or one), `open`, `kill-host`, `exec`,
`shell`, `crashes [--pull]`, and on a vphone `screenshot` and `logs`.

## Output

Each run writes JSON lines to `console/out/<runID>.jsonl` and logs every line
to the unified log (subsystem `wiki.qaq.apelin`, category `console`). Every
line has `type`, `runID` and `time`:

| type | fields |
|---|---|
| `run.start` | `script` |
| `run.name` | `name` (when the script has one) |
| `run.invalid` | `error` — the script did not read or decode |
| `step.start` | `index`, `op`, `label` |
| `step.task` | `index`, `taskID`, `kind`, `response` — the step answered a task handle and is about to follow it; written before its first event |
| `step.event` | `index`, `taskID`, `event` {`seq`, `kind`, `time`, `payload`} |
| `step.result` | `index`, `op`, `label`, `ok`, `durationMs`, `response` or `error` {`code`, `message`}, `state` |
| `step.note` | `index`, `note`, `message` — `respringSurvived`: the app was still running 15 s after the respring step `index` succeeded, and the run goes on |
| `run.resumed` | `fromStep`; and `taskID`, `afterSeq` when the run re-attaches to the task step `fromStep` was following — the run continues after the app went away |
| `run.interrupted` | `lastStep` — the app went away mid-run |
| `run.end` | `ok`, `failedStep` |

A run is finished when its `run.end` line is written. `runID` is
`yyyyMMdd-HHmmss-xxxxxx` (UTC).

## Script

A script is an array of steps, or `{"name": "…", "steps": [ … ]}`.

```json
{
  "name": "m1-chain",
  "steps": [
    {"op": "hello"},
    {"op": "toolchainSetup", "request": {"source": {"appleCatalog": {}}, "components": ["c"]}, "label": "toolchain"},
    {"op": "expect", "request": {"step": "toolchain", "state": "succeeded"}},
    {"op": "projectCreate", "request": {"templateID": "wiki.qaq.apelin.dev.tweak/objc", "name": "Hello", "values": {}}, "label": "project"},
    {"op": "projectCheck", "request": {"projectID": "${project.response.projectID}"}, "label": "check"},
    {"op": "expect", "request": {"step": "check", "path": "response.passed", "equals": true}},
    {"op": "buildStart", "request": {"projectID": "${project.response.projectID}", "configuration": "debug"}, "label": "build"},
    {"op": "installPackage", "request": {"artifactID": "${build.lastEvent.payload.artifactID}", "digest": "${build.lastEvent.payload.digest}"}},
    {"op": "confirmLoaded", "label": "loaded", "request": {"buildID": "${build.lastEvent.payload.buildID}", "targetID": "com.apple.springboard", "projectID": "${project.response.projectID}", "trigger": "respring"}},
    {"op": "expect", "request": {"step": "loaded", "path": "lastEvent.payload.result.loaded", "equals": true}}
  ]
}
```

### Steps

| field | meaning |
|---|---|
| `op` | an operation name from `AppOperation` (`Packages/ApelinKit/Sources/ApelinProtocol/AppOperation.swift`), or `wait`, or `expect` |
| `request` | the operation's request as JSON — the Codable form of its `…Request` type in `Operations/<Domain>.swift`. Defaults to `{}` |
| `label` | a name later steps refer to |
| `follow` | for a step that answers a task handle (`{"taskID", "kind"}`): read its events (`step.event` lines) until it finishes; defaults to true. A response that carries a handle as `task` (an agent session, a terminal) is followed only with `"follow": true`, since those run until closed. An attach (`buildAttach`, `environmentAttach`, `agentAttach`, `ptyAttach`, `logStream`) answers a batch: its events are the step's first, and a task not yet finished is read on from the batch's `lastSeq` with the same attach until it ends — so a script can pick up by ID a task an earlier run or host started; `"follow": false` keeps just the one batch (for a terminal or agent session still open). A followed task is announced by a `step.task` line, which lets a later launch re-attach to it. A followed task that ends in any state but `succeeded` fails the step, and so does a finished batch in such a state |
| `timeoutSeconds` | how long a followed task is read; defaults to 1800, and starts again when a resumed run re-attaches |
| `allowError` | keep going when this step fails; by default the first failure ends the run |

A step fails when the operation answers an error, when a followed task ends
in any state but `succeeded`, or when an `expect` does not hold.

Enums with associated values are encoded the way Swift's `Codable` does:
`{"appleCatalog": {"productID": "…"}}`, `{"repository": {"url": "…", "branch": "…"}}`,
`{"tap": {"x": 10, "y": 20}}`; an unlabelled value is `_0`:
`{"url": {"_0": "https://…"}}`. Descriptor-carrying operations (`fileRead`,
`crashOpen`, `captureScreen`, `ptyAttach`, `protectedEdit*`, `toolHostCall`
with attachments) run, but the console does not keep or pass descriptors (a
tool's returned file is seen by its `byteCount` and `sha256`):
`protectedEditCommit` takes the new contents as `contentsBase64` instead, and `ptyOpen` types `initialInput` into
the terminal (its output comes back as `output` events). Scripts that exercise
a worker's domain live in `Documents/Console/scripts/`, with what they install
in `Documents/Console/fixtures/`.

### References

A string `"${label.path}"` is replaced, before the step runs, by the value at
`path` in that step's result; a string that is nothing but one reference
becomes the value itself (a number stays a number), a reference inside a
longer string is spliced in as text. A step's result is:

```json
{"ok": true, "response": { … }, "error": {"code": "…", "message": "…"},
 "events": [ … ], "lastEvent": { … }, "state": "succeeded"}
```

Paths are dotted; array elements are addressed by index (`events.0.kind`).

### Scripts in the Repository

`Documents/Console/scripts/` holds scripts to copy into the inbox, listed
under "Scripts kept here" below. `make harness` decodes every one, checks
each `op` and each `${label…}` reference, decodes every request that has no
reference as its operation's request type, and fails when some operation in
`AppOperation` is called by none of them.

`r1-resume-build.json`, `r1-resume-sdk-import.json` and
`r2-resume-toolchain.json` check that a build, an SDK import and a toolchain
setup survive the session host being killed. Each starts its task without
following it, waits (20 s, 15 s for the toolchain), then attaches and follows
the resumed task to its end, expecting `succeeded` (a task the kill ended
`interrupted` never gets there); the setup also expects the first batch to
be still `running`. The import does not: on the iOS 27 iPad vphone a resumed
import of a registered SDK took 4 s and had ended by the attach. A
template's build takes about a second, so it has ended by the attach: kill
the host the moment `buildStart` answers, from a loop on the device that
watches the run's output, and check its events for `resumed`. On the iOS
26.4 vphone the toolchain setup took 25–35 s (Apple's download, the
retarget, the install through irisind, the self-test) and the import of a
300 MB SDK from the inbox about 25 s; a kill 5 s after `toolchainSetup`
answered lands in the download, and one within 0.2 s of `buildStart`
answering lands in the compile. A resumed task starts over (the download
from its first byte, the build from `check`) under the same task ID.
`Scripts/device.py run r1-resume-build` (and the other two) does all of
this, the kill from a watcher on the device included, and fails a run with
no `resumed` event. By hand, on the device:

1. For the build, delete `Projects/R1 Resume Tweak` if a previous run left
   it; for the import, put an `iPhoneOS.sdk` folder in
   `~/Documents/wiki.qaq.apelin/inbox/`; for the toolchain, remove the
   registered one first (`t2-toolchain-remove.json`, after deleting the
   projects bound to it), so its install through irisind happens in this
   run.
2. Copy the script into `~/Documents/wiki.qaq.apelin/console/inbox/` and
   open the app.
3. When `console/out/<runID>.jsonl` shows the `buildStart` (or `sdkImport`,
   `toolchainSetup`) step, and within the wait, kill the session host as
   root: `kill -9 $(cat <install root>/var/lib/apelin/session.pid)`. Its
   process name is apelind's — the kernel takes it from the executable,
   and `apelind-session` is only its `argv[0]` — so `killall` cannot pick it
   out: `killall apelind-session` finds nothing and `killall apelind` kills
   the proxy too. Leave apelind itself alone: it starts the session host
   again, which writes its own pid to the file.
4. Keep the app open until the run ends. It passes when both `expect` steps
   after the attach hold. The attach step's events hold a
   `resumed` event, and the `seq` numbers run on with no gap; if there is
   no `resumed` event, the kill came too late.
5. The retry bound, on another run: kill the session host three times
   while the task runs, waiting each time for `session.pid` to name a new
   one. After the third
   the task ends `interrupted`, with the message "the session host stopped
   3 times while this ran; it is not resumed again", after two `resumed`
   events (`resumes` 1 and 2). The script fails at the attach step itself
   (`taskEnded`, "the task ended interrupted"). The setup's job record and
   staging stay behind until the next `toolchainSetup` of the same source,
   which clears them and runs from the start; run `t1` afterwards so one
   toolchain is registered again.

A log stream's first call opens it and answers a batch. Followed (the
default), that step reads the whole stream to its end — the window or the
limit. To keep the opening batch alone, open it with `follow: false` and
read the rest with a second `logStream` carrying `stream`, which is
followed to the end:

```json
{"op": "logStream", "label": "logs", "request": {"filter": {"windowSeconds": 5}, "afterSeq": 0, "waitMilliseconds": 1000}, "follow": false},
{"op": "logStream", "request": {"stream": "${logs.response.taskID}", "afterSeq": 0, "waitMilliseconds": 5000}}
```

An agent session's task runs until it is closed; `agentOpen` with
`"closeWhenFinished": true` and a `prompt` ends it with the first run, so
`"follow": true` reads it to the end.

### Credentials

The agent signs in from the keychain. To provision a provider with no UI,
put `<store id>.json` (kwwk's credential shape: `access`, `refresh`,
`expires`, optional `extras`) or a kwwk `auth.json` map in
`~/Documents/wiki.qaq.apelin/console/inbox/credentials/`, then run
`{"op": "agentCredentialImport"}` — or just open a session, which imports
first. Store ids are kwwk's, one per provider Settings signs in to:
`github-copilot`, `anthropic`, `anthropic-api-key`, `openai-compatible`,
`openai-codex`, `cursor`, `devin`, `kiro`, `qoder`, `qoder-cn`, `workbuddy`,
`workbuddy-ai`, `kimi-coding`, `xai`, `zai`, `zai-coding-cn`, `openrouter`,
`openai-api-key` and `google-api-key`. Each file is read once and deleted, usable or not; the
response lists the store ids stored and the files refused with a reason,
never what they held. The console only scans `inbox/*.json`, so a file in
`inbox/credentials/` is never run as a script.

Settings ▸ Model Providers signs in with no file: `agentSignIn {"provider":
…}` starts a `signIn` task (read with `agentAttach`) whose first event says
what the user must do — `deviceCode`, `authorize` or `input` — and
`agentSignInRespond {"taskID", "values": {…}}` hands back a typed key or a
pasted redirect address. `agentAccountList` names each provider's
`method` and any `alternativeMethods`; `{"provider": "openRouter",
"method": "apiKey"}` asks for OpenRouter's key form instead of its browser
sign-in. A script that responds writes those values into the run's output
like any request, so only a placeholder ever goes in one. A step that does
not follow its task (`"follow": false`) reads the attach batch's state with
`{"step": …, "path": "response.state", "equals": …}`; an expect's `state`
is for a followed task. To see a sign-in end, attach after the last event
seen (`"afterSeq": "${step.response.lastSeq}"`), which waits for the
closing `state`.

### `wait`

`{"op": "wait", "request": {"seconds": 5}}`.

### `expect`

Every field given must hold of the step named by `step` (the previous step
when absent):

| field | holds when |
|---|---|
| `ok` | the step's `ok` is this |
| `errorCode` | the step failed with this code (`unimplemented`, `denied`, `backendUnavailable`, …) |
| `state` | a followed task ended in this state |
| `path` + `equals` | the value at `path` equals this JSON |
| `path` + `exists` | there is (or is not) a value at `path` |

While the operations are being written, `{"op": "expect", "request": {"errorCode": "unimplemented"}}`
after an `"allowError": true` step proves the whole path — app, apelind,
session host and worker — answers.

## Error Codes

`unimplemented`, `badRequest`, `unknownOperation`, `unsupportedVersion`,
`denied`, `notFound`, `conflict`, `cancelled`, `timeout`,
`backendUnavailable` (no privileged backend: the app is on its own),
`unavailable` (the session host or a worker could not be reached or
started), `internal`; and from the console itself `expectationFailed`,
`taskEnded`, `timeout`, `console`.

## Scripts Kept Here

`Documents/Console/scripts/`, one per domain; together they call every
operation. Each script's `name` says what must exist first. A step that
needs state a script cannot make is `allowError` with an `expect` on the
error, or on `ok: false` where the exact refusal is the worker's to choose.

### One per Domain

- `hello.json` — needs nothing. `hello`, `extensionList`, `sdkList`,
  `toolchainStatus`: apelind starts on demand and the workers come up.
- `environment.json` — needs the network and a registered SDK (the
  setup refuses to start without one). `toolchainStatus`, a
  `toolchainSetup` started unfollowed, `environmentAttach` (replay),
  `environmentCancel` and the task read back `cancelled`; `toolchainRemove`
  and `sdkRemove` of ids that do not exist are refused; `sdkList` with its
  sources.
- `project-build-install.json` — needs the tweak extension, a registered
  toolchain and SDK, Irisin, and no `Projects/Console Build Check`.
  `extensionList`, `projectCreate`, `projectCheck`, `approvalDigestState`
  (build and packaging match the template, a made-up digest is `changed`),
  a `buildStart` cancelled with `buildCancel` and read back with
  `buildAttach`, a followed build, `installPackage`, the install task
  replayed with `buildAttach`, `installationList` naming that installation,
  `removePackage`, and `installationList` again without it. Delete the
  project after.
- `files.json` — makes the `Hello` tweak project if it is missing, which
  takes the tweak extension and a registered toolchain and SDK.
  `fileRead` of `apelin-project.json` by descriptor; a path out of the
  project, `protectedEditOpen` of dpkg's status file and
  `protectedEditCommit` with a grant never given are refused.
- `terminal.json` — `ptyOpen` unfollowed, `ptyResize`, `ptyAttach` (the
  `started` event as uid 501), `ptyClose`, the task read back finished, and
  a resize of the closed terminal refused.
- `logs.json` — a 5 s `logStream` read in two calls and ended
  `succeeded`, `crashList`, and
  `crashOpen` and `crashSymbolicate` of the newest report (allowed to fail
  on a device with none); an unknown report is refused.
- `diagnostics.json` — a `uiAction` wake, which presses nothing on a
  device already awake and leaves `screenOff` false, `captureScreen`,
  `readUITree`, one `uiAction` tap in
  the status bar at (200, 4) — not its corner, where iPadOS 26 puts a
  window's close control —, and a `confirmLoaded` for a build that does not
  exist (allowed to fail).
- `agent.json` — needs the tweak extension; a Copilot credential in
  `inbox/credentials/` for the prompt to be answered.
  `agentCredentialImport`, `agentList`, a Confirm `agentOpen` unfollowed,
  `agentAttach`, `agentPrompt`, `agentSteer`, `agentAbort`, `agentCompact`
  (allowed to fail: a run still ending refuses it), `agentClose`;
  `agentApprove` of an unknown approval is refused and `agentRunCode` from
  the app is `denied` (it is the session worker's alone).
- `accounts.json` — needs the network (github.com, cursor's poll).
  `agentAccountList` in kwwk's order; a GitHub Copilot `agentSignIn` read to
  its `deviceCode`, a typed value refused, cancelled; OpenRouter's browser
  sign-in read to its `authorize` with a paste offered, an address with no
  code refused, cancelled; Cursor's polled sign-in read to its `authorize`
  with no paste, a pasted address refused `conflict`, cancelled; OpenRouter
  by `deviceCode` refused, its key form read to its fields, cancelled; an
  Anthropic API-key `agentSignIn` read to its `input`, an empty key
  refused, cancelled, and a late answer refused. Each cancel is read to its
  `cancelled` state. Signs nothing in or out.
- `a2-api-key-sign-in.json` — by name only: replaces the device's
  `openai-compatible` sign-in with a placeholder key through `agentSignIn`
  and `agentSignInRespond`, lists it under its host, `agentSignOut`, lists
  it gone.
- `transfer.json` — needs a registered SDK. `transferExport` of it read to
  its end (the export's `result` is also in the final `state`),
  `transferInspect` of the file in `Exports/` (an SDK already here: not
  importable, `existingID`), `transferImport` of it refused (`conflict`)
  and of it as a toolchain refused (`badRequest`), a path outside
  `Exports/` refused, exports of a toolchain and a project that do not
  exist `notFound`. Leaves `Exports/` for the harness to delete.
- `transfer-project.json` — needs `Projects/I3 Chain Tweak`. Exports it,
  inspects the file (`suggestedName` `I3 Chain Tweak 2`), is refused an
  import under the taken name, imports it as `Transfer Copy` under a new
  project ID, and `projectCheck`s that. The harness removes `Transfer Copy`
  and `Exports/`.
- `transfer-toolchain.json` — by name only: exports the first toolchain as
  an `.apetc` (a GB or more, minutes; RootHide's runtime brand undone),
  inspects it (already set up here) and is refused an import of it.
- `distribution.json` — nothing written to GitHub: `distributionRepositoryList`
  without GitHub, a bad repository name, a bad `owner/name` and a package
  outside `Builds/` each refused `badRequest` before a task starts, an
  empty feedback title, a `feedbackRead` of issue 0 and a `feedbackEdit`
  to an empty title each refused before anything reaches GitHub,
  `feedbackStarState` (a read: `denied` without a GitHub sign-in),
  `distributionRepositoryUnlink`, then the list with no link. The harness
  keeps `Settings/distribution.json` and puts it back.
- `tool-host.json` — needs the disassembler agent tool extension.
  `toolHostOpen`, `toolHostCall` of `symbols` on dyld, an undeclared tool
  refused, `toolHostClose`, a second close `notFound`, a missing extension
  refused.
- `resume.json` — a 20 s terminal followed to its end: kill the app from the
  app switcher during it and open it again, and the run re-attaches
  (mid-follow resume); then `respring` — open the app again and the run
  finishes (respring resume).

### Device Runs

- `i1-smoke.json` — the session host on a device: `ptyOpen` as 501, the
  protected edit end to end with its refusals, install and removal of the
  fixture deb through irisind. Its `setup` lists what to do as root first.
- `i2-sdk-import.json` — push an SDK folder to
  `~/Documents/wiki.qaq.apelin/inbox/iPhoneOS.sdk` first. Imports it
  (`{"inbox": {"path": …}}`), lists it, and checks that an inbox path
  climbing out and a plain-HTTP URL are refused.
- `i2-git.json` — needs github.com. Clones one branch of
  `libgit2/TestGitRepository` into `Projects/I2GitCheck/` (`gitClone`), then
  status, diff, stage, unstage; an empty commit, `gitInit` of a project that
  has a repository, a path out of the project and a second clone into the
  same name are refused.
- `i2-git-commit.json` — after `i2-git.json`, with a file `i2-note.txt`
  written into `Projects/I2GitCheck/` (the console writes no files): status,
  stage, staged diff, commit, clean tree.
- `i3-chain.json` — the milestone 1 chain: create the `I3 Chain Tweak`
  project, check, build, install through irisind (`installationList` of
  the project names the installation), then `confirmLoaded` in
  SpringBoard with `trigger: respring` (marker evidence; the image list is
  not read): expects the marker (`evidence.0`) confirmed and the image
  (`evidence.1`) `notRead`; then removes the package it installed.
- `i3-image-check-refused.json` — `confirmLoaded` with `imageCheck:
  regionPaths` is refused with `badRequest` and starts no task. Reading
  SpringBoard's image list panicked the iOS 27.0.1 vphone kernel on
  2026-10-17, the last time through the region-path walk alone
  (`Documents/Research/Device-Validation.md`), so no reader is
  left to ask for.
- `i4-agent.json` — imports credentials, makes the `Hello` tweak project if
  it is missing, opens a Relaxed Copilot session on it with
  `claude-sonnet-5.5` and a first prompt, and follows the session task until
  the run ends.
- `i5-log-continuity.json` — a 60 s `logStream` over the console's own
  unified-log lines while 100 labelled `hello` steps run; exactly 200 `log`
  events (each tick's `step.start` and `step.result`) prove no line was
  lost or repeated across the reader's chunk boundaries.
- `i6-tool-attachments.json` — needs the disassembler extension 1.1.0.
  Opens it, calls `symbols` inline and with `output: file`, and checks the
  returned attachment's metadata (text/plain, `dyld.symbols.txt`, the same
  `sha256` twice); then closes it.
- `r1-resume-build.json`, `r1-resume-sdk-import.json` — a build and an SDK
  import across a killed session host; the steps are under "Scripts in the
  repository" above.
- `t1-toolchain-setup.json` — the real `toolchainSetup` end to end: Apple's
  catalog, download (about 350 MB from Apple's software update servers),
  unpack, retarget, sign, the local deb, `installPackage` through irisind,
  the self-test as mobile on the installed tree, the registry. It needs a
  registered SDK (`i2-sdk-import.json`), Irisin 4.7.3 or later, and an empty
  toolchain registry, which it checks first. Expects the setup to succeed
  and the registered toolchain to carry an `installationID`, a passing C
  self-check and six passing self-test cases (C, C++, ObjC × arm64, arm64e).
  Its task can be cancelled with `environmentCancel`; a failed or cancelled
  run removes what it installed, and running it again picks up the
  download.
- `t2-toolchain-remove.json` — after `t1`: removes the registered toolchain
  with `toolchainRemove` (through `removePackage`), checks the registry is
  empty and that the same installation cannot be removed twice. A project
  bound to the toolchain blocks it; delete that project first.
- `t3-toolchain-side-by-side.json` — with 27.0 registered and an iPhoneOS
  18.5 SDK as `inbox/iPhoneOS18.5.sdk` (run by name: no registered SDK can
  stand in for it): imports that SDK, expects CLT 12.4 (`001-89745`) to fail
  with its refusal, sets up CLT 16.4 (`082-41241`, about 716 MB) beside 27.0
  with six passing cases and `newestSDK` 18.5 while the default stays 27.0,
  then removes 16.4 and expects 27.0 still registered and the default.
- `t6-toolchain-beside.json` — with one toolchain registered: the catalog
  offers 27.2 first, 27.0 second and 14.2 sixth, then a whole setup of CLT 14.2
  (`012-92431`, about 508 MB) beside it, its SDK fetched when none fits, and
  its removal; the default stays. `t1` skips any device that has a toolchain,
  so this is what runs a setup on a vphone that has one.
- `t4-toolchain-swift.json` — with one toolchain registered and an iOS 27
  SDK: sets CLT 27.2 up with Swift (`components: ["c", "swift"]`) beside it
  and expects both components to pass, the Swift cases among the self-tests
  (Swift, Swift dylib, Swift async, Swift macro), then creates the
  `uikit-swift` app against it, checks, builds debug and release, installs
  and removes it. Run by name; remove the Swift toolchain afterwards.
- `r2-resume-toolchain.json` — `t1` with the session host killed during it
  (above): the setup is resumed under its own task, irisind installs the
  package once, and one toolchain is registered.

### Demo captures and the replay fixtures

`Documents/Console/demo/` holds the scripts whose output became the replay
fixtures (`Packages/ApelinKit/Sources/ApelinReplay/Fixtures`, read by
`ReplayTransport` where no apelind runs; `Documents/Plan/Handoff.md` ▸ the
replay). They are checked for form like the scripts above, but are not
needed to call every operation. Run them in this order on a device with a
toolchain, an SDK, the four development extensions and Irisin:

- `d1-projects.json` — makes the six demo projects, builds three, installs
  `Demo Tweak`, reads a terminal once, streams 5 s of the log and confirms
  the tweak loaded across a respring (open the app again after it). Delete
  the six project folders and remove the package before running it again.
- `d2-broken-build.json` — put an error into `Demo Broken CLI`'s
  `Sources/main.c` by hand first, and replace the placeholder with that
  project's `projectID` from d1's output; the build must fail with
  diagnostics.
- `a1-relaxed.json` — needs `inbox/credentials/openai-compatible.json`;
  a Relaxed session that edits and builds `Agent Relaxed Tweak`.
- `c1-confirm-open.json` — a Confirm session that stops at an
  `approvalRequested`. Then approve it by hand: a script with `agentApprove`
  (the `sessionID` and `approvalID` from c1's output) followed by an
  `agentAttach` of its task from `afterSeq` 0, followed to the end. That
  script names one device's IDs, so it is not kept here.
- `s1-abort-steer.json` — one session aborted and closed, one steered.

Then copy `console/out/*.jsonl` into `<folder>/out/` and the scripts that
ran (the approval one included) into `<folder>/scripts/`, and run
`Documents/Console/demo/make-replay-fixtures.py <folder>` on the Mac. It
rebuilds each request from its script, merges every read of a task by
`seq`, scrubs the bootstrap folder name, hostnames, model and kernel build
strings, trims build logs and the log stream, numbers each task's events
from 1 again, and writes nothing if a key, a Mac path or a device
identifier survives. `make harness` then reads the result through the
protocol types (`ApelinReplayTests`). The capture folder holds the
credential's effects, never the credential, but it stays outside the
repository all the same.

### Cleaning up after them

`Scripts/device.py` does it, from each script's `before` and `after` in
`device-harness.json`. By hand: remove `Projects/I2GitCheck/` and the
imported SDK (`sdkRemove`) after the `i2-` scripts, and delete the project
folder an `i3-` or `r1-` script made (`Projects/I3 Chain Tweak`, …) before
running it again; `i3-chain.json` removes the package it installed itself.
After the `transfer` scripts, delete `Exports/` and `Projects/Transfer Copy`.
