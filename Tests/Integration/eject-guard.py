"""Verify Disk Arbitration approval using two independently owned disk images."""
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
    protected_image = root / "protected.dmg"
    ordinary_image = root / "ordinary.dmg"
    for image, name in [(protected_image, "SidePulseGuardFixture"),
                        (ordinary_image, "OrdinaryGuardFixture")]:
        subprocess.run(["hdiutil", "create", "-quiet", "-size", "20m", "-fs", "HFS+",
                        "-volname", name, str(image)], check=True)
    guard = None
    attached = {}

    def attach(image):
        info = plistlib.loads(subprocess.check_output([
            "hdiutil", "attach", "-nobrowse", "-noautoopen", "-plist", str(image)
        ]))["system-entities"]
        disk = next(row["dev-entry"] for row in info
                    if re.fullmatch(r"/dev/disk[0-9]+", row["dev-entry"]))
        mount = Path(next(row["mount-point"] for row in info if "mount-point" in row))
        attached[disk] = image
        return disk, mount

    def require_ejected(disk, context):
        result = eject_disk(disk, allow_settle=True)
        assert result.returncode == 0, context + ": " + result.stdout + result.stderr
        attached.pop(disk)

    try:
        # The ordinary fixture has its own volume identity and is never marked as
        # a Pro. Do not repurpose a protected image with pending remount events.
        ordinary, _ = attach(ordinary_image)
        require_ejected(ordinary, "Ordinary fixture baseline eject failed")
        protected, protected_mount = attach(protected_image)
        (protected_mount / "STATUS.TXT").write_text("release_version 1.1.0\nserial guard-fixture\n")
        env = dict(os.environ, SIDEPULSE_USER_HOME=str(root / "home"),
                   SIDEPULSE_SWIFT_HOME=str(root / "settings"),
                   XDG_CONFIG_HOME=str(root / "config"), XDG_STATE_HOME=str(root / "state"))
        guard = subprocess.Popen([cli, "sdejectguard", "run"], env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.5)
        assert guard.poll() is None, "Native guard did not remain running"
        denied = eject_disk(protected)
        assert denied.returncode != 0, "The native guard allowed the simulated Pro to eject"
        deadline = time.monotonic() + 8
        while not (protected_mount / "STATUS.TXT").exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        assert (protected_mount / "STATUS.TXT").exists(), "The protected volume was not remounted"
        ordinary, ordinary_mount = attach(ordinary_image)
        assert ordinary != protected, "Fixtures must have distinct attached disk identities"
        identifiers = [plistlib.loads(subprocess.check_output(
            ["diskutil", "info", "-plist", str(path)]))["VolumeUUID"]
            for path in (protected_mount, ordinary_mount)]
        assert identifiers[0] != identifiers[1], "Fixtures must have distinct volume UUIDs"
        assert not (ordinary_mount / "STATUS.TXT").exists()
        assert guard.poll() is None, "Native guard exited before ordinary-volume check"
        require_ejected(ordinary, "Ordinary fixture did not eject with native guard active")
        assert guard.poll() is None, "Native guard exited during ordinary-volume check"
        assert (protected_mount / "STATUS.TXT").exists(), "Ordinary eject disturbed the protected Pro"
    finally:
        cleanup_errors = []
        if guard is not None:
            try:
                guard.terminate()
                guard.communicate(timeout=5)
                assert guard.returncode == 0
            except Exception as error:
                cleanup_errors.append("guard shutdown: " + str(error))
        # Verify backing-image identity before detaching; a reused BSD name must
        # never cause cleanup to touch another disk. Try every owned fixture.
        for disk, image in attached.items():
            try:
                mounted = plistlib.loads(subprocess.check_output(
                    ["hdiutil", "info", "-plist"]))["images"]
                owned = any(Path(item.get("image-path", "")).resolve() == image.resolve()
                            and any(row.get("dev-entry") == disk for row in item.get("system-entities", []))
                            for item in mounted)
                if Path(disk).exists():
                    assert owned, "Fixture disk identity changed before cleanup"
                    subprocess.run(["hdiutil", "detach", disk], check=True)
            except Exception as error:
                cleanup_errors.append(image.name + ": " + str(error))
        if cleanup_errors:
            raise RuntimeError("Fixture cleanup failed: " + "; ".join(cleanup_errors))
print("Native eject guard rejected a simulated Pro and allowed a distinct ordinary disk image.")
