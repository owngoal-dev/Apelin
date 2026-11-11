extension BuiltInSkills {
    static let packageDepiction = SkillDocument(
        name: "apelin-package-depiction",
        description: "Giving a package its page in a package manager, changelog tab included: the Depiction and SileoDepiction control fields from package.depiction and package.sileoDepiction, how to write the native depiction JSON Sileo and Irisin draw, and where to host it.",
        body: """
        # A package's depiction

        A package manager shows a page for each package. The control's
        `Description` is only the text under the name: the page's tabs, a
        changelog among them, come from a depiction the package names in its
        control file. There are two fields, and a package may carry both:

        - `Depiction`: a web page, which a package manager opens as it is.
        - `SileoDepiction`: the native depiction, a JSON document that Sileo
          and Irisin draw themselves. Irisin draws only this one. A changelog
          tab goes here; without it Irisin writes a page from the control
          fields, with no changelog.

        ## In apelin-project.json
        `package.depiction` and `package.sileoDepiction`, both optional, each
        an `https://` URL in printable ASCII of at most 2048 bytes:

            "package": {
              "icon": "https://<host>/depictions/<package id>/icon.png",
              "depiction": "https://<host>/depictions/<package id>/",
              "sileoDepiction": "https://<host>/depictions/<package id>/depiction.json"
            }

        The build writes them as the control's `Depiction` and
        `SileoDepiction`, after `Icon`, and writes nothing for one that is
        absent. Both are part of the packaging description, so in Strict mode
        the first install after adding or changing one asks the user.

        Apelin only passes the addresses on; nothing is uploaded and nothing
        is checked to be there. Add a member only with an address the user
        gave or agreed to. Never make one up: a package manager shows nothing
        for an address that does not answer.

        ## Where the files live
        Any https host does. The user's package repository (the
        apelin-package-repository skill) is made for it: `depictions/<package
        id>/` holds `index.html` (for `Depiction`), `depiction.json` (for
        `SileoDepiction`), `icon.png` and `banner.png`, and Pages serves them
        at `<source>/depictions/<package id>/…`.

        A package manager fetches the depiction when the page opens, so the
        notes of a new version are a commit to `depiction.json`, with no
        rebuild for the notes themselves. The package still carries its own
        `version`.

        ## The native depiction
        This skill's file `depiction.json` is a page to start from, with a
        Details tab and a Changelog tab: read it with apelin_skill_read
        `{"name": "apelin-package-depiction", "file": "depiction.json"}`.
        Its shape:

        - The root: `{"class": "DepictionTabView", "minVersion": "0.4",
          "tabs": […]}`. Optional: `headerImage` (an https image, the banner
          above the page) and `tintColor` (a CSS colour such as `#34C759`).
        - A tab: `{"tabname": "…", "class": "DepictionStackView", "views":
          […]}`. Every tab needs `tabname` and `class`; one without either
          and the whole depiction is not drawn.
        - Views, drawn top to bottom, each an object with a `class`:
          `DepictionHeaderView` (`title`), `DepictionSubheaderView` (`title`),
          `DepictionMarkdownView` (`markdown`, and `useSpacing`: true),
          `DepictionSeparatorView`, `DepictionTableTextView` (`title`,
          `text`: one row, such as Version beside its number).
        - A changelog tab: for each version, newest first, one
          `DepictionSubheaderView` whose `title` is the version, then one
          `DepictionMarkdownView` with its notes.

        Write it as UTF-8 JSON and keep the tab names in the language the
        user's readers read. A file that does not parse, or a root or tab
        that names a class a package manager does not know, is not drawn.

        ## Checking
        - `apelin_web_fetch` the address: it answers the JSON once the host
          serves it. On GitHub Pages that is after the repository's workflow
          has run.
        - Build and install, then ask the user to open the package in their
          package manager: its page shows the depiction's tabs.
        """,
        files: ["depiction.json": sampleDepiction],
    )

    /// A native depiction with the views Irisin's renderer draws (its
    /// PackageDepiction package) and Apelin's own page on Pages uses; a test
    /// holds it to that list and to the shape the skill describes.
    static let sampleDepiction = """
    {
      "class": "DepictionTabView",
      "minVersion": "0.4",
      "tabs": [
        {
          "tabname": "Details",
          "class": "DepictionStackView",
          "views": [
            { "class": "DepictionHeaderView", "title": "Description" },
            {
              "class": "DepictionMarkdownView",
              "markdown": "What the package does, in a paragraph or two. **Markdown** works here.",
              "useSpacing": true
            },
            { "class": "DepictionSeparatorView" },
            { "class": "DepictionHeaderView", "title": "Information" },
            { "class": "DepictionTableTextView", "title": "Version", "text": "1.0.1" },
            { "class": "DepictionTableTextView", "title": "Requires", "text": "iOS 16.0 or later" }
          ]
        },
        {
          "tabname": "Changelog",
          "class": "DepictionStackView",
          "views": [
            { "class": "DepictionSubheaderView", "title": "1.0.1" },
            {
              "class": "DepictionMarkdownView",
              "markdown": "- What changed in this version, one line each.",
              "useSpacing": true
            },
            { "class": "DepictionSubheaderView", "title": "1.0.0" },
            {
              "class": "DepictionMarkdownView",
              "markdown": "- First release.",
              "useSpacing": true
            }
          ]
        }
      ]
    }

    """
}
