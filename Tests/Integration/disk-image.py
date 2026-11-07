"""Run the raw writer against a disposable disk image attached by this process."""
import os
import plistlib
from pathlib import Path
import re
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory() as tmp:
    image = Path(tmp) / "test.img"
    disk = bytearray(512 * 64)
    disk[510:512] = b"\x55\xaa"
    disk[11:13] = (512).to_bytes(2, "little")
    disk[13:17] = bytes([1, 1, 0, 1])
    disk[17:19] = (16).to_bytes(2, "little")
    disk[19:21] = (64).to_bytes(2, "little")
    disk[22] = 1
    disk[512:517] = bytes([248,255,255,255,15])
    disk[1024:1035] = b"LEDS    LED"
    disk[1050] = 2
    image.write_bytes(disk)
    attached = plistlib.loads(subprocess.check_output(["hdiutil","attach","-nomount","-plist",
        "-imagekey","diskimage-class=CRawDiskImage", str(image)]))["system-entities"]
    whole = next(row["dev-entry"] for row in attached if re.fullmatch(r"/dev/disk[0-9]+",row["dev-entry"]))
    try:
        args = [sys.argv[1],"raw-write",whole]
        subprocess.run([*args,"--dry-run","off"],check=True)
        subprocess.run([*args,"off"],check=True)
    finally:
        subprocess.run(["hdiutil","detach",whole],check=True)
    disk[1052:1056] = (3).to_bytes(4,"little")
    disk[1536:1539] = b"off"
    assert image.read_bytes() == disk, "Raw write changed bytes outside the LED file and its directory size."
print("Raw FAT12 write verified on an attached disk image.")
