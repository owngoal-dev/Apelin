# Apelin Xcode build and jailbreak Debian packaging (roothide, rootless)

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

ROOT_DIR            := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PROJECT             := $(ROOT_DIR)/Apelin.xcodeproj
# The app scheme builds apelind too: the app target depends on the daemon.
SCHEME              := Apelin
CONFIGURATION       ?= Release
DERIVED_DATA        ?= /private/tmp/apelin-deriveddata

DEVICE_DESTINATION  := generic/platform=iOS
PRODUCTS_DIR        := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos
TARGET_INTERMEDIATES := $(DERIVED_DATA)/Build/Intermediates.noindex/Apelin.build/$(CONFIGURATION)-iphoneos
APP_BUNDLE          := $(PRODUCTS_DIR)/Apelin.app
DAEMON_BINARY       := $(PRODUCTS_DIR)/apelind
# The workers apelind's session host spawns; each one's entitlements are
# Packaging/Workers/<name>.entitlements.
WORKERS             := apelin-environment apelin-build apelin-agent apelin-diagnostics apelin-log-reader
WORKER_ENTITLEMENTS := $(addprefix $(ROOT_DIR)/Packaging/Workers/,$(addsuffix .entitlements,$(WORKERS)))
PACKAGE_ID          := wiki.qaq.apelin
BUNDLE_ID           := wiki.qaq.apelin
DAEMON_ID           := wiki.qaq.apelind
PROJECT_OBJECT_VERSION := 77

# Which jailbreak layout the .deb is built for. roothide relocates the package
# into the jbroot it picked this boot, so its paths ship unprefixed; a rootless
# bootstrap lives at a fixed /var/jb that every path in the package has to
# name. The binaries are identical — only the layout and the architecture
# label differ.
FLAVOR              ?= roothide
ifeq ($(FLAVOR),roothide)
PACKAGE_PREFIX      :=
PACKAGE_ARCHITECTURE := iphoneos-arm64e
else ifeq ($(FLAVOR),rootless)
PACKAGE_PREFIX      := /var/jb
PACKAGE_ARCHITECTURE := iphoneos-arm64
else
$(error FLAVOR must be roothide or rootless, got '$(FLAVOR)')
endif

CONFIG_DIR          := $(ROOT_DIR)/Configuration
VERSION_CONFIG      := $(CONFIG_DIR)/Version.xcconfig
xcconfig_setting     = $(strip $(shell awk -F= '$$1 ~ /^[[:space:]]*$(1)[[:space:]]*$$/ { gsub(/[[:space:]]/, "", $$2); print $$2; exit }' "$(VERSION_CONFIG)"))
APP_VERSION         := $(call xcconfig_setting,MARKETING_VERSION)
# The build number is passed on the xcodebuild line and never written back to
# Version.xcconfig: CI passes its run number, a local build the commit count.
# The xcconfig's own number is what an Xcode-run build carries.
BUILD_NUMBER        ?= $(shell git -C "$(ROOT_DIR)" rev-list --count HEAD 2>/dev/null || echo 1)
DEB_OUTPUT          ?= $(ROOT_DIR)/build/Packages/$(PACKAGE_ID)_$(APP_VERSION)_$(PACKAGE_ARCHITECTURE).deb

# The clang module holding the SDK's XPC_TYPE_* macros as C functions. Xcode
# reaches it through SWIFT_INCLUDE_PATHS in Configuration/Base.xcconfig; the
# hand-rolled harness compile needs the same -I.
XPC_SHIM_DIR        := $(ROOT_DIR)/Shared/XPCShim
XCODEBUILD_WRAPPER  := $(ROOT_DIR)/Scripts/run-xcodebuild.sh
DEB_PACKAGER        := $(ROOT_DIR)/Scripts/package-deb.sh
DEVICE_INSTALLER    := $(ROOT_DIR)/Scripts/install-device.sh
VERSION_APPLIER     := $(ROOT_DIR)/Scripts/apply-version.sh
LICENSE_COLLECTOR   := $(ROOT_DIR)/Scripts/collect-licenses.py
ACCESSIBILITY_CHECK := $(ROOT_DIR)/Scripts/check-accessibility.py
STALE_STRINGS_CHECK := $(ROOT_DIR)/Scripts/check-stale-strings.py
FORMAT_STRINGS_CHECK := $(ROOT_DIR)/Scripts/check-format-strings.py
TRANSLATIONS_CHECK := $(ROOT_DIR)/Scripts/check-translations.py
CATALOG_KEYS_CHECK := $(ROOT_DIR)/Scripts/check-catalog-keys.py
SHELL_DELETES_CHECK := $(ROOT_DIR)/Scripts/check-shell-deletes.py
SYMBOL_CHECK        := $(ROOT_DIR)/Scripts/check-symbol-availability.py
RPATH_CHECK         := $(ROOT_DIR)/Scripts/check-rpath-dependencies.py
# The device harness: console scripts and suites on a vphone or a device,
# from the Mac (Documents/Console.md ▸ From the Mac).
DEVICE_TOOL         := $(ROOT_DIR)/Scripts/device.py
CONTROL_TEMPLATE    := $(ROOT_DIR)/Packaging/DEBIAN/control
ENTITLEMENTS        := $(ROOT_DIR)/Packaging/Apelin.entitlements
DAEMON_ENTITLEMENTS := $(ROOT_DIR)/Packaging/Apelind.entitlements
# The widget extension's (Widgets/Extension): sandboxed, the App Group alone.
WIDGET_ENTITLEMENTS := $(ROOT_DIR)/Packaging/ApelinWidgets.entitlements
# The development templates whose product is an executable signed with its
# own entitlements, an app or a command-line tool: both carry the app's GPU
# list. A tweak or a preference bundle is a library and runs with the
# entitlements of the process that loads it.
TEMPLATE_ENTITLEMENTS := $(wildcard $(ROOT_DIR)/Extensions/Development/wiki.qaq.apelin.dev.app/templates/*/Packaging/*.entitlements) \
	$(wildcard $(ROOT_DIR)/Extensions/Development/wiki.qaq.apelin.dev.cli/templates/*/Packaging/*.entitlements)
# The one App Group the app and the widget extension share; the snapshot's
# store names it too (Widgets/Shared/ChatWidgetSnapshot.swift).
APP_GROUP           := group.wiki.qaq.apelin
LAUNCH_DAEMON       := $(ROOT_DIR)/Packaging/$(DAEMON_ID).plist
# Every Swift source root, for the greps and the gates that read source.
SOURCE_ROOTS        := $(ROOT_DIR)/Apelin $(ROOT_DIR)/Apelind $(ROOT_DIR)/Shared $(ROOT_DIR)/Widgets $(ROOT_DIR)/Workers $(ROOT_DIR)/Packages/ApelinKit/Sources
# The shared package: `make harness` runs its tests on the Mac.
APELINKIT           := $(ROOT_DIR)/Packages/ApelinKit
SWIFTPM_SCRATCH     ?= $(APELINKIT)/.build
# ApelinToolHost links into apelind's session host; the harness builds it to
# typecheck apelind, in the scratch path its tests use below.
TOOLHOST            := $(ROOT_DIR)/Packages/ApelinToolHost
# The editor's text view and grammars, vendored (Packages/Runestone/README.md).
RUNESTONE           := $(ROOT_DIR)/Packages/Runestone
TOOLHOST_SCRATCH    ?= $(call package_scratch,ApelinToolHost)
IRISIN_SHIM_DIR     := $(ROOT_DIR)/Apelind/Vendor/IrisinExternalClient/CIrisinExternalXPC
# Every other standalone package under Packages/ (ApelinFormats,
# ApelinDiagnostics, ApelinAgent, ApelinToolHost, and any added later) has
# its tests run by `make harness` too, each in a scratch path of its own:
# its own .build by default, or <SWIFTPM_SCRATCH>-<name> when SWIFTPM_SCRATCH
# is given. Live and network tests stay off unless their variable is set.
# Runestone is UIKit and has no Mac build, so the harness skips it.
HARNESS_PACKAGES    := $(filter-out ApelinKit Runestone,$(notdir $(patsubst %/Package.swift,%,$(wildcard $(ROOT_DIR)/Packages/*/Package.swift))))
ifeq ($(origin SWIFTPM_SCRATCH),file)
package_scratch      = $(ROOT_DIR)/Packages/$(1)/.build
else
package_scratch      = $(SWIFTPM_SCRATCH)-$(1)
endif
# The extensions, packaged beside the IDE into build/Packages/: the four
# development extensions (data only) and the agent tool extensions (their
# own executables, the GPL assembler's corresponding source beside them).
PACKAGES_DIR        := $(ROOT_DIR)/build/Packages
SCHEMA_FIXTURES_CHECK := $(ROOT_DIR)/Documents/Schemas/Tools/check-fixtures.py
TEMPLATES_CHECK     := $(ROOT_DIR)/Extensions/Development/check-templates.py
EXTENSIONS_PACKAGER := $(ROOT_DIR)/Extensions/Development/package-extensions.sh
AGENT_TOOLS_BUILDER := $(ROOT_DIR)/Extensions/AgentTools/Disassembler/Scripts/build-agent-tools.sh
AGENT_TOOLS_SCRATCH ?= $(DERIVED_DATA)/AgentToolsSPM
# What the IDE's control recommends, in this order. Agent tool extensions
# are never recommended (some are GPL; the user installs them on purpose).
DEV_EXTENSIONS      := wiki.qaq.apelin.dev.app wiki.qaq.apelin.dev.tweak wiki.qaq.apelin.dev.cli wiki.qaq.apelin.dev.preferences
DEV_RECOMMENDS      := wiki.qaq.apelin.dev.app, wiki.qaq.apelin.dev.tweak, wiki.qaq.apelin.dev.cli, wiki.qaq.apelin.dev.preferences
# The worker packages' scratch paths, which the worker typechecks read.
APELIN_DIAGNOSTICS  := $(ROOT_DIR)/Packages/ApelinDiagnostics
DIAGNOSTICS_SCRATCH := $(call package_scratch,ApelinDiagnostics)
AGENT_SCRATCH       := $(call package_scratch,ApelinAgent)
# The oldest iOS the package claims. `check` refuses one in project.pbxproj.
IOS_DEPLOYMENT_FLOOR := $(shell sed -n 's/^[[:space:]]*IPHONEOS_DEPLOYMENT_TARGET[[:space:]]*=[[:space:]]*\([0-9.]*\).*/\1/p' "$(CONFIG_DIR)/Base.xcconfig")
# The oldest iPhoneOS SDK the app is linked against. The SDK, not the floor,
# picks how an iPhone Duo treats the app: linked against iOS 27.1 or later
# it runs edge to edge, its bars laid out vertically beside the content;
# against 27.0 it stays clear of the status bar's edge; against 26 or older
# it sits centred with empty space around it. `build` and `install-app`
# refuse an older SDK, and `_package` reads the SDK back from the app it
# ships. Pick the Xcode with xcode-select or DEVELOPER_DIR (AGENTS.md ▸
# Decisions ▸ The SDK tier).
IOS_SDK_TIER        := 27.1

# A device on the network or behind `iproxy $(DEVICE_PORT) 22`. Set
# DEVICE_PASSWORD empty to use an ssh key instead.
DEVICE_HOST         ?= 127.0.0.1
DEVICE_PORT         ?= 2333
DEVICE_USER         ?= mobile
DEVICE_PASSWORD     ?= alpine
# The vphone VM: VPHONE names it as vphone-launchpad does and its address is
# read from the guest; VPHONE_HOST gives the address instead. With neither,
# the one vphone that is running.
VPHONE              ?=
VPHONE_HOST         ?=
# What the device harness is told: the vphone, and DEVICE_HOST only when it
# was given, so the default loopback port never hides a running vphone.
DEVICE_TOOL_ENV      = VPHONE=$(call shell_word,$(VPHONE)) VPHONE_HOST=$(call shell_word,$(VPHONE_HOST)) \
	DEVICE_USER=$(call shell_word,$(DEVICE_USER)) DEVICE_PASSWORD=$(call shell_word,$(DEVICE_PASSWORD)) \
	$(if $(filter-out file,$(origin DEVICE_HOST)),DEVICE_HOST=$(call shell_word,$(DEVICE_HOST)) DEVICE_PORT=$(call shell_word,$(DEVICE_PORT)))
# `make device-test` runs this suite (Documents/Console/device-harness.json).
SUITE               ?= smoke

# OTHER_CFLAGS on the command line reaches the package targets too, which do
# not read Configuration/Base.xcconfig: BoringSSL (in apelin-agent, through
# swift-nio-ssl) spells __FILE__ in its error macros, and without the map
# every one is a derived-data path in the shipped binary. The vendored
# tree-sitter runtime (Packages/Runestone) asserts with __FILE__ the same
# way, from inside the repository.
XCODEBUILD := $(XCODEBUILD_WRAPPER) \
	-project "$(PROJECT)" \
	-scheme "$(SCHEME)" \
	-derivedDataPath "$(DERIVED_DATA)" \
	-skipMacroValidation \
	-skipPackagePluginValidation \
	CODE_SIGNING_ALLOWED=NO \
	CODE_SIGNING_REQUIRED=NO \
	CODE_SIGN_IDENTITY="" \
	CURRENT_PROJECT_VERSION="$(BUILD_NUMBER)" \
	OTHER_CFLAGS='$$(inherited) -ffile-prefix-map=$(DERIVED_DATA)=DerivedData -ffile-prefix-map=$(ROOT_DIR)=.'

ifeq ($(APP_VERSION),)
$(error MARKETING_VERSION is missing from Configuration/Version.xcconfig)
endif

shell_word = '$(subst ','\'',$(1))'

.PHONY: checklist sdk-tier all help print-version print-build-number print-deb-path set-version check format harness build _package deb deb-roothide deb-rootless deb-all deb-extensions deb-agent-tools template-archive install vphone install-app vphone-app device-status device-install device-test device-run clean

all: deb

help:
	@echo "Apelin:"
	@echo "  harness       Host tests on the Mac: RoothideRoot, ExecutableWatch, every package under Packages/, apelind and the workers typechecked"
	@echo "  check         Validate the project and packaging inputs (the checklist first)"
	@echo "  build         Build the unsigned Apelin.app and apelind for iPhoneOS (iOS $(IOS_SDK_TIER) SDK or later)"
	@echo "  deb           Build, ad-hoc sign and package the .deb (FLAVOR=$(FLAVOR))"
	@echo "  deb-roothide  Package for roothide (unprefixed, iphoneos-arm64e)"
	@echo "  deb-rootless  Package for a rootless bootstrap (/var/jb, iphoneos-arm64)"
	@echo "  deb-all       Both packages from one build, then every extension package"
	@echo "  deb-extensions  The four development extensions, roothide and rootless"
	@echo "  deb-agent-tools The agent tool extensions and the assembler's source archive"
	@echo "  install       Package for FLAVOR and update the installation on DEVICE_HOST:DEVICE_PORT"
	@echo "  vphone        Package roothide and update the installation on the vphone (VPHONE=<name>, or the one running)"
	@echo "  vphone-app    Build and put only Apelin.app over the vphone's installed one (no gates, harness or package)"
	@echo "  install-app   The same onto DEVICE_HOST:DEVICE_PORT"
	@echo "  device-status   What the vphone or device has installed, registered and running"
	@echo "  device-install  Install every built package (Apelin and its extensions) without building"
	@echo "  device-test     Run a suite of console scripts on it (SUITE=$(SUITE); Scripts/device.py list)"
	@echo "  device-run      Run console scripts by name (SCRIPT='i1-smoke terminal')"
	@echo "  Scripts/device.py --help covers the rest: call, out, open, kill-host, crashes, screenshot, logs, shell"
	@echo "  set-version   Write VERSION=x.y.z [BUILD=n] into Configuration/Version.xcconfig"
	@echo "  clean         Remove derived data and generated packages"

print-version:
	@echo "$(APP_VERSION)"

print-build-number:
	@echo "$(BUILD_NUMBER)"

print-deb-path:
	@echo "$(DEB_OUTPUT)"

set-version:
	@test -n "$(VERSION)" || { echo "usage: make set-version VERSION=1.2.3 [BUILD=42]" >&2; exit 64; }
	@"$(VERSION_APPLIER)" "$(VERSION)" $(BUILD)

checklist:
	@Scripts/check-checklist.sh CHECKLIST.md

# The selected Xcode's iPhoneOS SDK, against IOS_SDK_TIER.
sdk-tier:
	@sdk="$$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || true)"; \
	if [[ -z "$$sdk" || "$$(printf '%s\n%s\n' "$(IOS_SDK_TIER)" "$$sdk" | sort -V | head -n1)" != "$(IOS_SDK_TIER)" ]]; then \
		echo "error: the iPhoneOS SDK is $${sdk:-missing}; Apelin is linked against iOS $(IOS_SDK_TIER) or later: select Xcode $(IOS_SDK_TIER) or later with xcode-select or DEVELOPER_DIR" >&2; \
		exit 69; \
	fi; \
	echo "ok: iPhoneOS SDK $$sdk"

check harness vphone deb-extensions deb-agent-tools template-archive: checklist

# Swift sources as SwiftFormat writes them for Swift 6.2 (`.swiftformat`:
# vendored code, the templates and generated files are left alone).
format:
	@command -v swiftformat >/dev/null || { echo "error: swiftformat is required (install it with your preferred package manager)" >&2; exit 69; }
	swiftformat "$(ROOT_DIR)"

check:
	@command -v xcodebuild >/dev/null || { echo "error: xcodebuild is required" >&2; exit 69; }
	@command -v ldid >/dev/null || { echo "error: ldid is required (install it with your preferred package manager)" >&2; exit 69; }
	@command -v dpkg-deb >/dev/null || { echo "error: dpkg-deb is required (install it with your preferred package manager)" >&2; exit 69; }
	@test -d "$(PROJECT)" || { echo "error: Apelin.xcodeproj is missing" >&2; exit 66; }
	@for script in "$(DEB_PACKAGER)" "$(DEVICE_INSTALLER)" "$(VERSION_APPLIER)" "$(XCODEBUILD_WRAPPER)" \
		"$(LICENSE_COLLECTOR)" "$(ACCESSIBILITY_CHECK)" "$(STALE_STRINGS_CHECK)" "$(FORMAT_STRINGS_CHECK)" "$(TRANSLATIONS_CHECK)" \
		"$(CATALOG_KEYS_CHECK)" "$(SHELL_DELETES_CHECK)" \
		"$(SYMBOL_CHECK)" "$(RPATH_CHECK)" "$(SCHEMA_FIXTURES_CHECK)" "$(TEMPLATES_CHECK)" \
		"$(EXTENSIONS_PACKAGER)" "$(AGENT_TOOLS_BUILDER)" "$(DEVICE_TOOL)"; do \
		test -x "$$script" || { echo "error: $${script#$(ROOT_DIR)/} is not executable" >&2; exit 66; }; \
	done
	@for xcconfig in Version Base Development Release; do \
		test -f "$(CONFIG_DIR)/$$xcconfig.xcconfig" || { echo "error: Configuration/$$xcconfig.xcconfig is missing" >&2; exit 66; }; \
	done
	@[[ "$(APP_VERSION)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$$ ]] || { echo "error: MARKETING_VERSION must look like 1.2.3, got '$(APP_VERSION)'" >&2; exit 65; }
	@[[ "$(BUILD_NUMBER)" =~ ^[0-9]+$$ ]] || { echo "error: the build number must be an integer, got '$(BUILD_NUMBER)'" >&2; exit 65; }
	@[[ -n "$(IOS_DEPLOYMENT_FLOOR)" ]] || { echo "error: IPHONEOS_DEPLOYMENT_TARGET is missing from Configuration/Base.xcconfig" >&2; exit 65; }
	@objver="$$(sed -n 's/^[[:space:]]*objectVersion = \([0-9]*\);.*/\1/p' "$(PROJECT)/project.pbxproj")"; \
		[[ "$$objver" == "$(PROJECT_OBJECT_VERSION)" ]] || { echo "error: project.pbxproj objectVersion must stay $(PROJECT_OBJECT_VERSION), got '$$objver'" >&2; exit 65; }
	@! grep -nE '^[[:space:]]*(MARKETING_VERSION|CURRENT_PROJECT_VERSION|IPHONEOS_DEPLOYMENT_TARGET) =' "$(PROJECT)/project.pbxproj" \
		|| { echo "error: versions and the deployment target live in Configuration/*.xcconfig, not project.pbxproj — a target-level value shadows the xcconfig" >&2; exit 65; }
	@grep -qF 'collect-licenses.py' "$(PROJECT)/project.pbxproj" \
		|| { echo "error: the Collect Licenses build phase is missing from the Apelin target — Settings ▸ About ▸ Licenses would be empty" >&2; exit 65; }
	@test -f "$(ROOT_DIR)/Licenses/review.json" || { echo "error: Licenses/review.json is missing" >&2; exit 66; }
	@# Runestone is vendored source: the runtime and each grammar keep their
	@# upstream LICENSE beside them, and every LICENSE in the package has the
	@# same text in a Licenses/ folder, which the Licenses screen is built from.
	@for grammar in "$(RUNESTONE)"/Sources/TreeSitter*/; do \
		test -f "$$grammar/LICENSE" || { echo "error: $${grammar#$(ROOT_DIR)/} has no LICENSE beside it" >&2; exit 65; }; \
	done
	@for license in "$(RUNESTONE)/LICENSE" "$(RUNESTONE)"/Sources/*/LICENSE; do \
		found=; for notice in "$(ROOT_DIR)"/Licenses/*/LICENSE; do cmp -s "$$license" "$$notice" && { found=1; break; }; done; \
		[[ -n "$$found" ]] || { echo "error: $${license#$(ROOT_DIR)/} has no copy in Licenses/<name>/LICENSE — the Licenses screen would miss it" >&2; exit 65; }; \
	done
	@test -f "$(CONTROL_TEMPLATE)" || { echo "error: Debian control template is missing" >&2; exit 66; }
	@for script in postinst prerm postrm; do \
		sh -n "$(ROOT_DIR)/Packaging/DEBIAN/$$script" || { echo "error: Packaging/DEBIAN/$$script does not parse" >&2; exit 65; }; \
		[[ "$$(grep -c '$(DAEMON_ID)' "$(ROOT_DIR)/Packaging/DEBIAN/$$script")" == 1 ]] \
			|| { echo "error: Packaging/DEBIAN/$$script must name $(DAEMON_ID) exactly once, alone on its line" >&2; exit 65; }; \
	done
	@! grep -nE '[A-Za-z0-9_@]2>' "$(ROOT_DIR)"/Packaging/DEBIAN/* \
		|| { echo "error: a redirect is glued to the word before it above — launchctl would be handed '<label>2' and its errors would show" >&2; exit 65; }
	@python3 "$(ROOT_DIR)/Scripts/test-daemon-registration.py"
	@! grep -nw 'uicache' "$(ROOT_DIR)"/Packaging/DEBIAN/* \
		|| { echo "error: a maintainer hook calls uicache — uikittools' triggers register the app" >&2; exit 65; }
	@grep -qE '^Depends:.*firmware \(>= $(IOS_DEPLOYMENT_FLOOR)\).*uikittools.*launchctl' "$(CONTROL_TEMPLATE)" \
		|| { echo "error: control must depend on firmware (>= $(IOS_DEPLOYMENT_FLOOR)), uikittools and launchctl" >&2; exit 65; }
	@# The development extensions are recommended, never depended on, so a
	@# package manager that skips recommendations installs the IDE alone.
	@[[ "$$(sed -n 's/^Recommends: //p' "$(CONTROL_TEMPLATE)")" == "$(DEV_RECOMMENDS)" ]] \
		|| { echo "error: control must recommend exactly: $(DEV_RECOMMENDS)" >&2; exit 65; }
	@! grep -nE '^(Pre-Depends|Depends):.*wiki\.qaq\.apelin\.|^(Recommends|Suggests):.*agent-tools' "$(CONTROL_TEMPLATE)" \
		|| { echo "error: the IDE depends on an extension or recommends an agent tool (above)" >&2; exit 65; }
	@for extension in $(DEV_EXTENSIONS); do \
		test -f "$(ROOT_DIR)/Extensions/Development/$$extension/manifest.json" \
			|| { echo "error: control recommends $$extension, which Extensions/Development does not have" >&2; exit 66; }; \
	done
	@# Every deb names its package manager icon, one Pages serves from
	@# Documents/Site (Scripts/render-package-icons.py draws the extensions').
	@for control in "$(CONTROL_TEMPLATE)" "$(ROOT_DIR)"/Extensions/*/*/Packaging/*/control "$(ROOT_DIR)"/Extensions/Development/Packaging/*/control; do \
		icon="$$(sed -n 's#^Icon: https://owngoal-dev.github.io/Apelin/##p' "$$control")"; \
		[[ -n "$$icon" && -f "$(ROOT_DIR)/Documents/Site/$$icon" ]] \
			|| { echo "error: $${control#$(ROOT_DIR)/} has no Icon: a file in Documents/Site served by Pages" >&2; exit 65; }; \
	done
	@icon="$$(sed -n 's#.*"https://owngoal-dev.github.io/Apelin/\(icons/[^"]*\)".*#\1#p' "$(ROOT_DIR)/Packages/ApelinKit/Sources/ApelinEnvironment/Toolchain/ToolchainPackaging.swift")"; \
		[[ -n "$$icon" && -f "$(ROOT_DIR)/Documents/Site/$$icon" ]] \
			|| { echo "error: the toolchain deb's Icon is not a file in Documents/Site" >&2; exit 65; }
	@# The extension formats against their fixtures, and every development
	@# extension's manifest and templates; the Mac build of the templates is
	@# deb-extensions'.
	@python3 -I -B "$(SCHEMA_FIXTURES_CHECK)" >/dev/null
	@python3 -I -B "$(TEMPLATES_CHECK)" --no-build >/dev/null
	@# Every console script says what a device run needs, sets up and checks.
	@python3 -I -B "$(DEVICE_TOOL)" lint
	@plutil -lint "$(ENTITLEMENTS)" "$(DAEMON_ENTITLEMENTS)" "$(WIDGET_ENTITLEMENTS)" "$(LAUNCH_DAEMON)" $(WORKER_ENTITLEMENTS)
	@for entitlements in $(WORKER_ENTITLEMENTS); do \
		! /usr/libexec/PlistBuddy -c 'Print :wiki.qaq.apelin.client' "$$entitlements" >/dev/null 2>&1 \
			|| { echo "error: $${entitlements#$(ROOT_DIR)/} carries the client entitlement; workers reach the session host by socketpair only" >&2; exit 65; }; \
	done
	@"$(ROOT_DIR)/Scripts/check-gpu-entitlements.py" "$(ENTITLEMENTS)" $(TEMPLATE_ENTITLEMENTS)
	@"$(ROOT_DIR)/Scripts/check-launchd-paths.py" "$(LAUNCH_DAEMON)" --substituted-by "$(DEB_PACKAGER)"
	@# On demand (owner, 2026-10-16): launchd starts apelind for a message to
	@# its Mach service, and apelind exits itself once idle. RunAtLoad or
	@# KeepAlive would fight the idle exit — the scaffold's daemon was
	@# restarted, throttled, every few seconds that way.
	@for key in RunAtLoad KeepAlive AbandonProcessGroup; do \
		! /usr/libexec/PlistBuddy -c "Print :$$key" "$(LAUNCH_DAEMON)" >/dev/null 2>&1 \
			|| { echo "error: apelind is on demand; its launchd plist must not set $$key" >&2; exit 65; }; \
	done
	@[[ "$$(/usr/libexec/PlistBuddy -c 'Print :MachServices:wiki.qaq.apelin.service' "$(LAUNCH_DAEMON)")" == true ]] \
		|| { echo "error: the launchd plist must advertise wiki.qaq.apelin.service, which is what starts apelind" >&2; exit 65; }
	@[[ "$$(/usr/libexec/PlistBuddy -c 'Print :SoftResourceLimits:NumberOfFiles' "$(LAUNCH_DAEMON)")" == "10240" ]] \
		|| { echo "error: the daemon and its sessions require a 10240 soft file-descriptor limit" >&2; exit 65; }
	@[[ "$$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$(LAUNCH_DAEMON)")" == "@PREFIX@/usr/libexec/apelind" ]] \
		|| { echo "error: the launchd plist must start @PREFIX@/usr/libexec/apelind" >&2; exit 65; }
	@# One App Group, the same on the app and the widget extension and in the
	@# snapshot's store; the packager reads both back out of the signed binaries.
	@for entitlements in "$(ENTITLEMENTS)" "$(WIDGET_ENTITLEMENTS)"; do \
		[[ "$$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups' "$$entitlements" 2>/dev/null | sed -n 's/^ *\(group\.[^ ]*\)$$/\1/p')" == "$(APP_GROUP)" ]] \
			|| { echo "error: $${entitlements#$(ROOT_DIR)/} must carry exactly the App Group $(APP_GROUP)" >&2; exit 65; }; \
	done
	@grep -qF 'appGroup = "$(APP_GROUP)"' "$(ROOT_DIR)/Widgets/Shared/ChatWidgetSnapshot.swift" \
		|| { echo "error: ChatWidgetStore.appGroup must be $(APP_GROUP), the App Group both targets carry" >&2; exit 65; }
	@for key in wiki.qaq.apelin.client com.apple.private.security.no-sandbox platform-application com.apple.security.exception.mach-lookup.global-name; do \
		! /usr/libexec/PlistBuddy -c "Print :$$key" "$(WIDGET_ENTITLEMENTS)" >/dev/null 2>&1 \
			|| { echo "error: Packaging/ApelinWidgets.entitlements carries $$key; the widget extension stays sandboxed and unprivileged" >&2; exit 65; }; \
	done
	@test -f "$(XPC_SHIM_DIR)/module.modulemap" -a -f "$(XPC_SHIM_DIR)/shim.h" \
		|| { echo "error: Shared/XPCShim is missing — the XPC_TYPE_* macros are read through the CAppXPC module" >&2; exit 66; }
	@grep -qF 'SWIFT_INCLUDE_PATHS' "$(CONFIG_DIR)/Base.xcconfig" \
		|| { echo "error: Configuration/Base.xcconfig must add Shared/XPCShim to SWIFT_INCLUDE_PATHS" >&2; exit 65; }
	@# Naming the SDK's XPC macros in Swift links libswiftXPC.dylib, which an
	@# older iOS does not have: dyld kills the process before main. One path on
	@# every OS, so the floor stays honest whatever it is.
	@hits="$$(grep -rnE '\bXPC_(TYPE|ERROR|ARRAY_APPEND)[A-Z_0-9]*' --include='*.swift' $(SOURCE_ROOTS) "$(ROOT_DIR)/Tests" || true)"; \
	if [[ -n "$$hits" ]]; then \
		echo "error: an SDK XPC macro is named in Swift below — read it through AppXPC (Shared/Protocol/AppXPC.swift):" >&2; \
		echo "$$hits" >&2; \
		exit 65; \
	fi
	@hits="$$(grep -rnE 'NSLocalizedString|String\(localized: *"[A-Z0-9_]+"' --include='*.swift' $(SOURCE_ROOTS) || true)"; \
	if [[ -n "$$hits" ]]; then \
		echo "error: user-facing text is a String.LocalizationValue spelled out in English, never NSLocalizedString or a SHOUTING_KEY:" >&2; \
		echo "$$hits" >&2; \
		exit 65; \
	fi
	@hits="$$(grep -rnE 'UIImage\(named: *"AppIcon"' --include='*.swift' $(SOURCE_ROOTS) || true)"; \
	if [[ -n "$$hits" ]]; then \
		echo "error: the app icon is never looked up by name — draw the AppIconMark image set:" >&2; \
		echo "$$hits" >&2; \
		exit 65; \
	fi
	@hits="$$(grep -rnwE 'exit|_exit' --include='*.swift' "$(ROOT_DIR)/Apelin" | grep -vE '^[^:]+/QuietExit\.swift:|^[^:]+:[0-9]+:[[:space:]]*//' | grep -E '\b_?exit\(' || true)"; \
	if [[ -n "$$hits" ]]; then \
		echo "error: the app exits through QuietExit.run only:" >&2; \
		echo "$$hits" >&2; \
		exit 65; \
	fi
	@test ! -e "$(ROOT_DIR)/CLAUDE.md" || { echo "error: AGENTS.md is the only notes file; remove CLAUDE.md" >&2; exit 65; }
	@"$(ACCESSIBILITY_CHECK)" "$(ROOT_DIR)/Apelin"
	@# Discipline: keys Xcode cannot see stay `extractionState: manual`, pruned
	@# by hand with prune-xcstrings.py (Xcode closed, every source root
	@# passed). `stale` is what Xcode writes during a build and never survives.
	@"$(STALE_STRINGS_CHECK)" "$(ROOT_DIR)/Apelin" "$(ROOT_DIR)/Widgets"
	@"$(FORMAT_STRINGS_CHECK)" "$(ROOT_DIR)/Apelin" "$(ROOT_DIR)/Widgets"
	@"$(TRANSLATIONS_CHECK)" "$(ROOT_DIR)/Apelin" "$(ROOT_DIR)/Widgets"
	@"$(SYMBOL_CHECK)" "$(IOS_DEPLOYMENT_FLOOR)" $(SOURCE_ROOTS)
	@# An empty variable in a removed path removes from /, the bootstrap's
	@# root on roothide: every recursive rm checks its variables with :?.
	@"$(SHELL_DELETES_CHECK)" "$(ROOT_DIR)"

# The Mac half of "where things get tested": what can run without a device.
# RoothideRoot against libroothide's own name rule, ExecutableWatch against a
# real executable replaced, unlinked and rolled back the way dpkg does it,
# ApelinKit's tests (the wire, the worker channel, paths, projects against the
# schema fixtures, and the tweak template built end to end into both debs with
# Xcode's tools when the iPhoneOS SDK is there), the tests of every other
# package under Packages/ (HARNESS_PACKAGES; the diagnostics, log-reader and
# agent workers' logic among them), the rule that what the root processes
# link is system code, the session host's tests (the toolchain setup end to
# end among them: apelin-environment-harness, the real environment worker
# with a fake backend, against the install bridge and a fake irisind), and
# apelind and every worker typechecked for macOS —
# against the package scratch it imports — so a change that only compiles on
# iOS shows.
# Generated module maps for C targets are under out/ with swift-build (Xcode
# 27, which CI runs) and beside each C target's objects with the native build
# system (Xcode 26); module_flags passes both.
# A binary framework (libarchive, libgit2) is passed by its macOS slice in
# artifacts/, which both build systems unpack there. An editor's
# SourceKit-LSP keeps a second build in <scratch>/index-build with the same
# module maps; passing those too redefines every C module, so they are left
# out.
harness:
	@python3 -I -B "$(ROOT_DIR)/Tests/ToolchainAudit/test_inventory.py"
	@harness_dir="$$(mktemp -d /private/tmp/apelin-harness.XXXXXX)"; \
	trap 'rm -rf -- "$${harness_dir:?}"' EXIT; \
	xcrun --sdk macosx swiftc -swift-version 5 \
		"$(ROOT_DIR)/Shared/RoothideRoot.swift" \
		"$(ROOT_DIR)/Tests/RoothideRoot/main.swift" \
		-o "$$harness_dir/roothide-root" && \
	"$$harness_dir/roothide-root" && echo "ok: RoothideRoot" && \
	xcrun --sdk macosx swiftc -swift-version 5 \
		"$(ROOT_DIR)/Apelin/Interface/Chats/Messages/MessageImageLayout.swift" \
		"$(ROOT_DIR)/Tests/MessageImageLayout/main.swift" \
		-o "$$harness_dir/message-image-layout" && \
	"$$harness_dir/message-image-layout" && \
	xcrun --sdk macosx swiftc -swift-version 5 \
		"$(ROOT_DIR)/Apelin/Interface/Chats/Messages/TokenClimb.swift" \
		"$(ROOT_DIR)/Tests/TokenClimb/main.swift" \
		-o "$$harness_dir/token-climb" && \
	"$$harness_dir/token-climb" && \
	xcrun --sdk macosx swiftc -swift-version 5 -target arm64-apple-macos13.0 \
		"$(ROOT_DIR)/Apelin/Interface/Settings/Git/GitHubDeviceFlow.swift" \
		"$(ROOT_DIR)/Tests/GitHubDeviceFlow/main.swift" \
		-o "$$harness_dir/github-device-flow" && \
	"$$harness_dir/github-device-flow" && \
	xcrun --sdk macosx swiftc -swift-version 5 \
		"$(ROOT_DIR)/Apelin/Interface/Chats/Composer/ComposerDropPolicy.swift" \
		"$(ROOT_DIR)/Tests/ComposerDrop/main.swift" \
		-o "$$harness_dir/composer-drop" && \
	"$$harness_dir/composer-drop" && \
	xcrun --sdk macosx swiftc -swift-version 5 \
		"$(ROOT_DIR)/Apelin/Interface/Settings/Logs/JournalFiles.swift" \
		"$(ROOT_DIR)/Apelin/Interface/Settings/Logs/JournalLines.swift" \
		"$(ROOT_DIR)/Packages/ApelinKit/Sources/ApelinCore/LogText.swift" \
		"$(ROOT_DIR)/Packages/ApelinAgent/Sources/ApelinAgent/Journal/DiagnosticJournal.swift" \
		"$(ROOT_DIR)/Tests/Journal/main.swift" \
		-o "$$harness_dir/journal" && \
	"$$harness_dir/journal" && \
	xcrun --sdk macosx swiftc -swift-version 5 \
		"$(ROOT_DIR)/Apelin/Application/DeviceOwnerCheck.swift" \
		"$(ROOT_DIR)/Tests/DeviceOwnerCheck/main.swift" \
		-o "$$harness_dir/device-owner-check" && \
	"$$harness_dir/device-owner-check" && \
	xcrun --sdk macosx swiftc -swift-version 5 \
		"$(ROOT_DIR)/Packages/ApelinKit/Sources/ApelinCore/SkillFolder.swift" \
		"$(ROOT_DIR)/Tests/SkillFolder/main.swift" \
		-o "$$harness_dir/skill-folder" && \
	"$$harness_dir/skill-folder" && \
	xcrun --sdk macosx swiftc -swift-version 5 \
		"$(ROOT_DIR)/Widgets/Shared/ApelinLink.swift" \
		"$(ROOT_DIR)/Widgets/Shared/ChatWidgetSnapshot.swift" \
		"$(ROOT_DIR)/Apelin/Interface/Projects/RepositoryImport/RepositoryImportPlan.swift" \
		"$(ROOT_DIR)/Tests/ApelinLink/main.swift" \
		-o "$$harness_dir/apelin-link" && \
	"$$harness_dir/apelin-link" && \
	xcrun --sdk macosx swiftc -swift-version 5 \
		"$(ROOT_DIR)/Apelin/Application/ExecutableWatch.swift" \
		"$(ROOT_DIR)/Tests/ExecutableWatch/main.swift" \
		-o "$$harness_dir/executable-watch" && \
	for mode in unchanged remove immediate-remove replace dpkg rollback; do \
		cp -p "$$harness_dir/executable-watch" "$$harness_dir/$$mode" && "$$harness_dir/$$mode" "$$mode" \
			|| { echo "error: ExecutableWatch failed in mode $$mode" >&2; exit 1; }; \
	done && echo "ok: ExecutableWatch" && \
	swift test --package-path "$(APELINKIT)" --scratch-path "$(SWIFTPM_SCRATCH)" && echo "ok: ApelinKit tests" && \
	$(foreach package,$(HARNESS_PACKAGES),swift test --package-path "$(ROOT_DIR)/Packages/$(package)" --scratch-path "$(call package_scratch,$(package))" && echo "ok: $(package) tests" && ) \
	"$(ROOT_DIR)/Scripts/check-system-only.py" "$(APELINKIT)" --scratch-path "$(SWIFTPM_SCRATCH)" \
		--toolhost-scratch-path "$(TOOLHOST_SCRATCH)" --diagnostics-scratch-path "$(DIAGNOSTICS_SCRATCH)" && \
	swift build --package-path "$(TOOLHOST)" --scratch-path "$(TOOLHOST_SCRATCH)" --target ApelinToolHost \
		|| { echo "error: a harness step above failed" >&2; exit 1; }; \
	toolhost_modules=; \
	for candidate in "$(TOOLHOST_SCRATCH)/out/Products/Debug" "$(TOOLHOST_SCRATCH)/debug/Modules" "$(TOOLHOST_SCRATCH)/debug"; do \
		if [[ -e "$$candidate/ApelinToolHost.swiftmodule" ]]; then toolhost_modules="$$candidate"; break; fi; \
	done; \
	[[ -n "$$toolhost_modules" ]] || { echo "error: no ApelinToolHost.swiftmodule under $(TOOLHOST_SCRATCH)" >&2; exit 1; }; \
	module_flags() { \
		local scratch="$$1" candidate; \
		for candidate in "$$scratch/out/Products/Debug" "$$scratch/debug/Modules" "$$scratch/debug"; do \
			if [[ -e "$$candidate/ApelinProtocol.swiftmodule" ]]; then echo "-I $$candidate"; break; fi; \
		done; \
		{ find "$$scratch/out" -name '*.modulemap' -path '*GeneratedModuleMaps*' 2>/dev/null; \
		  find "$$scratch" -path '*/debug/*.build/module.modulemap' -not -path '*/out/*' -not -path '*/index-build/*' 2>/dev/null; \
		  find "$$scratch/checkouts" -name module.modulemap -not -path '*/Tests/*' 2>/dev/null; } \
			| sed 's/^/-Xcc -fmodule-map-file=/'; \
		find "$$scratch/artifacts" -type d -name '*.framework' -path '*/macos-*' -prune 2>/dev/null \
			| xargs -n1 dirname | sort -u | sed 's/^/-F /'; \
	}; \
	modules=; \
	for candidate in "$(SWIFTPM_SCRATCH)/out/Products/Debug" "$(SWIFTPM_SCRATCH)/debug/Modules" "$(SWIFTPM_SCRATCH)/debug"; do \
		if [[ -e "$$candidate/ApelinProtocol.swiftmodule" ]]; then modules="$$candidate"; break; fi; \
	done; \
	[[ -n "$$modules" ]] || { echo "error: no ApelinProtocol.swiftmodule under $(SWIFTPM_SCRATCH)" >&2; exit 1; }; \
	kit_flags="$$(module_flags "$(SWIFTPM_SCRATCH)")"; \
	"$(ROOT_DIR)/Scripts/test-chat-transcript.sh" "$$modules" && \
	"$(ROOT_DIR)/Scripts/test-onboarding.sh" "$$modules" && \
	xcrun --sdk macosx swiftc -swift-version 5 -typecheck -target arm64-apple-macos13.0 -I "$(XPC_SHIM_DIR)" -I "$(IRISIN_SHIM_DIR)" $$kit_flags -I "$$toolhost_modules" \
		$$(find "$(ROOT_DIR)/Shared/Protocol" "$(ROOT_DIR)/Apelind" -name '*.swift' | sort) "$(ROOT_DIR)/Shared/RoothideRoot.swift" && \
	echo "ok: apelind typechecks for macOS" && \
	swift build --package-path "$(APELINKIT)" --scratch-path "$(SWIFTPM_SCRATCH)" --product apelin-environment-harness && \
	environment_harness="$$(swift build --package-path "$(APELINKIT)" --scratch-path "$(SWIFTPM_SCRATCH)" --show-bin-path)/apelin-environment-harness" && \
	"$(ROOT_DIR)/Scripts/test-session-host.sh" "$$modules" "$$environment_harness" && echo "ok: session host tests (toolchain setup end to end included)" && \
	for worker in "$(ROOT_DIR)"/Workers/*/; do \
		flags="$$kit_flags"; \
		if grep -qE '^import (ApelinDiagnosticsWorker|ApelinLogReaderWorker)$$' "$$worker"*.swift; then flags="$$(module_flags "$(DIAGNOSTICS_SCRATCH)")"; fi; \
		if grep -qE '^import ApelinAgentWorker$$' "$$worker"*.swift; then flags="$$(module_flags "$(AGENT_SCRATCH)")"; fi; \
		xcrun --sdk macosx swiftc -swift-version 5 -typecheck -target arm64-apple-macos14.0 $$flags \
			$$(find "$$worker" -name '*.swift' | sort) \
			|| { echo "error: $${worker#$(ROOT_DIR)/} does not typecheck for macOS" >&2; exit 1; }; \
	done && echo "ok: the workers typecheck for macOS"

# The iPhoneOS build every package is made from, and the app's inner loop.
IOS_BUILD = XCBUILD_LABEL=build-ios $(XCODEBUILD) \
	-configuration "$(CONFIGURATION)" \
	-destination "$(DEVICE_DESTINATION)" \
	ARCHS=arm64 \
	ONLY_ACTIVE_ARCH=YES \
	ENABLE_DEBUG_DYLIB=NO \
	build

ifeq ($(SKIP_HARNESS),1)
build: sdk-tier check
else
build: sdk-tier check harness
endif
	$(IOS_BUILD)
	@# xcodebuild never merges what the compiler extracted into a catalog, so a
	@# new string is only there if someone put it there.
	@"$(CATALOG_KEYS_CHECK)" \
		"$(ROOT_DIR)/Apelin/Resources/Localizable.xcstrings" "$(TARGET_INTERMEDIATES)/Apelin.build" \
		"$(ROOT_DIR)/Widgets/Extension/Resources/Localizable.xcstrings" "$(TARGET_INTERMEDIATES)/ApelinWidgets.build"

# The packaging half of `deb`, without a build: CI and deb-all package one
# build twice through it.
_package:
	@sdk="$$(xcrun vtool -show-build "$(APP_BUNDLE)/Apelin" | awk '$$1 == "sdk" { print $$2; exit }')"; \
	if [[ -z "$$sdk" || "$$(printf '%s\n%s\n' "$(IOS_SDK_TIER)" "$$sdk" | sort -V | head -n1)" != "$(IOS_SDK_TIER)" ]]; then \
		echo "error: Apelin.app is linked against the iOS $${sdk:-unknown} SDK, older than $(IOS_SDK_TIER); build it again with Xcode $(IOS_SDK_TIER) or later" >&2; \
		exit 65; \
	fi
	CONFIGURATION="$(CONFIGURATION)" "$(DEB_PACKAGER)" \
		"$(APP_BUNDLE)" \
		"$(DAEMON_BINARY)" \
		"$(CONTROL_TEMPLATE)" \
		"$(ENTITLEMENTS)" \
		"$(DAEMON_ENTITLEMENTS)" \
		"$(LAUNCH_DAEMON)" \
		"$(DEB_OUTPUT)" \
		"$(PACKAGE_ID)" \
		"$(APP_VERSION)" \
		"$(PACKAGE_ARCHITECTURE)" \
		"$(PACKAGE_PREFIX)" \
		"$(FLAVOR)" \
		"$(PRODUCTS_DIR)"

deb: build
	@$(MAKE) --no-print-directory _package FLAVOR="$(FLAVOR)" BUILD_NUMBER="$(BUILD_NUMBER)"

deb-roothide:
	@$(MAKE) --no-print-directory FLAVOR=roothide deb

deb-rootless:
	@$(MAKE) --no-print-directory FLAVOR=rootless deb

# Both layouts share the build; only the packaging step differs. Then every
# extension package, each with its own id and version, into the same folder.
deb-all: build
	@$(MAKE) --no-print-directory _package FLAVOR=roothide BUILD_NUMBER="$(BUILD_NUMBER)"
	@$(MAKE) --no-print-directory _package FLAVOR=rootless BUILD_NUMBER="$(BUILD_NUMBER)"
	@$(MAKE) --no-print-directory deb-extensions deb-agent-tools template-archive

# The four development extensions, roothide and rootless: data only, each
# template built on the Mac with the iPhoneOS SDK first, and every package
# read back and verified.
template-archive:
	python3 "$(ROOT_DIR)/Scripts/package-templates.py" --version "$(APP_VERSION)" --output "$(ROOT_DIR)/build/Packages"

deb-extensions:
	"$(EXTENSIONS_PACKAGER)" "$(PACKAGES_DIR)" roothide rootless

# The agent tool extensions, built for iPhoneOS with SwiftPM, packaged per
# layout and verified; the GPL assembler's corresponding-source archive is
# written beside its debs and ships wherever they do.
deb-agent-tools:
	SCRATCH_PATH="$(AGENT_TOOLS_SCRATCH)" "$(AGENT_TOOLS_BUILDER)" "$(PACKAGES_DIR)"

# Updates an existing installation; the first one still goes through the
# device's package manager. Confirm the payload and the launch: a locked
# device can accept an installation while refusing to open the app.
install: deb
	@DEVICE_HOST=$(call shell_word,$(DEVICE_HOST)) DEVICE_PORT=$(call shell_word,$(DEVICE_PORT)) \
	DEVICE_USER=$(call shell_word,$(DEVICE_USER)) DEVICE_PASSWORD=$(call shell_word,$(DEVICE_PASSWORD)) \
	"$(DEVICE_INSTALLER)" "$(DEB_OUTPUT)" --launch

# The vphone VM is roothide and answers ssh on its own address, which the
# harness reads from the guest when only its name (or nothing) is given.
vphone:
	@host=$(call shell_word,$(VPHONE_HOST)); \
	if [[ -z "$$host" ]]; then host="$$(VPHONE=$(call shell_word,$(VPHONE)) DEVICE_HOST= "$(DEVICE_TOOL)" address)" || exit 69; fi; \
	$(MAKE) --no-print-directory install FLAVOR=roothide DEVICE_HOST="$$host" DEVICE_PORT=22

# The inner loop while working on the app: no gates, no harness, no
# package. The same build, incremental, then only Apelin.app goes over the
# installed one, signed as the packager signs it. The daemon, the workers
# and dpkg's record stay as the last package left them: a change outside the
# app, and anything that ships, goes through `make vphone`.
install-app: sdk-tier
	$(IOS_BUILD)
	@DEVICE_HOST=$(call shell_word,$(DEVICE_HOST)) DEVICE_PORT=$(call shell_word,$(DEVICE_PORT)) \
	DEVICE_USER=$(call shell_word,$(DEVICE_USER)) DEVICE_PASSWORD=$(call shell_word,$(DEVICE_PASSWORD)) \
	"$(DEVICE_INSTALLER)" --app "$(APP_BUNDLE)" --launch

vphone-app:
	@host=$(call shell_word,$(VPHONE_HOST)); \
	if [[ -z "$$host" ]]; then host="$$(VPHONE=$(call shell_word,$(VPHONE)) DEVICE_HOST= "$(DEVICE_TOOL)" address)" || exit 69; fi; \
	$(MAKE) --no-print-directory install-app FLAVOR=roothide DEVICE_HOST="$$host" DEVICE_PORT=22

# The device half of "where things get tested", against what is installed:
# nothing here builds. `make vphone` (or device-install after deb-all) first.
device-status:
	@$(DEVICE_TOOL_ENV) "$(DEVICE_TOOL)" status

device-install:
	@$(DEVICE_TOOL_ENV) "$(DEVICE_TOOL)" install --all

device-test:
	@$(DEVICE_TOOL_ENV) "$(DEVICE_TOOL)" suite $(call shell_word,$(SUITE))

device-run:
	@test -n "$(SCRIPT)" || { echo "usage: make device-run SCRIPT='i1-smoke terminal'" >&2; exit 64; }
	@$(DEVICE_TOOL_ENV) "$(DEVICE_TOOL)" run $(SCRIPT)

clean:
	@test -n "$(DERIVED_DATA)" && test -n "$(ROOT_DIR)" \
		|| { echo "error: DERIVED_DATA and ROOT_DIR must name folders; refusing to remove anything" >&2; exit 64; }
	rm -rf -- "$(DERIVED_DATA)"
	rm -rf -- "$(ROOT_DIR)/build/Packages"
