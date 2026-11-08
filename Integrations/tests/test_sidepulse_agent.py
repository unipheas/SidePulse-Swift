import subprocess
import sys
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch, MagicMock
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sidepulse_agent import AgentRun, instrument, main

class Tests(unittest.TestCase):
    def test_order_and_distinct_runs(self):
        events = []
        with AgentRun('nova', emitter=events.append) as a:
            with AgentRun('ollama', emitter=events.append) as b:
                a.set_state('tool_running')
        self.assertNotEqual(a.run_id, b.run_id)
        for run in (a, b):
            own = [e for e in events if e[5] == run.run_id]
            self.assertEqual([int(e[9]) for e in own], list(range(1, len(own)+1)))
            self.assertEqual(own[-1][7], 'completed')

    def test_heartbeat_preserves_attention_and_serializes(self):
        events = []
        active = threading.Lock()
        overlaps = []
        def emit(args):
            acquired = active.acquire(False)
            if not acquired:
                overlaps.append(True)
                return
            events.append(args)
            time.sleep(.01)
            active.release()
        with AgentRun('nova', lease_seconds=5, emitter=emit) as run:
            run.needs_input()
            time.sleep(1.4)
        self.assertEqual(overlaps, [])
        self.assertGreaterEqual(len(events), 4)
        self.assertTrue(all(e[7] == 'waiting_for_input' for e in events[1:]))
        count = len(events)
        time.sleep(.05)
        self.assertEqual(count, len(events))

    def test_exception_cancel_and_blocked(self):
        for error in (ValueError, KeyboardInterrupt):
            events = []
            with self.assertRaises(error):
                with AgentRun('nova', emitter=events.append):
                    raise error('SECRET')
            self.assertEqual(events[-1][7], 'unknown')
            self.assertNotIn('SECRET', repr(events))
        events = []
        with AgentRun('nova', emitter=events.append) as run:
            run.blocked()
        self.assertEqual(events[-1][7], 'blocked_error')

    def test_unavailable_and_timeout_fail_open(self):
        for error in (FileNotFoundError(), subprocess.TimeoutExpired('cli', .5)):
            with patch('sidepulse_agent.subprocess.run', side_effect=error) as proc:
                @instrument('nova')
                def operation(secret):
                    return secret
                self.assertEqual(operation('PRIVATE'), 'PRIVATE')
                self.assertNotIn('PRIVATE', repr(proc.call_args_list))
                self.assertEqual(proc.call_args.kwargs['stdout'], subprocess.DEVNULL)
                self.assertEqual(proc.call_args.kwargs['timeout'], .5)

    def test_validation_and_single_use(self):
        for source in ('bad space', 'a'*49, 'é'):
            with self.assertRaises(ValueError):
                AgentRun(source)
        run = AgentRun('nova', emitter=lambda _: None)
        with run:
            pass
        with self.assertRaises(RuntimeError):
            run.__enter__()

    def test_reject_deferred_functions(self):
        async def coroutine():
            return 1
        def generator():
            yield 1
        async def async_generator():
            yield 1
        for function in (coroutine, generator, async_generator):
            with self.assertRaises(TypeError):
                instrument('nova')(function)

    def test_thread_start_failure_is_best_effort(self):
        events = []
        with patch('sidepulse_agent.threading.Thread.start', side_effect=RuntimeError):
            with AgentRun('nova', emitter=events.append):
                pass
        self.assertEqual([e[7] for e in events], ['working', 'completed'])

    def test_command_wrapper(self):
        for code, expected, state in ((0, 0, 'completed'), (7, 7, 'blocked_error'),
                                      (-15, 143, 'unknown')):
            events = []
            with patch.object(AgentRun, '_subprocess', side_effect=events.append), \
                 patch('sidepulse_agent.subprocess.Popen') as job:
                job.return_value.wait.return_value = code
                self.assertEqual(main(['--source', 'nova', '--', 'command', 'PRIVATE']), expected)
            job.assert_called_once_with(['command', 'PRIVATE'])
            self.assertEqual(events[-1][7], state)
            self.assertNotIn('PRIVATE', repr(events))
        for error, expected in ((KeyboardInterrupt(), 130), (FileNotFoundError(), 127)):
            events = []
            with patch.object(AgentRun, '_subprocess', side_effect=events.append), \
                 patch('sidepulse_agent.subprocess.Popen', side_effect=error):
                self.assertEqual(main(['--source', 'nova', '--', 'command']), expected)
            self.assertEqual(events[-1][7], 'unknown')

    def test_started_at_is_fixed_and_sigterm_forwarded(self):
        events = []
        with patch('sidepulse_agent.time.time', return_value=1234.5):
            with AgentRun('nova', emitter=events.append) as run:
                run.set_state('tool_running')
        self.assertTrue(all(e[-2:] == ['--started-at', '1234.5'] for e in events))
        events = []
        with patch.object(AgentRun, '_subprocess', side_effect=events.append), \
             patch('sidepulse_agent.subprocess.Popen') as spawn, \
             patch('sidepulse_agent.signal.signal') as handlers, \
             patch('sidepulse_agent.signal.getsignal', return_value='previous'):
            def wait():
                handlers.call_args_list[0].args[1](15, None)
                return -15
            spawn.return_value.wait.side_effect = wait
            self.assertEqual(main(['--source', 'nova', '--', 'command']), 143)
            spawn.return_value.terminate.assert_called_once()
            self.assertEqual(handlers.call_args.args[1], 'previous')
        self.assertEqual(events[-1][7], 'unknown')

if __name__ == '__main__':
    unittest.main()
