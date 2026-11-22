extension BuiltInSkills {
    static let packageRepository = SkillDocument(
        name: "apelin-package-repository",
        description: "Maintaining the user's package repository (an APT source on GitHub Pages): its layout, the packages in debs/, depictions, the control fields a package needs, how a release is published, and keeping old versions in check; and adding a project to a shared source that indexes GitHub Releases, such as owngoal-packages.",
        body: """
        # Maintaining a package repository

        A package repository is an APT source the user's devices and other
        people add in Irisin. Apelin keeps one in a GitHub
        repository of the user's, set up from Settings ▸ Git ▸ Publishing:
        Create Distribution Repository makes it from Apelin's template, and
        Link Distribution Repository takes one the user has, adding what the
        template has and it lacks. Either way its folder is a workspace
        project, and that project's conversation maintains it with the file
        and git tools. GitHub Pages serves it at
        `https://<owner>.github.io/<repository>/`, the address users add as a
        source.

        ## Layout
        - `debs/`: the packages, one `.deb` each, named
          `<Package>_<Version>_<Architecture>.deb`. No two files have the same
          name, nor the same Package, Version and Architecture.
        - `depictions/<package id>/`: optional, per package: `index.html` (the
          web depiction), `depiction.json` (the native depiction Irisin shows),
          `icon.png` and `banner.png`. Pages serves them at
          `<source>/depictions/<package id>/…`, the addresses a package's
          `Depiction`, `SileoDepiction` and `Icon` fields name: in a project,
          `package.depiction`, `package.sileoDepiction` and `package.icon`
          (the apelin-package-depiction skill).
        - `index.html`: the source's home page; `CydiaIcon.png`: its icon.
        - `sileo-featured.json`: the banners Irisin shows at the top of the
          source, each naming a package and an image under `depictions/`.
        - `scripts/update-repository.sh` and
          `.github/workflows/update-repository.yml`: on every push to `main`,
          GitHub Actions indexes `debs/` with apt-ftparchive into `Packages`,
          `Packages.xz` and `Release` and publishes the site to Pages. Those
          indexes and `_site/` are built there; never commit them.

        ## Publishing a release
        - A project's Distribute… page builds a release package for each
          bootstrap (`iphoneos-arm64e` for roothide, `iphoneos-arm64` for
          rootless), and its Publish copies the package into `debs/` here,
          commits and pushes. The source shows it once the workflow has run,
          usually within a few minutes; Pages may serve the old index for up
          to ten more.
        - From a conversation, `apelin_package_publish` does the same with
          release builds already made: the roothide and the rootless build
          of one version in one call, each exactly as its build made it.
          Call it only when the user asked to publish them, or agreed when
          you asked. Never copy a `.deb` into `debs/` yourself: the tool
          holds each package to the digest its build recorded.
        - A package's control file needs `Package`, `Name`, `Version`,
          `Architecture`, `Description`, `Maintainer`, `Author` and `Section`
          (the package's category: Tweaks, Applications, Utilities, Themes…); the
          workflow fails without `Section`. A project sets them in its
          apelin-project.json (the apelin-project-description skill), not here.
        - A new version is a new file. Never replace a published file under
          the same name: clients compare it with the index they cached.

        ## Maintaining it
        - Keep the newest few versions of each package. Remove an older one
          with shell_run (`rm debs/<file>`), then `git_commit` with `all: true`
          and `git_push`.
        - Write depictions and featured banners when the user asks for a
          better page; keep images small (a banner around 1000×400, an icon
          120×120, PNG).
        - When the source still does not update, look at the workflow's run:
          its log shows only on GitHub, in the repository's Actions tab, but
          whether it failed, at which step, and what it annotated can be
          read from here (the apelin-github-actions skill). Say what you
          found, and point the user to that tab for the log.
        - Pushing publishes: in Strict mode `git_push` asks the user, and that
          is the step that makes a change public.

        ## A shared source that lists repositories
        Some sources, often shared by several projects, hold no packages of
        a project: their `manifest.json` lists GitHub repositories, and their
        workflow indexes each one's GitHub Releases. owngoal-dev/owngoal-packages
        (`https://apt.owngoal.dev/`) is one. A project gets into it as an
        entry naming its repository, whose GitHub Releases carry the
        packages. Read the source's README, `manifest.json` and workflow
        first; owngoal-packages' say:
        - An entry: `{"repository": "https://github.com/<owner>/<repo>",
          "architectures": ["iphoneos-arm64e", "iphoneos-arm64"]}`, each
          repository once, with the architectures its releases carry; add
          `"allPackages": true` when one release holds several packages.
        - The workflow indexes each repository's three newest stable
          releases and the newest of the minor version before them: not a
          draft or a prerelease, and no `alpha`, `beta`, `rc`, `pre`,
          `preview`, `dev`, `nightly` or `snapshot` as a word of the tag
          (`v1.2-beta`). From each it
          takes, per architecture, the first asset whose name ends
          `<architecture>.deb` (every one with `allPackages`), checked
          against the release's `SHA256SUMS` when it has one; devices
          download it from the release.
        - One entry that fails stops the whole build, and the source keeps
          its old index for every package in it: a repository with no
          stable release, or whose newest release has no `.deb` for an
          architecture its entry lists. So before adding an entry, check the
          release: `apelin_web_fetch`
          `https://api.github.com/repos/<owner>/<repo>/releases/latest`
          answers the newest release that is neither a draft nor a
          prerelease, its `tag_name` and each asset's `name`, and 404 when
          there is none; its tag must hold none of the words above.
        - Never commit a listed project's `.deb` files there: `debs/` is for
          packages with no release of their own, and a file name both give
          stops the build too.
        - The workflow runs on a push to `main` that changes the manifest,
          every day at 04:00 UTC and by hand, so a new release of a listed
          repository shows by the next day.
        - It is a repository of its own: change it only when the user asks,
          in a workspace that imported it, and push as the user agrees.
        """,
    )
}
