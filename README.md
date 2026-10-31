<p align="center"><img src="Documents/Site/icon.png" width="128" alt=""></p>

# Apelin

## Write. Build. Install. On the device.

Apelin is an IDE for iPhone and iPad running custom firmware on iOS and iPadOS 16 or later. Its agent writes, builds, installs and debugs tweaks, apps, command-line tools and preference bundles on the device itself, with no Mac needed. It works with both rootless and roothide bootstraps.

![Preview](Documents/screenshots.jpg)

## Features

- Designed for both iPhone and iPad
- Sets up Apple's Command Line Tools on the device, for C, C++ and Objective-C, with Swift as an option. You don't need Xcode or an Apple ID
- Downloads and checks the iPhoneOS SDKs, or imports one from a file
- Templates for tweaks, apps, command-line tools and preference bundles, or an empty workspace that keeps your project's own build script
- Builds, signs, packages and installs through Irisin, then resprings and checks that your tweak loaded
- An agent that edits your project, builds and installs it, and reads logs and crash reports. Sign in with GitHub Copilot, Claude, ChatGPT, OpenRouter and many other providers, or use an API key
- Choose how much the agent may do on its own: Strict asks before anything beyond a project edit, and every command as root asks unless you turn on Full
- A code editor, a terminal and git, with Sign In with GitHub
- Publish your packages to your own package repository on GitHub Pages, and share it as a card anyone can scan to add it in Irisin
- Read the live log, symbolicate crash reports against your own builds, and take screenshots
- Move a toolchain, an SDK or a project to your other device as one file
- Available in 13 languages
- Open source under the MIT License

## Installation

Add **[apt.owngoal.dev](https://apt.owngoal.dev/)** in your preferred package manager, or download the package for your bootstrap from [Releases](https://github.com/owngoal-dev/Apelin/releases):

| Bootstrap | Package |
| --- | --- |
| roothide | `iphoneos-arm64e` |
| rootless (`/var/jb`) | `iphoneos-arm64` |

Apelin needs [Irisin](https://github.com/Lakr233/Irisin) 4.7.3 or later, which installs the packages you build, and an A12 or later for the compilers. Which iOS versions and CPUs can run Swift depends on the toolchain release: [Compatibility](Documents/Compatibility.md) lists them.

The development extensions add the project templates and come with Apelin by default; Apelin still works if you remove one. The tweak template depends on an injection framework, which Apelin itself does not.

| Extension | Adds |
| --- | --- |
| `wiki.qaq.apelin.dev.app` | UIKit apps in Objective-C or Swift |
| `wiki.qaq.apelin.dev.tweak` | Tweaks |
| `wiki.qaq.apelin.dev.cli` | Command-line tools in C or Objective-C |
| `wiki.qaq.apelin.dev.preferences` | Preference bundles |
| `wiki.qaq.apelin.agent-tools.disassembler` | A disassembler for the agent, on Capstone |
| `wiki.qaq.apelin.agent-tools.assembler` | An assembler for the agent, on Keystone (GPL-2.0; its source is published with each release) |

## Open in Apelin

A repository's README can carry a button that opens the repository in Apelin, which asks before importing it into a new project:

```markdown
[![Open in Apelin](https://owngoal-dev.github.io/Apelin/open/badge.svg)](https://owngoal-dev.github.io/Apelin/open/?url=https%3A%2F%2Fgithub.com%2Fowner%2Frepo)
```

`url` is the repository's HTTPS address, URL-encoded. Add `&branch=<name>` to check out a branch other than the default. The link carries nothing else: no command, no message for the agent and no credential. Apelin shows the address, the branch and the new project's name, and imports only once you confirm. Nothing in the repository runs, and nothing is sent to the agent. A private repository needs a sign-in: Sign In with GitHub in Settings ▸ Git for github.com. Without Apelin, the page explains how to install it and lets you copy the address.

## Report a Problem

Choose Report a Problem in Settings, or [open an issue on GitHub](https://github.com/owngoal-dev/Apelin/issues/new). Search the existing issues first to avoid duplicates.

If Apelin crashes or a build or an installation fails, include the log from Settings ▸ Logs. The log may contain your project names, paths and repository addresses, so review it before you share it.

## Privacy

Agent and git credentials are kept in the keychain, on this device only, and never synced. Apelin has no telemetry: your conversations go only to the model provider you signed in to.

## Build from Source

Open `Apelin.xcodeproj` in the newest Xcode. To build the packages:

```sh
make harness      # run the tests on the Mac
make check        # project, packaging, string and accessibility checks
make deb-all      # build the roothide and rootless packages
make install DEVICE_HOST=<address> FLAVOR=roothide
```

You need `dpkg`, `ldid`, `zstd` and `swiftformat` from your preferred package manager. There is no Simulator build. Notes for contributors are in [AGENTS.md](AGENTS.md), and you can drive the app headless through the [console](Documents/Console.md).

The [session reliability and history plan](Documents/Plan/Session-Storage-Refactor.md) targets low concurrency and millions to tens of millions of archived events, read on demand. Three releases are iteration windows, with scope driven by evidence; storage stays file-based and the kwwk revision stays fixed.

## Acknowledgements

Apple's Command Line Tools and iPhoneOS SDKs remain Apple's, under Apple's terms. Apelin never ships them. The SDK repository [owngoal-dev/iOS-SDKs](https://github.com/owngoal-dev/iOS-SDKs) is forked from [xybp888/iOS-SDKs](https://github.com/xybp888/iOS-SDKs).

Third-party components keep their own licenses. Their notices are in [Licenses/](Licenses/) and in the app under Settings ▸ Open Source Licenses.

## Sponsor

[LookInside](https://lookinside-app.com/) lets you inspect the interface of a running iOS or macOS app from your Mac.

---

Copyright © 2026 OwnGoal Studio. Released under the [MIT License](LICENSE).
