"""Verify Disk Arbitration approval callbacks using only an image owned by this test."""
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time

cli = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="sidepulse-guard-") as directory:
    root = Path(directory)
    image = root / "guard.dmg"
    subprocess.run(["hdiutil", "create", "-quiet", "-size", "20m", "-fs", "HFS+",
                    "-volname", "SidePulseGuardFixture", str(image)], check=True)
    guard = None
    whole = None
    def attach():
        info = plistlib.loads(subprocess.check_output(["hdiutil", "attach", "-nobrowse", "-noautoopen",
                                                       "-plist", str(image)]))["system-entities"]
        disk = next(row["dev-entry"] for row in info if re.fullmatch(r"/dev/disk[0-9]+", row["dev-entry"]))
        mount = Path(next(row["mount-point"] for row in info if "mount-point" in row))
        return disk, mount
    def eject():
        return subprocess.run(["diskutil", "eject", whole], capture_output=True, text=True, timeout=30)
    try:
        whole, mount = attach()
        # Establish the baseline before identifying the image as a SidePulse. This
        # keeps any installed companion from treating the baseline as a device.
        baseline = eject()
        assert baseline.returncode == 0, "Another guard prevented the baseline eject: " + baseline.stderr
        whole = None
        whole, mount = attach()
        (mount / "STATUS.TXT").write_text("release_version 1.1.0\nserial guard-fixture\n")
        env = dict(os.environ, SIDEPULSE_USER_HOME=str(root / "home"),
                   SIDEPULSE_SWIFT_HOME=str(root / "settings"),
                   XDG_CONFIG_HOME=str(root / "config"), XDG_STATE_HOME=str(root / "state"))
        guard = subprocess.Popen([cli, "sdejectguard", "run"], env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.5)
        assert guard.poll() is None, "Native guard did not remain running"
        denied = eject()
        assert denied.returncode != 0, "The native guard allowed the simulated Pro to eject"
        deadline = time.monotonic() + 8
        while not (mount / "STATUS.TXT").exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        assert (mount / "STATUS.TXT").exists(), "The protected volume was not remounted"
        (mount / "STATUS.TXT").unlink()
        guard.terminate()
        guard.communicate(timeout=5)
        assert guard.returncode == 0
        guard = subprocess.Popen([cli, "sdejectguard", "run"], env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.5)
        allowed = eject()
        assert allowed.returncode == 0, "The native guard blocked an ordinary disk image: " + allowed.stderr
        whole = None
    finally:
        if guard is not None:
            guard.terminate()
            guard.communicate(timeout=5)
            assert guard.returncode == 0
        if whole is not None and Path(whole).exists():
            subprocess.run(["hdiutil", "detach", whole], check=True)
print("Native eject guard rejected a simulated Pro and allowed an ordinary disk image.")
