"""Bounded normal-eject retries for disposable integration fixtures only."""
import subprocess
import time


def eject_disk(device, *, allow_settle=False, run=subprocess.run,
               clock=time.monotonic, wait=time.sleep):
    # Ordinary images can briefly be held by Finder/Spotlight or Disk Arbitration.
    # Never retry a protected-volume refusal assertion and never force an eject.
    deadline = clock() + (5 if allow_settle else 0)
    while True:
        result = run(["diskutil", "eject", device], capture_output=True,
                     text=True, timeout=30)
        if result.returncode == 0 or clock() >= deadline:
            return result
        wait(0.2)
