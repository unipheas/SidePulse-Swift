#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo 'Install XcodeGen to generate the UI test host: brew install xcodegen' >&2; exit 1; }
stage=$(mktemp -d "${TMPDIR:-/tmp}/sidepulse-ui.XXXXXXXX")
finish() {
  if [[ -d "$stage/result.xcresult" ]]; then
    rm -rf .build/ui-tests/results.xcresult
    cp -R "$stage/result.xcresult" .build/ui-tests/results.xcresult
  fi
  registrar=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  for app in "$stage/build/Build/Products/Debug/SidePulse.app" "$stage/build/Build/Products/Debug/SidePulseUITests-Runner.app"; do
    if [[ -d "$app" ]]; then "$registrar" -u "$app" || true; fi
  done
  rm -rf "$stage"
}
trap finish EXIT
mkdir -p .build/ui-tests
xcodegen generate
# Build outside Documents so Finder metadata cannot invalidate the test runner signature.
xcodebuild -project SidePulse.xcodeproj -scheme SidePulse -destination 'platform=macOS' \
  -derivedDataPath "$stage/build" -resultBundlePath "$stage/result.xcresult" test "$@"
profiles=()
while IFS= read -r path; do profiles+=("$path"); done < <(find "$stage/build/Build/ProfileData" -name Coverage.profdata)
test "${#profiles[@]}" -gt 0
xcrun llvm-profdata merge -sparse "${profiles[@]}" -o .build/ui-tests/coverage.profdata
xcrun xccov view --report --json "$stage/result.xcresult" > .build/ui-tests/coverage.json
