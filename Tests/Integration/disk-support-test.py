"""Regression checks for fixture retry policy; no actual disks or subprocesses."""
from types import SimpleNamespace
import unittest

from disk_support import eject_disk


class EjectRetryTests(unittest.TestCase):
    def exercise(self, statuses, *, allow_settle):
        calls, waits = [], []
        now = [0.0]
        def run(command, **options):
            calls.append((command, options))
            return SimpleNamespace(returncode=statuses[min(len(calls) - 1, len(statuses) - 1)])
        def wait(delay):
            waits.append(delay)
            now[0] += delay
        result = eject_disk('/dev/fixture', allow_settle=allow_settle,
                            run=run, clock=lambda: now[0], wait=wait)
        for command, options in calls:
            self.assertEqual(command, ['diskutil', 'eject', '/dev/fixture'])
            self.assertEqual(options['timeout'], 30)
        return result, calls, waits

    def test_protected_refusal_is_never_retried(self):
        result, calls, waits = self.exercise([1, 0], allow_settle=False)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(calls), 1)
        self.assertEqual(waits, [])

    def test_ordinary_fixture_can_settle_without_force(self):
        result, calls, waits = self.exercise([1, 1, 0], allow_settle=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(calls), 3)
        self.assertEqual(waits, [.2, .2])

    def test_persistent_refusal_still_fails_at_deadline(self):
        result, calls, waits = self.exercise([1], allow_settle=True)
        self.assertEqual(result.returncode, 1)
        self.assertLessEqual(len(calls), 27)
        self.assertGreaterEqual(sum(waits), 5)

    def test_ownership_is_verified_before_every_retry(self):
        events = []
        now = [0.0]
        def before():
            events.append("verify")
            if len(events) == 3:
                raise RuntimeError("identity changed")
        def run(*args, **kwargs):
            events.append("eject")
            return SimpleNamespace(returncode=1)
        def wait(delay):
            now[0] += delay
        with self.assertRaisesRegex(RuntimeError, "identity changed"):
            eject_disk('/dev/fixture', allow_settle=True, before_attempt=before,
                       run=run, clock=lambda: now[0], wait=wait)
        self.assertEqual(events, ["verify", "eject", "verify"])

    def test_immediate_success_does_not_wait(self):
        result, calls, waits = self.exercise([0], allow_settle=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)
        self.assertEqual(waits, [])


if __name__ == '__main__':
    unittest.main()
