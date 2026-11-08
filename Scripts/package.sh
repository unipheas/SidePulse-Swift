#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
args=(-c release)
if [[ "${1:-}" == "--universal" ]]; then args+=(--arch arm64 --arch x86_64); fi
swift build "${args[@]}"
bin=$(swift build "${args[@]}" --show-bin-path)
Scripts/build-classifier.sh
classifier="$PWD/.build/classifier/Build/Products/Release"
mkdir -p "$PWD/dist"
touch "$PWD/dist/.metadata_never_index"
stage=$(mktemp -d "${TMPDIR:-/tmp}/sidepulse-package.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/SidePulse.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp -X "$bin/SidePulse" "$bin/sidepulsectl" "$contents/MacOS/"
cp -X "$classifier/sidepulse-classifier" "$contents/MacOS/"
# MLX resolves its SwiftPM resource bundle from Contents/Resources. A raw
# .metallib beside the executables is incorrectly treated as nested code by codesign.
for resource in "$classifier"/*.bundle; do
  ditto --norsrc --noextattr "$resource" "$contents/Resources/$(basename "$resource")"
done
cp -X -R "$bin/SidePulseSwift_PulseCore.bundle" "$contents/Resources/"
mkdir -p "$contents/Frameworks"
framework="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto --norsrc --noextattr "$framework" "$contents/Frameworks/Sparkle.framework"
cp -X Scripts/sleep-helper.sh "$contents/Resources/"
cp -X LICENSE "$contents/Resources/LICENSE"
cp -X -R ThirdParty "$contents/Resources/ThirdParty"
for dependency in .build/classifier/SourcePackages/checkouts/*; do
  for notice in "$dependency"/LICENSE* "$dependency"/NOTICE*; do
    if [[ -f "$notice" ]]; then
      cp -X "$notice" "$contents/Resources/ThirdParty/$(basename "$dependency")-$(basename "$notice")"
    fi
  done
done
cp -X Artwork/SidePulse.icns "$contents/Resources/"
cp -X Artwork/Info.plist "$contents/"
identity="${CODESIGN_IDENTITY:--}"
sign=(codesign --force --sign "$identity")
if [[ "$identity" == "Developer ID Application:"* ]]; then
  sign+=(--options runtime --timestamp)
  # Sign embedded Sparkle code inside out with the application's team, retaining
  # the official helper entitlements. Do not use --deep to create signatures.
  sparkle="$contents/Frameworks/Sparkle.framework"
  for helper in "$sparkle/Versions/B/XPCServices/Downloader.xpc" \
    "$sparkle/Versions/B/XPCServices/Installer.xpc" \
    "$sparkle/Versions/B/Updater.app" "$sparkle/Versions/B/Autoupdate"; do
    "${sign[@]}" --preserve-metadata=entitlements "$helper"
  done
  "${sign[@]}" "$sparkle"
fi
"${sign[@]}" "$contents/MacOS/sidepulse-classifier"
"${sign[@]}" "$contents/MacOS/sidepulsectl"
"${sign[@]}" "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --norsrc --noextattr --keepParent "$app" "$stage/SidePulse-macOS.zip"
if [[ -d "dist/SidePulse.app" ]]; then mv "dist/SidePulse.app" "$stage/previous.app"; fi
mv "$app" dist/
mv "$stage/SidePulse-macOS.zip" dist/
app="$PWD/dist/SidePulse.app"
printf '%s\n' "$app"
