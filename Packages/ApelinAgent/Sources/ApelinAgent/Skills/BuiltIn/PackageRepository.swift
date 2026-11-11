extension BuiltInSkills {
    static let packageRepository = SkillDocument(
        name: "apelin-package-repository",
        description: "Maintaining the user's package repository (an APT source on GitHub Pages): its layout, the packages in debs/, depictions, the control fields a package needs, how a release is published, and keeping old versions in check.",
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
        - The workflow's own failures show only on GitHub, in the repository's
          Actions tab: when the source does not update, say so and point the
          user there; you cannot read them from here.
        - Pushing publishes: in Strict mode `git_push` asks the user, and that
          is the step that makes a change public.
        """,
    )
}
