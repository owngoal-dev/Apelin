# Distributing a project

Open a project's menu and choose **Distribute…**. Choose **roothide** or
**rootless**, then tap **Build**. Opening the page or choosing a target does
not start a build. Build opens the build page, which runs one existing
release build for that target, showing Preparing, Compiling, Packaging and
Verifying (a workspace: Preparing, Running Build Script and Verifying); its
`…` menu has the Build Log. Stop cancels that build; the page
stays open with its outcome, and Retry starts a new build for the same
target. Once it succeeds, **Distribute** is the page's primary action. Its
menu, repeated in the `…` menu, has **Share Package**, which opens the
system share sheet with the build's one `.deb` file, **Publish to
Repository** and **Publish to GitHub Release** (below). Go back, choose the
other target and tap Build to make a separate package. None of them installs
the package.

A package already built does not need building again. The first page's
**Packages** section lists, for each target, the newest release build of the
project's current version (a workspace's newest release build), as long as its
`.deb` is still in `Builds/` with the digest the build recorded, and says
whether it is **Built**, **Shared** (a share sheet completed with it) or
**Published** (the linked repository already holds those bytes). Select the
packages and tap **Publish to Repository** to publish roothide and rootless
together in one commit, **Publish to GitHub Release** to put them on one
release, or share one from its row; each takes the file as the build made
it.

## Publishing to a package repository

A package repository is an APT source in a GitHub repository of the user's,
indexed by GitHub Actions and served by GitHub Pages at
`https://<owner>.github.io/<name>/`. Settings ▸ Git ▸ Publishing (or the
GitHub welcome page) creates one from Apelin's template, laid out after
owngoal-dev/owngoal-packages, or links one the user has, adding what the
template has and it lacks. Its clone is a workspace project, which its own
conversation maintains (the agent's `apelin-package-repository` skill).

Once a release build succeeds, **Distribute ▸ Publish to Repository** on the
build page, or **Publish to Repository** under the first page's Packages,
publishes it: each package, checked against its digest as Share Package
checks it, goes into the repository's `debs/` as
`<Package>_<Version>_<Architecture>.deb`, is committed and pushed, and the
workflow indexes it; sources that added the address see it within a few
minutes. Publishing the same package again does nothing; a different
package under a published version is refused, so raise the version first.
With no repository linked yet, Publish to Repository opens Settings ▸ Git
over the page instead: Publishing there creates or links one, after Sign In
with GitHub when there is no account yet. Close Settings and publish again;
the build stays as it was.

A conversation publishes release builds it has made without building them
again: asked to, it calls `apelin_package_publish` with those builds, which
go in together — the roothide and the rootless package of one version in one
commit —, each held to the digest its build recorded, and none goes in if
one has changed. In Strict mode it asks first, naming the repository and
every package with its digest; in every mode it publishes only what the user
asked for or agreed to.

## Publishing to a GitHub Release

Some package sources do not take committed packages: owngoal-dev's shared
source, owngoal-dev/owngoal-packages, names GitHub repositories and indexes
each one's newest stable **GitHub Release**, serving the `.deb` files from
it. **Publish to GitHub Release**, under the first page's Packages or in the
build page's Distribute menu, publishes the selected release packages there,
exactly as their builds made them, so the release carries the device's own
packages, whose dSYMs Apelin keeps to symbolicate their crashes. Never build
the package a second way for a release, such as a GitHub Actions workflow
that rebuilds it: that build drifts from Apelin's and keeps no dSYM.

- The release goes to the repository the project's GitHub remote names
  (`origin` first); a project with none asks for `owner/name`.
- Its tag is `v` and the version (`v1.0.2`), at the project's current
  commit, which must already be pushed there: commit, push, then publish. A
  version holding anything but letters, digits, periods, hyphens and
  underscores cannot name a release. All the selected packages must be one
  version.
- The confirmation names the tag, the repository, the commit and every
  package. Apelin then makes the release as a draft, uploads each package
  and a `SHA256SUMS` of every package on the release, and publishes it, not
  as a pre-release, so a source that takes the newest stable release picks
  it up. Open Release shows it on GitHub.
- A release of that tag that exists already is filled in: a package of the
  same name and bytes is left as it is, `SHA256SUMS` is written again when
  it changes, and notes it has are kept. A package already there with other
  bytes is refused before anything is uploaded; raise the version and build
  again.
- A tag GitHub has at another commit is never moved: release a new version
  from this commit instead. A release GitHub keeps immutable takes no new
  file once published.
- Without a GitHub sign-in it opens Settings ▸ Git, where Sign In with GitHub
  is. A release cut off part way stays a draft on GitHub; publishing the same
  version again fills it in and publishes it.

A conversation does the same with `apelin_package_release`, in the project's
own chat: the release builds of one version, to the repository the user
names or the project's own on GitHub. In Strict mode it asks first, naming
the repository, the tag, the commit and every package with its digest; in
every mode it releases only what the user asked for or agreed to.

## Before distributing

The first page lists what a package for other people should not carry yet,
from `projectCheck` with `purpose: distribution` (and the chosen target as
`bootstrap`). Each finding is a warning with a `distribution.*` code:

- `distribution.package.name.template`, `.description.template`,
  `.author.template`: the field is still a string default of the project's
  template.
- `distribution.package.version.template`: the version is still the one the
  template's project file starts with.
- `distribution.package.id.local`, `distribution.bundleID.local`: the package
  ID or an app's `CFBundleIdentifier` is still the `local.apelin.` one
  `projectCreate` made up.
- `distribution.icon.missing`: an app's Info.plist names no icon.
- `distribution.version.packaged`: a release package of this ID and version
  was already built for the target (any target, without one). Publish or
  share that package; raise the version only to ship a change. Build does not
  ask about it when that package is listed under Packages.

An error the check finds would stop the build, so it is listed too and Build
waits until it is fixed.

They are advice. Build still goes ahead after a confirmation, and the build
itself is never refused for them. **Ask Agent to Prepare** closes the page and
sends the project's conversation a request to run `apelin_project_check_distribution`, fix
what it lists and report back without building. The agent's
`apelin_project_check_distribution` tool answers the same findings; its `apelin_project_build` with
`configuration: release` and a `bootstrap` returns them among the
diagnostics, and its system prompt tells it to check before a distribution
build.

The project must have a valid `apelin-project.json`, an SDK and toolchain binding,
and architectures for the chosen bootstrap — or be a workspace that declares its
own build script (`external`; see the agent's apelin-external-build skill). A manifest
with no `build`, and a workspace with no script, have nothing to package:
**Distribute…** in the menu is disabled and says which is missing, and the
distribution page, if it is open when that is found, offers no target and says
the same.

## Workspaces

A workspace keeps its own build: Build runs its script once for the chosen
target, with `APELIN_CONFIGURATION=release` and that target's
`APELIN_BOOTSTRAP`, `APELIN_ARCHITECTURE` and `APELIN_PREFIX`, whatever this
device runs. Its script writes the one `.deb`; Apelin reads its control file,
requires the target's architecture and registers it as for any build. There is
no description to check before, so `apelin_project_check_distribution` and the first page
only say whether the script is declared. The release build reads the package it
wrote and lists, under the outcome and among the agent's build diagnostics:

- `distribution.package.id.local`: the package ID starts `local.apelin.`.
- `distribution.version.packaged`: this project already packaged this ID and
  version for the target.
- `distribution.package.id.differs`: the other target's latest release package
  has another ID.

They are warnings, as above; the package can still be shared and published.

For a project apelin-build builds, use its existing build and packaging description:

- Declare each target's actual architectures and bootstrap dependencies.
- Keep package layout paths logical. The packager maps rootless paths under
  `/var/jb` and writes roothide's unprefixed relocatable layout. The package
  architecture is `iphoneos-arm64` or `iphoneos-arm64e`, respectively.
- Declare maintainer scripts in `package.maintainerScripts` only when needed.
  Refer to bootstrap paths with `@PREFIX@` and real system paths with `@ROOTFS@`.
  The packager substitutes these per target and checks every script with `sh -n`.
- Use the typed `apelin_project_build` tool with `configuration: "release"` and an explicit
  `bootstrap: "roothide"` or `"rootless"` when asking the agent to build a
  distribution. Omit bootstrap for an ordinary build for the current device.
- Do not create a second packaging script that bypasses these checks. Never
  rename or copy one target's package and call it the other target.

The wire remains the existing `buildStart` operation, with an optional bootstrap
field; old requests retain their current-device behavior. Each target has its
own task, build directory, artifact ID and dSYMs. The worker reads the finished
Debian archive back, validates its structure and package identity/architecture,
checks the bytes against the recorded digest, then publishes the artifact.
The build page checks the digest again before it shares or publishes the package.

Builds retain the existing cancellation, on-demand session-host lifecycle and
resumption behavior. A distribution page itself is transient; if it is closed
or the app exits, its already completed artifacts remain in the normal Builds
folder. It does not modify project source, install packages or change the
current toolchain selection.
