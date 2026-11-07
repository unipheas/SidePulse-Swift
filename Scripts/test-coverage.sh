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
unset LLVM_PROFILE_FILE
report=.build/coverage-report
mkdir -p "$report"
xcrun llvm-profdata merge -sparse "$bin/codecov/default.profdata" "$work"/*.profraw -o "$work/all.profdata"
testbinary=""
for candidate in "$bin"/*.xctest/Contents/MacOS/*; do
  if [[ -f "$candidate" && -x "$candidate" ]]; then testbinary="$candidate"; break; fi
done
test -n "$testbinary"
# SwiftPM names the XCTest binary differently between the Xcode and native build systems.
coverage=("$testbinary" -object "$bin/SidePulse" -object "$bin/sidepulsectl" -instr-profile "$work/all.profdata")
sources=()
while IFS= read -r source; do sources+=("$PWD/$source"); done < <(find Sources \( -name '*.swift' -o -name '*.c' \) | sort)
xcrun llvm-cov export "${coverage[@]}" -summary-only -sources "${sources[@]}" > "$report/coverage.json"
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
print(f'All production sources: {lines["covered"]}/{lines["count"]} lines ({lines["percent"]:.2f}%)')
if lines["percent"] < float(sys.argv[2]):
    raise SystemExit("Coverage below required minimum of " + sys.argv[2] + "%")
PY
