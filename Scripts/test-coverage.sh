#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/sidepulse-tests.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
export SIDEPULSE_USER_HOME="$work/home" SIDEPULSE_SWIFT_HOME="$work/settings"
export XDG_CONFIG_HOME="$work/config" XDG_STATE_HOME="$work/state"
swift test --enable-code-coverage -Xcc -fprofile-instr-generate -Xcc -fcoverage-mapping
bin=$(swift build --show-bin-path)
export LLVM_PROFILE_FILE="$work/cli-%m-%p.profraw"
python3 Tests/Integration/cli.py "$bin/sidepulsectl"
python3 Tests/Integration/disk-image.py "$bin/sidepulsectl"
python3 Tests/Integration/disk-support-test.py
python3 Tests/Integration/eject-guard.py "$bin/sidepulsectl"
if [[ "${RUN_INSTALLED_TESTS:-0}" == 1 ]]; then
  python3 Scripts/test-installed.py "$bin" "$work"
fi
unset LLVM_PROFILE_FILE
classifier_binary=""
if [[ "${RUN_CLASSIFIER_TESTS:-0}" == 1 ]]; then
  Scripts/test-classifier.sh
  classifier_binary="$PWD/.build/classifier/Build/Products/Debug/sidepulse-classifier"
  LLVM_PROFILE_FILE="$work/classifier-%m-%p.profraw" python3 Tests/Integration/classifier.py "$classifier_binary" "$bin/sidepulsectl"
fi
report=.build/coverage-report
mkdir -p "$report"
profiles=("$bin/codecov/default.profdata" "$work"/*.profraw)
if [[ -n "$classifier_binary" ]]; then
  while IFS= read -r profile; do profiles+=("$profile"); done < <(find .build/classifier/Build/ProfileData -name Coverage.profdata)
fi
if [[ "${RUN_UI_TESTS:-0}" == 1 ]]; then
  Scripts/test-ui.sh
  profiles+=(".build/ui-tests/coverage.profdata")
fi
xcrun llvm-profdata merge -sparse "${profiles[@]}" -o "$report/all.profdata"
testbinary=""
for candidate in "$bin"/*.xctest/Contents/MacOS/*; do
  if [[ -f "$candidate" && -x "$candidate" ]]; then testbinary="$candidate"; break; fi
done
test -n "$testbinary"
# SwiftPM names the XCTest binary differently between the Xcode and native build systems.
coverage=("$testbinary" -object "$bin/SidePulse" -object "$bin/sidepulsectl" -instr-profile "$report/all.profdata")
if [[ -n "$classifier_binary" ]]; then
  coverage+=(-object "$classifier_binary")
  while IFS= read -r object; do coverage+=(-object "$object"); done < <(find .build/classifier/Build/Products/Debug -path '*.xctest/Contents/MacOS/*' -type f)
fi
sources=()
while IFS= read -r source; do sources+=("$PWD/$source"); done < <(find Sources \( -name '*.swift' -o -name '*.c' \) | sort)
if [[ -n "$classifier_binary" ]]; then
  while IFS= read -r source; do sources+=("$PWD/$source"); done < <(find Classifier/Sources -name '*.swift' | sort)
else
  echo 'MLX helper not included; set RUN_CLASSIFIER_TESTS=1 for complete production coverage.'
fi
xcrun llvm-cov export "${coverage[@]}" -sources "${sources[@]}" > "$report/coverage.json"
xcrun llvm-cov show "${coverage[@]}" -format=html -output-dir="$report/html" -sources "${sources[@]}"
python3 - "$report/coverage.json" "${MIN_COVERAGE:-0}" "${sources[@]}" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())["data"][0]
files = {f["filename"] for f in data["files"]}
missing = set(sys.argv[3:]) - files
assert not missing, f"Sources absent from coverage: {missing}"
for f in data["files"]:
    lines = f["summary"]["lines"]
    print(f'{Path(f["filename"]).name:25} {lines["covered"]:4}/{lines["count"]:<4} {lines["percent"]:6.2f}%')
lines = data["totals"]["lines"]
print(f'Measured production sources: {lines["covered"]}/{lines["count"]} lines ({lines["percent"]:.2f}%)')
minimum = float(sys.argv[2])
if (minimum == 100 and lines["covered"] != lines["count"]) or lines["percent"] < minimum:
    raise SystemExit("Coverage below required minimum of " + sys.argv[2] + "%")
PY
