#!/bin/zsh
# audit-objc-selectors.sh <products folder> [--baseline <products folder>]
#
# Every member of Apelin's own classes that Objective-C can represent is
# `@objc dynamic` (AGENTS.md ▸ Hard rules), so a tweak can hook it. Run this
# after adding classes or members, on the iPhoneOS products a build left
# (`$(DERIVED_DATA)/Build/Products/Release-iphoneos`): it reads the Objective-C
# metadata of Apelin.app, its extensions, apelind and the workers, and reports
# each selector of ours that an Apple superclass already answers (an override
# the source never declared), the selectors the runtime, ARC or UIKit's edit
# menu call by name, the optional delegate or data source selectors answered
# by accident, an override in a final class of our own member left without
# `dynamic`, and our category methods on Apple classes (audit-objc-selectors.py
# says how each is decided). With `--baseline`, the products of an earlier
# build, a finding the class did not have there is marked NEW.
#
# A packaged binary is stripped: put its dSYM beside it (`apelind.dSYM`,
# `Apelin.app.dSYM`, as the products folder and CI's `*_dSYMs.zip` hold them),
# which is used only when its UUID is the binary's. Without one the audit
# stops, since an override cannot be told from a collision by name alone.
#
# The Apple side comes from audit-objc-selectors-probe.m, built here for Mac
# Catalyst and run once: Catalyst's UIKitCore carries iOS UIKit's private
# methods closely enough. The edit actions come from UIResponder.h in the
# iPhoneOS SDK (IOS_DEVELOPER_DIR, default the Xcode that carries the 27.1 SDK
# when it is installed, else the selected one). Not part of `make check`.
#
# Exit 0 clean, 1 with findings, 2 when the audit could not run.

set -euo pipefail
scripts=${0:A:h}
root=${scripts:h}
products=${1:?usage: audit-objc-selectors.sh <products folder> [--baseline <products folder>]}
products=${products:A}
shift
baseline=()
if (( $# )); then
  [[ $1 == --baseline && -n ${2:-} ]] || { print -u2 "usage: audit-objc-selectors.sh <products folder> [--baseline <products folder>]"; exit 2; }
  baseline=(--baseline-dir ${2:A})
fi

binaries=()
for app in $products/*.app(N/); do
  executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' $app/Info.plist 2>/dev/null) || continue
  binaries+=($app/$executable)
  for appex in $app/PlugIns/*.appex(N/); do
    executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' $appex/Info.plist 2>/dev/null) || continue
    binaries+=($appex/$executable)
  done
done
for candidate in $products/apelind(N.) $products/apelin-*(N.); do
  [[ $candidate == *.* ]] && continue
  [[ $(file -b $candidate) == *Mach-O*executable* ]] && binaries+=($candidate)
done
(( ${#binaries} )) || { print -u2 "error: no Apelin executables under $products"; exit 2; }

developer=${IOS_DEVELOPER_DIR:-}
if [[ -z $developer && -d $HOME/Applications/Xcode_27.0-sdk27.1.app ]]; then
  developer=$HOME/Applications/Xcode_27.0-sdk27.1.app/Contents/Developer
fi
ios_sdk=$(DEVELOPER_DIR=${developer:-$(xcode-select -p)} xcrun --sdk iphoneos --show-sdk-path)
responder_header=$ios_sdk/System/Library/Frameworks/UIKit.framework/Headers/UIResponder.h
[[ -f $responder_header ]] || { print -u2 "error: no UIResponder.h in $ios_sdk"; exit 2; }

work=$(mktemp -d /private/tmp/apelin-objc-audit.XXXXXX)
trap 'rm -rf -- "${work:?}"' EXIT

mac_sdk=$(xcrun --sdk macosx --show-sdk-path)
catalyst=$mac_sdk/System/iOSSupport/System/Library/Frameworks
frameworks=(Foundation UIKit QuartzCore QuickLook WebKit SafariServices PhotosUI AVKit UserNotifications)
framework_flags=()
for framework in $frameworks; do framework_flags+=(-framework $framework); done
xcrun --sdk macosx clang -target arm64-apple-ios18.0-macabi -isysroot $mac_sdk \
  -iframework $catalyst -F $catalyst -fobjc-arc $framework_flags \
  $scripts/audit-objc-selectors-probe.m -o $work/probe

python3 -I -B $scripts/audit-objc-selectors.py externals $binaries > $work/externals
# The system libraries the binaries link, so their categories are in the probe.
libraries=(${(f)"$(for binary in $binaries; do otool -L $binary | tail -n +2 | awk '{print $1}'; done | grep -E '^/(System|usr/lib)/' | sort -u)"})
$work/probe ${libraries/#/+} ${(f)"$(<$work/externals)"} > $work/apple
if grep -q '^MISSING' $work/apple; then
  print -u2 "error: the probe found no class named $(grep '^MISSING' $work/apple | cut -f2 | tr '\n' ' ')— add its framework to \`frameworks\` in $0"
  exit 2
fi
print "Apple classes probed: $(grep -c '^S' $work/apple), selectors: $(grep -cE '^(I|C)	' $work/apple)," \
  "libraries loaded: $(( ${#libraries} - $(grep -c '^UNLOADED' $work/apple) )) of ${#libraries}"

python3 -I -B $scripts/audit-objc-selectors.py audit --probe $work/apple --responder-header $responder_header \
  --source-root $root --products $products $baseline $binaries
