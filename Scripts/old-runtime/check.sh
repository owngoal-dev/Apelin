#!/bin/zsh
# Runs what iOS 26 cannot show on the oldest Swift runtime Apple hands out
# without an account. The vphones are iOS 26 and 27 and the Mac newer still,
# and on all of them `Data` through an @objc thunk costs nothing, so 0.3.6
# passed everything and then ran out of memory unpacking a toolchain on
# users' older devices.
#
# The runtime is never booted: a program built for the simulator runs against
# its libraries through DYLD_ROOT_PATH, so nothing here needs a GPU or a
# window. The first run downloads 5.4 GB and keeps about 4.5 GB in
# $APELIN_OLD_RUNTIME_CACHE (default ~/Library/Caches/apelin-old-runtime).
set -euo pipefail

here=${0:A:h}
repository=${here:h:h}
cache=${APELIN_OLD_RUNTIME_CACHE:-$HOME/Library/Caches/apelin-old-runtime}
image=https://devimages-cdn.apple.com/downloads/xcode/simulators/com.apple.pkg.iPhoneSimulatorSDK15_5-15.5.1.1653527639.dmg
target=arm64-apple-ios15.5-simulator
runtime=$cache/iOS-15.5
sources=$repository/Packages/ApelinToolchain/Sources
build=$(mktemp -d "${TMPDIR:-/tmp}/apelin-old-runtime.XXXXXX")
home=$build/home
mount=$build/image
cleanup() {
  hdiutil detach -quiet "$mount" 2>/dev/null || true
  rm -rf -- "${build:?}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$cache" "$home/tmp" "$home/logs"

if [[ ! -e $runtime/usr/lib/dyld_sim ]]; then
  print "Fetching the iOS 15.5 runtime (5.4 GB)"
  rm -rf -- "${runtime:?}.partial"
  curl -fsSL --retry 3 -o "$cache/runtime.dmg" "$image"
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$cache/runtime.dmg"
  python3 -I "$here/runtime-root.py" "$mount"/*.pkg "$runtime.partial"
  mv "$runtime.partial" "$runtime"
  hdiutil detach -quiet "$mount" || true
  rm -f -- "${cache:?}/runtime.dmg"
fi

# The newest reviewed package, the smallest of them to unpack.
address=$(sed -n 's/.*url: "\(https:[^"]*\)".*/\1/p' "$sources/ApelinToolchain/Support.swift" | head -1)
package=$cache/${${address:h:h:t}%%-A_*}.pkg
if [[ ! -s $package ]]; then
  print "Fetching $address"
  curl -fsSL --retry 3 -o "$package.part" "$address"
  mv "$package.part" "$package"
fi

sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
swiftc=(xcrun --sdk iphonesimulator swiftc -target "$target" -sdk "$sdk" -swift-version 5 -O -wmo)
cp "$here/BridgeCheck.swift" "$build/main.swift"
mkdir "$build/extract"
cp "$here/ExtractCheck.swift" "$build/extract/main.swift"
xcrun --sdk iphonesimulator clang -target "$target" -isysroot "$sdk" \
  -I "$sources/CToolchainSystem/include" -c "$sources/CToolchainSystem/system.c" -o "$build/system.o"
mkdir "$build/modules"
cp "$sources/CToolchainSystem/include/CToolchainSystem.h" "$build/modules/"
print 'module CToolchainSystem { header "CToolchainSystem.h" export * }' > "$build/modules/module.modulemap"
"${swiftc[@]}" "$build/main.swift" -o "$build/bridge-check"
"${swiftc[@]}" -module-name ApelinCodeSign -parse-as-library -emit-library -static -emit-module \
  -emit-module-path "$build/modules/ApelinCodeSign.swiftmodule" -o "$build/libApelinCodeSign.a" \
  "$repository"/Packages/ApelinFormats/Sources/ApelinCodeSign/*.swift
"${swiftc[@]}" -module-name ApelinToolchain -I "$build/modules" -Xcc "-I$build/modules" \
  "$sources"/ApelinToolchain/*.swift "$build/extract/main.swift" "$build/system.o" \
  "$build/libApelinCodeSign.a" -lz -o "$build/extract-check"

# What launchd_sim gives a process; libsystem_trace stops without them.
simulated=(
  DYLD_ROOT_PATH="$runtime" SIMULATOR_ROOT="$runtime" IPHONE_SIMULATOR_ROOT="$runtime"
  SIMULATOR_RUNTIME_VERSION=15.5 SIMULATOR_RUNTIME_BUILD_VERSION=19F70 SIMULATOR_VERSION_INFO=check
  SIMULATOR_SHARED_RESOURCES_DIRECTORY="$home" SIMULATOR_LOG_ROOT="$home/logs" SIMULATOR_HOST_HOME="$HOME"
  SIMULATOR_UDID=00000000-0000-0000-0000-000000000000 SIMULATOR_MODEL_IDENTIFIER=iPhone14,5
  SIMULATOR_DEVICE_NAME=check HOME="$home" CFFIXED_USER_HOME="$home" TMPDIR="$home/tmp"
)
env "${simulated[@]}" "$build/bridge-check"
env "${simulated[@]}" "$build/extract-check" "$package" "$build/extracted"
print "The old runtime passed."
