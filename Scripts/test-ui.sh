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
# Keep the generated project outside Documents too: file coordination on a synced
# workspace can block Xcode before compilation. Source references stay in the repo.
python3 - "$PWD" "$stage" <<'PY'
import json, plistlib, sys
from pathlib import Path
root, stage = map(Path, sys.argv[1:])
spec = (root / "project.yml").read_text().replace("    path: .\n", "    path: " + json.dumps(str(root)) + "\n")
# Exercise URL routing and real Sparkle startup with isolated test metadata.
info = plistlib.loads((root / "Artwork/Info.plist").read_bytes())
info["CFBundleIdentifier"] = "com.unipheas.SidePulseSwift.UITestHost"
info["SUFeedURL"] = "https://127.0.0.1:9/fixture-appcast.xml"
info["SUEnableAutomaticChecks"] = False
info["SUAllowsAutomaticUpdates"] = False
info_path = stage / "HostInfo.plist"
info_path.write_bytes(plistlib.dumps(info))
spec = spec.replace("SIDEPULSE_UI_INFO_PLIST", json.dumps(str(info_path)))
(stage / "project.yml").write_text(spec)
PY
xcodegen generate --spec "$stage/project.yml" --project "$stage" --project-root "$PWD"
# Build outside Documents so Finder metadata cannot invalidate the test runner signature.
xcodebuild -project "$stage/SidePulse.xcodeproj" -scheme SidePulse -destination 'platform=macOS' \
  CC="$(xcrun --find clang)" CXX="$(xcrun --find clang++)" \
  -derivedDataPath "$stage/build" -resultBundlePath "$stage/result.xcresult" test "$@"
profiles=()
while IFS= read -r path; do profiles+=("$path"); done < <(find "$stage/build/Build/ProfileData" -name Coverage.profdata)
test "${#profiles[@]}" -gt 0
xcrun llvm-profdata merge -sparse "${profiles[@]}" -o .build/ui-tests/coverage.profdata
xcrun xccov view --report --json "$stage/result.xcresult" > .build/ui-tests/coverage.json
