extension BuiltInSkills {
    static let tweakDevelopment = SkillDocument(
        name: "apelin-tweak-development",
        description: "Writing and changing a tweak in an Apelin project: layout, hooks, filters, the on-device toolchain and SDK, and the edit-build loop.",
        body: """
        # Tweak development on the device

        You are on a jailbroken iPhone or iPad (iOS 16 or later, roothide or
        rootless). The project lives in `~/Documents/wiki.qaq.apelin/Projects/<name>/`
        and every file tool works relative to that root. Nothing you write can
        leave it.

        ## The project
        - `apelin-project.json` is the build description: sources, compile and
          link flags, frameworks, the deployment target (16.0 by default,
          15.0 at the lowest for Objective-C and C) and build steps.
          Changing it, or a build script it names, makes the next `apelin_project_build` ask the
          user once (Strict mode); editing sources never does. Change it only
          when the task needs it, and say why. The apelin-project-description skill
          lists every member; read it before you edit the file.
        - Sources are Objective-C by default; write hooks the way the
          project's template does (its hook API comes from the injection
          framework the tweak extension depends on). Swift is available only if
          the user set it up with the toolchain.
        - The filter plist (`<Tweak>.plist`) selects the processes the dylib
          loads into, by bundle id (`Filter.Bundles`) or executable
          (`Filter.Executables`). SpringBoard is `com.apple.springboard`.
        - Read the template's files before writing new ones; keep its naming.
        - `apelin-icon.png`, beside `apelin-project.json`, is the project's
          icon in Apelin: a square PNG, 1024 points or less. Write it when the
          user asks for an icon; without it Apelin shows its kind's default.
          It is Apelin's alone and never goes into the package.
        - A path in code, a maintainer script or a plist is spelled as the
          apelin-bootstrap-paths skill says; logging is the apelin-tweak-runtime skill's.

        ## Finding the API you hook
        - `apelin_sdk_analyze_framework` lists a framework's exported symbols and
          Objective-C classes from the SDK's `.tbd`; `symbol_filter` narrows
          them. Both SDK tools look in `Frameworks`, then `PrivateFrameworks`,
          so `private` can be left out.
        - `apelin_sdk_read_header` reads a public header; with `symbol` in place
          of `header` it finds the header that declares a class, protocol, type
          or function. Private frameworks usually have no headers in the SDK:
          declare the interface you need in a local header, only the selectors
          you call.
        - Check availability: the build uses `-Werror=unguarded-availability-new`.
          Guard newer API with `@available(iOS 17.0, *)`.

        ## Writing hooks
        - Hook the narrowest method that produces the behaviour. Call the
          original unless the task is to replace it.
        - Never block the main thread in SpringBoard; a hang there is a
          respring loop for the user.
        - Keep the template's load-time marker log line intact so
          `apelin_package_confirm_loaded` can see it.
        - Symbols are hidden by default (`-fvisibility=hidden`); export only
          what the loader needs.

        ## Beside other tweaks
        Other tweaks load into the same process and often hook the same
        methods.
        - Install hooks with `MSHookMessageEx` or `MSHookFunction`, which
          chain with theirs, and call the original.
          `method_exchangeImplementations` and `method_setImplementation`
          can drop another tweak's hook.
        - Everything you name shares the process with them. Keep hook
          functions, saved originals and globals `static`. Give any method
          you add to a system class, and any class you create, your tweak's
          own prefix: when two tweaks use one name, one of them silently
          loses. Never override a system method in a category.
        - Key associated objects by the address of a `static` variable,
          never by a string.

        ## Theos and Logos
        Apelin does not build Theos projects: there is no Logos preprocessor
        and no Theos makefile system, and an Objective-C product compiles
        only `.m` and `.c` files (no `.x`, `.xm`, `.mm` or C++). Never
        download or vendor Theos. Rewrite a Theos tweak instead, keeping its
        logic, in the template's style:
        - A `%hook Class` method becomes a `static` function taking `id self,
          SEL _cmd` and the method's arguments, installed in the constructor
          with `MSHookMessageEx(objc_getClass("Class"), @selector(name:),
          (IMP)Hooked, (IMP *)&Original)`; `%orig` becomes
          `Original(self, _cmd, …)`. A class method hooks the metaclass,
          `object_getClass(objc_getClass("Class"))`.
        - `%ctor` is `__attribute__((constructor)) static void …(void)`;
          `%group` and `%init` are that constructor installing each group's
          hooks when its condition holds.
        - `%c(Name)` is `objc_getClass("Name")`; `%new` is `class_addMethod`
          with the method's type encoding; `%property` is a getter and setter
          on `objc_getAssociatedObject`; `%hookf` is `MSHookFunction`; `%log`
          is `os_log`.
        - Logos gave every hook a mangled name unique to the tweak
          (`_logos_method$…`); a rewrite names them itself, by the rules in
          Beside other tweaks. A Swift or C++ function is hooked by its
          mangled symbol, as apelin_sdk_analyze_framework lists it, looked up with
          `dlsym` or `MSFindSymbol`: a demangled name finds nothing. Check
          the symbol on each iOS version the package supports.
        - A `.x` file becomes `.m`; an `.xm` that uses C++ is rewritten
          without it.
        - The build links the SDK's public frameworks only. Reach a private
          class at run time with `objc_getClass`, and a private function with
          `dlopen` and `dlsym`.
        - Never link with `-undefined dynamic_lookup` or `suppress`, in
          `linkFlags` or a build script: CLT 15.0's linker then binds an
          arm64e slice without pointer authentication, and it crashes on its
          first constant string or imported call (the build refuses one).
          Leave a symbol to load time with `-Wl,-U,_symbol`, one per symbol.
        - A roothide-aware repository's `jbroot(…)` and a rootless one's
          `ROOT_PATH_NS(…)` become the apelin-bootstrap-paths skill's
          `ApelinBootstrapPath(…)`.
        - An imported repository stays a workspace: its Theos Makefile is
          replaced by a build script of its own that compiles the rewritten
          sources with the toolchain (the apelin-external-build skill), reading
          `TWEAK_NAME`, `_FILES`, `_FRAMEWORKS`, `_LIBRARIES`, `_CFLAGS`, the
          filter plist and `control` for what to build and package. Keep the
          package id, version and author the repository already has.

        ## The loop
        1. Read the relevant files (`file_read`, `file_grep`, `file_find`).
        2. Edit with `file_edit` (exact snippet, one occurrence) or
           `file_write`/`file_create` for new files.
        3. `apelin_project_build`. Fix every error diagnostic by file and line, rebuild.
           Treat warnings as work unless they are in the template.
        4. Install and confirm as the apelin-packaging-and-install skill describes.
           A target that starts only on demand (a daemon launched when a Mac
           connects, an app the user opens) is confirmed while it starts: tell
           the user what to start, then call `apelin_package_confirm_loaded`
           with `wait_seconds` and have them start it while the call listens.
        5. Check the behaviour itself, not only that it loaded: bring up what
           you changed, read it with `apelin_screen_read_tree`, drive it with
           `apelin_screen_interact`, and read it again after each action;
           while Ask Before Using the Screen is on, first tell the user what
           you will open, read and do there and why, and go on only once
           they consent explicitly (the prompt's rule, in every mode);
           behaviour that does not show in the UI tree is checked in what it
           logs (`apelin_log_read`), or in a screenshot only once the user
           has agreed to that one (the prompt's rule, in every mode). Report
           what you could not drive or see as Not tested.
        Keep each step its own call: build, install, respring and
        apelin_package_confirm_loaded are approved one by one.
        """,
    )
}
