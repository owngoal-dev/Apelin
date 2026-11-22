extension BuiltInSkills {
    static let packagingAndInstall = SkillDocument(
        name: "apelin-packaging-and-install",
        description: "From a successful build to a confirmed load: the package artifact and the GitHub Release of release builds, the package and bundle identifiers to settle before the first install and how to change one after it, install through the system installer and what to do when another package is in its way, maintainer scripts, respring, apelin_package_confirm_loaded, and removal.",
        body: """
        # Packaging and install

        `apelin_project_build` compiles, links, makes the dSYM, strips and signs (signing is
        last; nothing touches the binary after it), then writes the `.deb`. Its
        result lists artifacts with an `id`, a `kind` and a `digest`.

        ## Where the package goes
        - The `.deb` stays in Apelin's folder for that build, outside the
          project; the file tools do not reach it. It is the project's only
          package: never repack, rename or copy it into the project, and
          never make one yourself with `dpkg-deb -b`, `ar` or `tar`, to test
          or to hand over. A workspace's declared build script is the one
          place a package is put together (apelin-external-build).
        - A user who wants the package file takes it from Distribute… in the
          project chat's More (…) menu: it runs a release build for the
          bootstrap they choose, then exports that package. Release builds
          you already made go to the user's package repository with
          `apelin_package_publish`, as they are, when the user asks for it
          (apelin-package-repository).

        ## A GitHub Release
        - A source that indexes each repository's newest stable GitHub
          Release, such as owngoal-dev/owngoal-packages, takes a project's
          packages from a release of its repository, not from committed
          files. `apelin_package_release`, in the project's chat, publishes
          the release builds of one version as the release `v<version>` of
          the GitHub repository the user names (the project's own origin
          when they name none), with a `SHA256SUMS`, exactly as the builds
          made them.
        - Its tag names the project's current commit, which must already be
          on that repository: commit, then `git_push`, then release. A tag
          GitHub has at another commit is never moved; release a new version.
        - A release the tag has already is filled in, a file of the same
          bytes left as it is; one with other bytes is refused, so raise the
          version and build again.
        - Only when the user asked for the release, or agreed when you
          asked, after telling them which packages go to which repository and
          tag. Never write a workflow that builds the package again on GitHub
          Actions to release it: that is a second build that drifts from
          Apelin's and keeps no dSYM for `apelin_crash_symbolicate`.

        ## Package identity
        - A new project's `package.id` in apelin-project.json, and an app's
          `CFBundleIdentifier` in its Info.plist, start as `local.apelin.…`
          placeholders Apelin made up from the folder name. Before the first
          install, ask the user for permanent reverse-DNS identifiers, or
          whether to keep these, and write each one everywhere the project
          spells it: `file_grep` for `local.apelin.` finds each place, such
          as an app's `application-identifier` entitlement and a preference
          bundle's `Root.plist` domain. `apelin_project_create` takes them
          up front as `packageID` and `bundleID` in `values`.
        - Debug and release builds carry the same identifiers: a release is
          the same package at a higher version, never a renamed one.
        - `apelin_package_list` with this project says whether a package of
          it is installed. Once one is, its identifiers are established:
          never change them on your own, and never assume a build under a
          new package ID upgrades the installed package in place. The new ID
          is another package, and the old one stays installed until it is
          removed. When the user wants one changed, agree the migration with
          them before installing:
          - A new package that installs a file the old one installed (the
            same dylib or app bundle) is refused, naming the old package in
            `conflicts` (below); one that installs none goes in beside it,
            and both stay installed. Either way the plan is to remove the old
            installation with `apelin_package_remove` (in Strict mode it
            asks), then install the new package, and only with the user's
            agreement.
          - Nothing follows the identity: an app's data and preferences, a
            preferences domain named for the package ID (the preference
            bundle template's) and anything else keyed by the old bundle ID
            or package ID stay where they were. Say so, and ask whether any
            of it must be carried over before the old package goes.

        ## Install
        - Call `apelin_package_install` with the `package` artifact's `id` and `digest`
          exactly as `apelin_project_build` returned them. The host copies that artifact to
          private staging and checks the digest before the installer sees it; a
          mismatch is refused, so never guess or reuse a digest from an older
          build.
        - The packaging description (control fields, maintainer scripts,
          install layout, dependencies) is compared with the template. Matching
          installs run; a changed one asks the user once, showing the package
          id, the diff and every maintainer script. Do not add maintainer scripts
          unless the task needs them; they run as root.
        - The result carries a `transactionID` and, on success, an
          `installationID`, which `apelin_package_remove` takes;
          `apelin_package_list` finds it again later.
        - Installation goes through Irisin's installer. There is no `dpkg` or
          `apt` for you to call, and `shell_run` must not try; the
          apelin-package-dependencies skill covers what installs a dependency.

        ## When another package is in the way
        The installer resolves nothing: it never removes a package to make
        room for yours. An install fails when an installed package owns one
        of its files (`… is owned by …; Replaces is required`) or when its
        `package.conflicts` or `package.breaks` names an installed package
        (`Conflicting final packages`). The result's `conflicts` then names
        each package in the way, the file, and the `installationID` when
        Apelin installed it.
        - After a package ID change the user agreed to (Package identity,
          above), or reusing a product name another package already
          installs, remove the installation named there with
          `apelin_package_remove` (in Strict mode the user confirms it), then
          install again. A package Apelin did not install is the
          user's to remove with their package manager: ask them.
        - Adding `conflicts` or `breaks` removes nothing; it only makes the
          install fail while that package is there.
        - Name a package in `package.replaces` only when the user wants
          yours to take over its files.
        - Never rename the dylib or drop a file to get past the failure
          without telling the user.

        ## Maintainer scripts
        Add one only when the task needs it (postinst, prerm, …), as a project
        file named in `package.maintainerScripts`. They run as **root**, in
        the bootstrap, and the install card shows each in full:
        - Spell paths `@PREFIX@/…` (bootstrap) and `@ROOTFS@/…` (system), the
          only tokens substituted, as the apelin-bootstrap-paths skill says; `sh -n`
          must pass.
        - Start with `set -e`. A path a script removes, moves or overwrites
          is written out in full (`@PREFIX@/Library/…`); one that has a
          variable in it spells it `${name:?}`, so the script stops when the
          variable is empty instead of running `rm -rf` on `/` as root.
        - A daemon your package ships is loaded by its postinst: boot the
          label out of `system/`, `user/501/` and `gui/501/` (roothide's
          launchctl can put a bootstrap daemon in the per-user domain), then
          `launchctl bootstrap system "@PREFIX@/Library/LaunchDaemons/<label>.plist"`;
          prerm boots it out on `remove`. Keep the label in a variable alone
          on its line. A daemon your tweak injects into is restarted by your
          postinst too; a SpringBoard tweak needs a respring, not a script.
        - Do not register the app, rebuild the icon cache or respring from a
          script, and do not `mkdir -p` a folder for mobile as root (it leaves
          the parents root-owned): make each level with `mkdir -m 0755` and
          `chown -h 501:501`, skipping a level that exists and never following
          a symlink.
        - A link you ship or create is relative (apelin-bootstrap-paths).

        ## Respring and confirm
        - A tweak loaded into SpringBoard needs `apelin_device_respring`; one
          loaded into an app takes effect when that app starts again. After
          respring the session continues; the app may reconnect.
        - An app project: installing replaces the bundle on disk, but a copy
          already running keeps the previous build until it exits, and the
          install does not stop it (its result's `relaunchHint` says so).
          Restart it through shell_run as mobile, never with `root: true`:
          `{"argv": ["icli", "app", "kill", "--force", "<bundle id>"]}` (icli
          refuses a kill without `--force`), then
          `{"argv": ["icli", "app", "launch", "<bundle id>"]}`. The kill
          answers the pids it stopped; before saying the new build runs,
          check that `icli app running` lists the app under another pid. The
          bundle id is the `CFBundleIdentifier` of the app product's
          Info.plist; `icli app list` names it too.
        - `apelin_package_confirm_loaded` with the `buildID` and the target process reports
          the marker log line, whether the filter selects the target and
          whether the target process ran while it listened (`targetProcess`),
          separately; its `loaded` rests on the marker alone, since the image
          list is never read, on any iOS version. The marker is logged once,
          when the target starts, and is only seen while `apelin_package_confirm_loaded`
          listens (15 s; 30 s with a respring; the call ends as soon as it
          hears it): for a SpringBoard tweak pass
          `respring: true` instead of a separate `apelin_device_respring`. For an app, your
          tool calls run one at a time, so quit it first if it runs
          (`icli app kill --force <bundle id>`), then ask the user to open it
          while the call listens; an installed app's bundle id works when it
          is not running. For a process that starts only on demand — a
          daemon launched when a Mac connects, such as `dtremotedisplayd`, or
          a helper an action starts — first tell the user what to do, then
          call with `wait_seconds` (up to 180) and have them do it while the
          call listens; call again rather than asking for longer.
          "Installed" is not "loaded": report both. When `targetProcess` says
          the process never ran, report it as not started, not as not loaded.
        - If nothing loaded: check the filter plist's bundle id against the
          target, the injection framework dependency (`mobilesubstrate` in
          `depends`), then `apelin_log_read` for the target process. A daemon
          started with `DISABLE_TWEAKS=1`, and an app on roothide's blacklist,
          load no tweaks at all.

        ## Removal
        - `apelin_package_list` lists what Apelin installed that is still on
          the device, from every project and conversation: per package, the
          installation id, version, the project whose build it was, and
          whether it can be removed. Read it instead of rebuilding or
          reinstalling to get an id, and instead of asking another project's
          conversation to remove its package.
        - `apelin_package_remove` takes that installation id, one an install
          returned or a refused install names in `conflicts`, or the package
          id alone, and removes only what a project's build installed:
          bootstrap packages, Apelin itself and its toolchains (removed in
          Settings) are out of reach, and a package installed some other way
          is the user's to remove with their package manager. In Strict mode
          every removal asks.
        """,
    )
}
