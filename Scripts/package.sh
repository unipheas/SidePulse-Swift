#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
args=(-c release)
if [[ "${1:-}" == "--universal" ]]; then args+=(--arch arm64 --arch x86_64); fi
swift build "${args[@]}"
bin=$(swift build "${args[@]}" --show-bin-path)
mkdir -p "$PWD/dist"
stage=$(mktemp -d "$PWD/dist/.package.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/SidePulse.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$bin/SidePulse" "$bin/sidepulsectl" "$contents/MacOS/"
cp -R "$bin/SidePulseSwift_PulseCore.bundle" "$contents/Resources/"
cp LICENSE "$contents/Resources/LICENSE"
cp Artwork/SidePulse.icns "$contents/Resources/"
cp Artwork/Info.plist "$contents/"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$contents/MacOS/sidepulsectl"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
ditto -c -k --keepParent "$app" "$stage/SidePulse-macOS.zip"
if [[ -d "dist/SidePulse.app" ]]; then mv "dist/SidePulse.app" "$stage/previous.app"; fi
mv "$app" dist/
mv "$stage/SidePulse-macOS.zip" dist/
app="$PWD/dist/SidePulse.app"
printf '%s\n' "$app"
