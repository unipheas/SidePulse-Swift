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

from disk_support import eject_disk

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
    try:
        whole, mount = attach()
        # Establish the baseline before identifying the image as a SidePulse. This
        # keeps any installed companion from treating the baseline as a device.
        baseline = eject_disk(whole, allow_settle=True)
        assert baseline.returncode == 0, "The ordinary fixture could not eject before guard startup: " + baseline.stderr
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
        denied = eject_disk(whole)
        assert denied.returncode != 0, "The native guard allowed the simulated Pro to eject"
        deadline = time.monotonic() + 8
        while not (mount / "STATUS.TXT").exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        assert (mount / "STATUS.TXT").exists(), "The protected volume was not remounted"
        # Let the next remount tick observe success and clear its pending entry.
        time.sleep(1.2)
        assert (mount / "STATUS.TXT").exists()
        (mount / "STATUS.TXT").unlink()
        guard.terminate()
        guard.communicate(timeout=5)
        assert guard.returncode == 0
        guard = subprocess.Popen([cli, "sdejectguard", "run"], env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.5)
        assert guard.poll() is None, "Native guard exited before ordinary-volume check"
        allowed = eject_disk(whole, allow_settle=True)
        assert guard.poll() is None, "Native guard exited during ordinary-volume check"
        assert allowed.returncode == 0, "The ordinary fixture did not eject with the native guard active: " + allowed.stderr
        whole = None
    finally:
        if guard is not None:
            guard.terminate()
            guard.communicate(timeout=5)
            assert guard.returncode == 0
        if whole is not None and Path(whole).exists():
            subprocess.run(["hdiutil", "detach", whole], check=True)
print("Native eject guard rejected a simulated Pro and allowed an ordinary disk image.")
