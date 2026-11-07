#!/usr/bin/env python3
"""Merge explicit installed-app acceptance into a complete coverage measurement.

Usage: Scripts/merge-install-coverage.py BASE.profdata ACCEPTANCE_DIRECTORY
The directory must contain profraw files and sources.json, a mapping from every
production source path to its SHA-256 digest at the time of acceptance. This tool
does not install software, stop jobs, change settings, or operate devices.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
if len(sys.argv) != 3:
    raise SystemExit(__doc__)
baseline = Path(sys.argv[1]).resolve()
acceptance = Path(sys.argv[2]).resolve()
ledger = json.loads((acceptance / "sources.json").read_text())
sources = sorted([*root.glob("Sources/**/*.swift"), *root.glob("Sources/**/*.c"),
                  *root.glob("Classifier/Sources/**/*.swift")])
expected = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sources}
if ledger != expected:
    raise SystemExit("Acceptance source fingerprint differs from the current production sources.")
raw = sorted(acceptance.glob("*.profraw"))
if not raw or not baseline.is_file():
    raise SystemExit("Both a complete baseline profile and acceptance profiles are required.")
binary_dir = Path(subprocess.check_output(["swift", "build", "--show-bin-path"],
                                         cwd=root, text=True).strip())
test_binary = next(binary_dir.glob("*.xctest/Contents/MacOS/*"))
classifier_dir = root / ".build/classifier/Build/Products/Debug"
objects = [binary_dir / "SidePulse", binary_dir / "sidepulsectl",
           classifier_dir / "sidepulse-classifier",
           *classifier_dir.glob("*.xctest/Contents/MacOS/*")]
report = root / ".build/coverage-report"
report.mkdir(parents=True, exist_ok=True)
profile = report / "all.profdata"
if baseline == profile:
    raise SystemExit("Copy the baseline profile before merging so it remains available for review.")
subprocess.run(["xcrun", "llvm-profdata", "merge", "-sparse", str(baseline),
                *map(str, raw), "-o", str(profile)], check=True)
arguments = [str(test_binary)]
for obj in objects:
    arguments += ["-object", str(obj)]
arguments += ["-instr-profile", str(profile)]
with (report / "coverage.json").open("w") as stream:
    subprocess.run(["xcrun", "llvm-cov", "export", *arguments, "-sources", *map(str, sources)],
                   check=True, stdout=stream)
subprocess.run(["xcrun", "llvm-cov", "show", *arguments, "-format=html",
                "-output-dir=" + str(report / "html"), "-sources", *map(str, sources)], check=True)
data = json.loads((report / "coverage.json").read_text())["data"][0]
if {str(p) for p in sources} != {row["filename"] for row in data["files"]}:
    raise SystemExit("The report does not include exactly all production sources.")
lines = data["totals"]["lines"]
print(f"Measured production lines: {lines['covered']}/{lines['count']} ({lines['percent']:.2f}%)")
(report / "acceptance-evidence.json").write_text(json.dumps({
    "sources": ledger, "totals": data["totals"], "production_files": len(sources),
    "baseline_sha256": hashlib.sha256(baseline.read_bytes()).hexdigest(),
    "acceptance_profiles": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in raw},
}, indent=2) + "\n")
if lines["covered"] != lines["count"]:
    raise SystemExit("Production line coverage is below 100%.")
