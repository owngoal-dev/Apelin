extension BuiltInSkills {
    /// Issue #79: what bit a user who released a tweak through GitHub
    /// Actions and debugged the workflow from a conversation. The API
    /// endpoints, their sizes and answers, and the signing behaviour were
    /// checked against owngoal-dev/Apelin's public runs and on a Mac
    /// (codesign, brew's ldid 2.1.5); that `git_commit` records an
    /// executable bit is held by ApelinKit's `GitServiceTests`.
    static let githubActions = SkillDocument(
        name: "apelin-github-actions",
        description: "GitHub Actions workflows in a project's repository, when the user asks for one: the packages to ship are the ones Apelin builds on the device, scripts and YAML that fail on a runner, signing on a macOS runner, release triggers without a tag tool, and reading a run's jobs, steps and annotations from a conversation, since its log cannot be read.",
        body: """
        # GitHub Actions in a project's repository

        GitHub Actions runs the workflows in a repository's
        `.github/workflows/` on GitHub's machines when something is pushed.
        Write or change one when the user asks for it; on a public
        repository it runs, and its results show, in public.

        ## What to ship
        The packages to ship are the ones Apelin builds on this device:
        `apelin_project_build` with `configuration: release` for each
        bootstrap, then Distribute… or `apelin_package_publish` (the
        apelin-packaging-and-install and apelin-package-repository skills).
        No tool here makes a GitHub Release of them: the user makes one on
        GitHub with the files Distribute… shares.

        A workflow that compiles and packages an Apelin project again on a
        runner is a second build beside Apelin's: it drifts from what this
        device builds, installs and tests, and a crash from its package
        cannot be symbolicated here, since its dSYMs are not on the device.
        Never offer one as the way to release an Apelin package. When the
        user asks for one anyway, say so first, then write what they asked
        for. A workflow that checks, tests or publishes what the repository
        already holds needs no such word.

        ## Before the first push
        - A script a step runs must be executable. `file_create` and
          `file_write` make a new file `rw-r--r--` (0644), and a later write
          keeps the mode it finds, so `run: Scripts/release.sh` fails on the
          runner at once. Run `chmod +x Scripts/release.sh` with `shell_run`,
          then `git_commit`, which records the executable bit; or write the
          step as `run: bash Scripts/release.sh`.
        - A YAML value with a colon and a space in it does not parse
          unquoted: `name: Audit: control` (or `run: echo status: ok`) makes
          the whole workflow file invalid, and no job starts. Quote it
          (`name: "Audit: control"`), leave the colon out, or put commands in
          a block: `run: |` with the lines indented below it.
        - A command that exits other than 0 fails its step: `codesign
          --version` exits 2 ("unrecognized option") and `ldid -v` prints its
          usage and exits 1. Neither prints a version: leave them out.

        ## Steps that say why they failed
        A job's log cannot be read from here (below), so make a failing run
        say why where it can be:
        - One check per step, named for what it checks: the run's list of
          steps then names the one that failed.
        - Print what each check sees before it decides, and when it fails,
          write that as an annotation:
          `echo "::error title=Control file::$message"`. An annotation is
          one line: write each line break in the message as `%0A`. A failed
          step that writes none leaves only GitHub's own, such as "Process
          completed with exit code 1."

        ## Signing on a macOS runner
        - `codesign --force --sign - --entitlements <file> <binary>` signs
          every slice of a universal binary ad hoc. Check every slice with
          `codesign -v --all-architectures <binary>`, and read its
          entitlements with `codesign -d --entitlements - --xml <binary>`.
        - `ldid -S<file>` without `-Cadhoc` writes a signature with no ad
          hoc flag: macOS's codesign reads every slice of it as "code object
          is not signed at all", and a plain `codesign -v` names only
          `arm64e`, which looks as if ldid had skipped that slice. Sign with
          `ldid -S<file> -Cadhoc` and read the entitlements back with
          `ldid -e`, or sign with codesign as above.

        ## Releasing without a tag tool
        No Apelin tool pushes a git tag: `git_push` pushes one branch. A
        release workflow can do without one:
        - On a push to `main`, read the version in `apelin-project.json`;
          when there is no tag `v<version>` yet, release that commit under
          it. A commit whose version is tagged already releases nothing.
        - A pushed tag `v<version>` still works, and fails unless it names
          the version committed in `apelin-project.json`.
        - `workflow_dispatch` with a tag as its input runs that release again
          and replaces its files.

        ## Reading a run from here
        `apelin_web_fetch` sends no token, and GitHub answers a job's or a
        run's log (`…/actions/jobs/<id>/logs`, `…/actions/runs/<id>/logs`)
        with 403, "Must have admin rights to Repository.": a log cannot be
        read from a conversation. On a public repository these can, each
        under `https://api.github.com/repos/<owner>/<repo>`:
        1. `/commits/<sha>/check-runs`: every job the commit ran, each with
           its `name`, `status`, `conclusion` and `id`, and the run's ID in
           its `details_url` (`…/actions/runs/<run id>/job/<id>`). About 3 KB
           a job.
        2. `/actions/runs/<run id>/jobs`: each job's steps, each with its
           `name` and `conclusion`.
        3. `/check-runs/<id>/annotations`: what the job's steps annotated,
           its `::error` messages among them. A job's check run has the
           job's ID.

        - Start from the check runs, not `/actions/runs`, which answers
          about 12 KB a run and some 360 KB for the 30 it lists by default.
        - A run that started no job, as one whose workflow file does not
          parse, has no check runs: `/actions/runs?head_sha=<sha>` lists it,
          with its workflow's `path` and `conclusion` `failure`.
        - The commit is the HEAD `git_status` answers, or the one `git_push`
          did.
        - Without a token GitHub answers 60 requests an hour; an answer over
          32 KB comes in pages, which `offset` reads on.
        - When none of it says enough, ask the user to open the run on
          GitHub, where its log is.
        """,
    )
}
