"""Bounded normal-eject retries for disposable integration fixtures only."""
import subprocess
import time


def eject_disk(device, *, allow_settle=False, run=subprocess.run,
               wait=time.sleep, before_attempt=lambda: None):
    # Ordinary images can briefly be held by Finder/Spotlight or Disk Arbitration.
    # Bound attempts rather than elapsed time: one slow refusal must not consume
    # the retry allowance. Never retry a protected-volume refusal assertion.
    attempts = 3 if allow_settle else 1
    for attempt in range(attempts):
        before_attempt()
        # Identity failures and timeouts propagate without retrying an uncertain
        # operation. Every retry is a normal eject of the verified fixture.
        result = run(["diskutil", "eject", device], capture_output=True,
                     text=True, timeout=30)
        if result.returncode == 0 or attempt == attempts - 1:
            return result
        wait(0.2)
