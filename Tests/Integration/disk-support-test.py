"""Regression checks for fixture retry policy; no actual disks or subprocesses."""
import subprocess
from types import SimpleNamespace
import unittest

from disk_support import eject_disk


class EjectRetryTests(unittest.TestCase):
    def exercise(self, statuses, *, allow_settle, duration=0):
        calls, waits = [], []
        elapsed = [0.0]
        def run(command, **options):
            calls.append((command, options))
            elapsed[0] += duration
            return SimpleNamespace(returncode=statuses[min(len(calls) - 1, len(statuses) - 1)])
        def wait(delay):
            waits.append(delay)
            elapsed[0] += delay
        result = eject_disk('/dev/fixture', allow_settle=allow_settle,
                            run=run, wait=wait)
        for command, options in calls:
            self.assertEqual(command, ['diskutil', 'eject', '/dev/fixture'])
            self.assertEqual(options, dict(capture_output=True, text=True, timeout=30))
        return result, calls, waits, elapsed[0]

    def test_protected_refusal_is_never_retried(self):
        result, calls, waits, _ = self.exercise([1, 0], allow_settle=False)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(calls), 1)
        self.assertEqual(waits, [])

    def test_ordinary_fixture_can_settle_without_force(self):
        result, calls, waits, _ = self.exercise([1, 1, 0], allow_settle=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(calls), 3)
        self.assertEqual(waits, [.2, .2])

    def test_slow_refusal_does_not_exhaust_retry_allowance(self):
        result, calls, waits, elapsed = self.exercise(
            [1, 0], allow_settle=True, duration=10)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(calls), 2)
        self.assertEqual(waits, [.2])
        self.assertAlmostEqual(elapsed, 20.2)

    def test_persistent_slow_refusal_stops_after_three_attempts(self):
        result, calls, waits, elapsed = self.exercise(
            [1], allow_settle=True, duration=30)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(calls), 3)
        self.assertEqual(waits, [.2, .2])
        self.assertAlmostEqual(elapsed, 90.4)

    def test_ownership_is_verified_before_every_retry(self):
        events = []
        def before():
            events.append('verify')
        def run(*args, **kwargs):
            events.append('eject')
            return SimpleNamespace(returncode=1)
        eject_disk('/dev/fixture', allow_settle=True, before_attempt=before,
                   run=run, wait=lambda _: None)
        self.assertEqual(events, ['verify', 'eject'] * 3)

    def test_identity_failure_prevents_retry(self):
        events = []
        def before():
            events.append('verify')
            if len(events) == 3:
                raise RuntimeError('identity changed')
        def run(*args, **kwargs):
            events.append('eject')
            return SimpleNamespace(returncode=1)
        with self.assertRaisesRegex(RuntimeError, 'identity changed'):
            eject_disk('/dev/fixture', allow_settle=True, before_attempt=before,
                       run=run, wait=lambda _: None)
        self.assertEqual(events, ['verify', 'eject', 'verify'])

    def test_timeout_propagates_without_retry(self):
        events = []
        def run(command, **options):
            events.append('eject')
            raise subprocess.TimeoutExpired(command, options['timeout'])
        with self.assertRaises(subprocess.TimeoutExpired):
            eject_disk('/dev/fixture', allow_settle=True,
                       before_attempt=lambda: events.append('verify'),
                       run=run, wait=lambda _: events.append('wait'))
        self.assertEqual(events, ['verify', 'eject'])

    def test_immediate_success_does_not_wait(self):
        result, calls, waits, _ = self.exercise([0], allow_settle=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)
        self.assertEqual(waits, [])


if __name__ == '__main__':
    unittest.main()
