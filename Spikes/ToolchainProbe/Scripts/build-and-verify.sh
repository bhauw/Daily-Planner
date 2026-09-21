#!/bin/zsh
set -euo pipefail

probe_root="${0:A:h:h}"
build_root="$probe_root/.build"
app="$build_root/ToolchainProbe.app"
binary="$app/Contents/MacOS/ToolchainProbe"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
target_arch="$(uname -m)"

rm -rf "$build_root"
mkdir -p "$app/Contents/MacOS"

xcrun swiftc \
  -parse-as-library \
  -sdk "$sdk_path" \
  -target "${target_arch}-apple-macos15.0" \
  -framework SwiftUI \
  -o "$binary" \
  "$probe_root/Sources/ToolchainProbeApp/main.swift"

cp "$probe_root/Resources/Info.plist" "$app/Contents/Info.plist"
xattr -cr "$app"
xattr -c "$app"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
