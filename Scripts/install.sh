#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source="$PWD/dist/SidePulse.app"
target=/Applications/SidePulse.app
registrar=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -d "$source" ]] || { echo 'Build first with Scripts/package.sh --universal.' >&2; exit 1; }
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source/Contents/Info.plist")
[[ "$identifier" == com.unipheas.SidePulseSwift ]] || { echo 'Unexpected application identifier.' >&2; exit 1; }
stage=$(mktemp -d /Applications/.SidePulse-install.XXXXXXXX)
trap 'rm -rf "$stage"' EXIT
ditto --norsrc --noextattr "$source" "$stage/SidePulse.app"
codesign --verify --deep --strict "$stage/SidePulse.app"
if [[ -d "$target" ]]; then
  installed=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist")
  [[ "$installed" == "$identifier" ]] || { echo 'Another application occupies the install location.' >&2; exit 1; }
  backup="$HOME/Library/Application Support/SidePulse/Backups"
  mkdir -p "$backup"
  chmod 700 "$backup"
  ditto -c -k --norsrc --noextattr --keepParent "$target" "$backup/SidePulse-$(date +%Y%m%d-%H%M%S).zip"
  if pgrep -f '^/Applications/SidePulse.app/Contents/MacOS/SidePulse$' >/dev/null; then
    osascript -e 'tell application id "com.unipheas.SidePulseSwift" to quit'
  fi
  "$registrar" -u "$target"
  mv "$target" "$stage/previous.app"
fi
if ! mv "$stage/SidePulse.app" "$target"; then
  if [[ -d "$stage/previous.app" ]]; then mv "$stage/previous.app" "$target"; fi
  exit 1
fi
"$registrar" -f "$target"
mdimport "$target"
for name in service sdejectguard; do
  job="gui/$(id -u)/com.unipheas.SidePulseSwift.$name"
  if launchctl print "$job" >/dev/null 2>&1; then launchctl kickstart -k "$job"; fi
done
mkdir -p "$HOME/.local/bin"
if [[ ! -e "$HOME/.local/bin/sidepulsectl" || -L "$HOME/.local/bin/sidepulsectl" ]]; then
  ln -sfn "$target/Contents/MacOS/sidepulsectl" "$HOME/.local/bin/sidepulsectl"
fi
# Keep the distributable ZIP; do not leave another indexed .app in the checkout.
"$registrar" -u "$source" >/dev/null 2>&1 || true
rm -rf "$source"
printf 'Installed %s\n' "$target"
