import enum ApelinProject.ProjectValidation

extension BuiltInSkills {
    static let projectDescription = SkillDocument(
        name: "apelin-project-description",
        description: "Every member of apelin-project.json, the build description Apelin's build reads: products, flags, steps, package, layout, tweak filter, the macros the build defines, and what asks the user.",
        body: """
        # The project description

        `apelin-project.json` at the project root is the one thing Apelin's
        build reads. It is checked strictly: an unknown member, a duplicate
        key or a wrong type is an error naming its field, such as
        `/products/0/sources`. The complete schema is this skill's file
        `apelin-project.schema.json` (apelin_skill_read with that file).
        Apelin writes it two spaces a level, one member or element a line,
        and every build puts it back in that form, values unchanged: keep to
        it, and read the file again before file_edit after a build.

        ## Members Apelin writes
        Never invent, copy or change these:
        - `schemaVersion` (1) and `projectID`, a lowercase UUID approvals are
          bound to.
        - `template`: the template the project was made from.
        - `environment` `{toolchain, sdk}`, each `{id, digest}`: the
          registered toolchain and SDK. Change them only with
          apelin_project_set_environment; never type a digest.
        - `displayName` and `autoName`: the name Apelin shows.

        Only apelin_project_create writes `template` and `environment`, so a
        description written from scratch lacks them: it does not build, and
        no toolchain or SDK can be bound to it. Never rewrite a workspace
        (`"kind": "workspace"`) as one: it builds with a script of its own
        (the apelin-external-build skill).

        ## What it builds
        - `kind`: `tweak` (a `dylib` product and `package.tweakFilter`),
          `app` (an `app` product), `cli` (an `executable`) or `preferences`
          (a `bundle`). A project may carry more products than its kind's,
          such as a tweak with its own preference bundle.
        - `language`: `objc` and `c` compile `.m` and `.c` files only;
          `swift` compiles `.swift` only. A product never mixes them.
        - `deploymentTarget`: a string, "16.0" or later.
        - `architectures`: `{"rootless": ["arm64", "arm64e"], "roothide":
          ["arm64e"]}`. The keys present are the bootstraps it packages for.
        - `configurations`: `Debug` and `Release`, each `{optimization,
          debugInfo, defines?, cFlags?, swiftFlags?, linkFlags?}`.
          `optimization` is "0", "1", "2", "3", "s" or "z". `defines` maps a
          name to its value; no name starts with `APELIN_`. Each flag is one
          argument starting with `-`, never shell text: `-framework X` is two
          items. The member is `linkFlags`, not `linkerFlags`.

        ## products (one to eight)
        `{id, type, name, sources, …}`:
        - `id`: lowercase, such as `tweak`. `type`: `dylib`, `app`, `bundle`
          or `executable`. `name`: the Mach-O file name; product names are
          unique.
        - `sources`: project paths that may use `*`, `**` and `?`, such as
          `Sources/*.m` or `src/**/*.m`.
        - Optional: `headerSearchPaths`, `frameworks`, `weakFrameworks`,
          `libraries` (`-l` names, such as `substrate`),
          `frameworkSearchPaths` and `librarySearchPaths` (project paths),
          `objcARC`, `installName` (dylib only; default
          `@rpath/<name>.dylib`), `entitlements` (a project plist), and
          `infoPlist` and `resources` (app and bundle only).
        - `extensionSupport`: `[{extension, component}]`, the headers, link
          stubs and rpaths an installed development extension provides, the
          build picking each bootstrap's own. A tweak hooking with substrate
          has `{"extension": "wiki.qaq.apelin.dev.tweak", "component":
          "substrate"}`, `libraries: ["substrate"]` and depends on
          `mobilesubstrate`; a preference bundle has
          `{"extension": "wiki.qaq.apelin.dev.preferences", "component":
          "preferences"}`, `frameworks` with `Preferences`, and depends on
          `preferenceloader`.

        ## build.steps
        Per product, in this order: `compile`, `link`, `bundle-resources`
        (app and bundle), `lipo`, `dsym`, `strip`, `sign`. `compile`, `link`,
        `lipo` and `sign` are required and `sign` comes last, as `{"type":
        "sign", "product": "tweak", "identity": "adhoc"}`. `compile` and
        `link` take extra `flags`; `strip` takes `style`, `non-global` or
        `debug`. A `script` step, `{"type": "script", "id", "interpreter",
        "file", "arguments"?, "inputs"?, "outputs"?, "requiresApproval":
        true}`, runs a project script (sh, bash, zsh, python3 or perl) as
        mobile in the project root, to generate sources; it always asks the
        user in Strict mode.

        ## package
        `{id, name, version, description, author, section, layout, …}`:
        - `id`: the Debian package name; a new project's is a
          `local.apelin.` placeholder to settle with the user before its
          first install (the apelin-packaging-and-install skill's Package
          identity). `version`: a Debian version.
          `section`: Tweaks, Utilities, Development, System, Applications or
          Addons. Optional: `maintainer`, `longDescription` (a list of lines).
        - `icon`: the image a package manager shows beside the package, its
          control `Icon`: an `https://` URL in printable ASCII, at most 2048
          bytes. Every template writes its extension's icon on Apelin's
          Pages, such as
          `https://owngoal-dev.github.io/Apelin/icons/wiki.qaq.apelin.dev.tweak.png`.
          Keep it, or put in an https image the user gives as their own. It
          is not an app's own icon, which its Info.plist names.
        - Relations: `depends`, `recommends`, `suggests`, `conflicts`,
          `breaks`, `replaces` and `provides`, each item like `"name (>=
          1.0)"`, alternatives joined by ` | `; `dependsByBootstrap`
          `{rootless?, roothide?}` for one bootstrap only. The packager adds
          `firmware` and the `Architecture`; never write them.
        - `layout`: `{path, product}` or `{path, file, mode?,
          substitutePrefix?}` items. Paths are as the package sees them,
          rooted at the bootstrap, such as
          `/Library/MobileSubstrate/DynamicLibraries/X.dylib`; the packager
          maps them for rootless and roothide. Never write `/var/jb` or a
          jbroot path. `mode` is `0644` or `0755`; `substitutePrefix: true`
          fills `@PREFIX@` and `@ROOTFS@` in a file, such as a launch daemon
          plist (the apelin-bootstrap-paths skill).
        - `tweakFilter` (tweak only): `{dylib: <product id>, bundles?,
          executables?, classes?}`. The packager writes the filter plist
          beside the dylib, which must be laid out under
          `/Library/MobileSubstrate/DynamicLibraries/`; do not ship one
          yourself. A new tweak's `bundles` come from the template's
          `filterBundles`, an array of bundle IDs in apelin_project_create's
          `values`, such as `["com.apple.Preferences"]`.
        - `maintainerScripts`: `{preinst?, postinst?, prerm?, postrm?}`, each
          a project file. Only `@PREFIX@` and `@ROOTFS@` are substituted;
          `sh -n` must pass. They run as root and the install card shows
          them in full: add one only when the task needs it, written as the
          apelin-packaging-and-install skill says.

        ## What the build defines
        On every C and Objective-C compile: `APELIN_BUILD_ID`,
        `APELIN_PACKAGE_ID`, `APELIN_VERSION` and `APELIN_PRODUCT_NAME`
        (string literals); `APELIN_BOOTSTRAP_ROOTLESS` or
        `APELIN_BOOTSTRAP_ROOTHIDE` (1, for the bootstrap being built); and
        `APELIN_CONFIGURATION_DEBUG` or `APELIN_CONFIGURATION_RELEASE` (1).
        Swift gets the bootstrap and configuration as conditions. Code that
        behaves differently per bootstrap tests these; a repository's own
        macro is defined from them in a header. The build always passes the
        SDK, `-arch`, the deployment target, `-fvisibility=hidden` and
        `-Werror=unguarded-availability-new`, and `-fobjc-arc` with `objcARC`.

        ## What asks the user
        In Strict mode the next build asks once after a change to `kind`,
        `language`, `deploymentTarget`, `architectures`, `configurations`,
        `build`, `products` (except their `sources`, `headerSearchPaths` and
        `resources`), or an entitlements or script file. The next install
        asks once after a change to `package` (except `version`), a
        maintainer script or an installed file. Editing sources and bumping
        `version` never ask.

        ## A tweak's build members
        ```json
        "products": [{
          "id": "tweak", "type": "dylib", "name": "MyTweak",
          "sources": ["Sources/*.m"], "objcARC": true,
          "frameworks": ["Foundation", "UIKit"], "libraries": ["substrate"],
          "extensionSupport": [{"extension": "wiki.qaq.apelin.dev.tweak", "component": "substrate"}]
        }],
        "build": {"steps": [
          {"type": "compile", "product": "tweak"}, {"type": "link", "product": "tweak"},
          {"type": "lipo", "product": "tweak"}, {"type": "dsym", "product": "tweak"},
          {"type": "strip", "product": "tweak", "style": "non-global"},
          {"type": "sign", "product": "tweak", "identity": "adhoc"}
        ]},
        "package": {
          "id": "com.example.mytweak", "name": "MyTweak", "version": "1.0.0",
          "description": "What it does.", "author": "Someone", "section": "Tweaks",
          "depends": ["mobilesubstrate"],
          "layout": [{"path": "/Library/MobileSubstrate/DynamicLibraries/MyTweak.dylib", "product": "tweak"}],
          "tweakFilter": {"dylib": "tweak", "bundles": ["com.apple.springboard"]}
        }
        ```
        """,
        files: ["apelin-project.schema.json": ProjectValidation.schemaText],
    )
}
