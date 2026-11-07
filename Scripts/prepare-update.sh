#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
archive="${1:-dist/SidePulse-macOS.zip}"
destination="${2:-.build/update-feed}"
account="${SPARKLE_KEYCHAIN_ACCOUNT:-com.unipheas.SidePulseSwift}"
tools="$PWD/.build/artifacts/sparkle/Sparkle/bin"
test -f "$archive"
test -x "$tools/generate_appcast"
stage=$(mktemp -d "${TMPDIR:-/tmp}/sidepulse-update.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
unzip -p "$archive" SidePulse.app/Contents/Info.plist > "$stage/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$stage/Info.plist")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Expected a semantic app version.' >&2; exit 1; }
mkdir "$stage/archives"
cp "$archive" "$stage/archives/SidePulse-macOS.zip"
signature=$("$tools/sign_update" --account "$account" -p "$stage/archives/SidePulse-macOS.zip")
"$tools/sign_update" --account "$account" --verify "$stage/archives/SidePulse-macOS.zip" "$signature"
"$tools/generate_appcast" --account "$account" \
  --download-url-prefix "https://github.com/unipheas/SidePulse-Swift/releases/download/v$version/" \
  "$stage/archives"
mkdir -p "$destination"
cp "$stage/archives/appcast.xml" "$destination/appcast.xml"
shasum -a 256 "$archive" > "$destination/SHA256SUMS.txt"
printf 'Prepared signed feed: %s/appcast.xml\n' "$destination"
printf 'Release archive: %s\n' "$archive"
