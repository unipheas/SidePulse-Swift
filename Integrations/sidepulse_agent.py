"""Best-effort, content-free local SidePulse lifecycle instrumentation."""
import os
import argparse
import inspect
import time
import signal
import re
import subprocess
import threading
import uuid
from functools import wraps

DEFAULT_CLI = '/Applications/SidePulse.app/Contents/MacOS/sidepulsectl'
STATES = frozenset(('working', 'tool_running', 'long_task_progress',
                    'waiting_for_input', 'blocked_error', 'completed', 'idle_ready', 'unknown'))

class AgentRun:
    """One actual operation. Never reuse an instance or infer state from model presence.

    A blocked/needs-input state persists through heartbeats. Normal context exit
    marks success; exceptions (including KeyboardInterrupt) mark unknown, unless
    the caller explicitly reported blocked_error. Reporting failures are ignored.
    """
    def __init__(self, source, executable=DEFAULT_CLI, lease_seconds=60,
                 timeout=0.5, emitter=None):
        if not re.fullmatch(r'[A-Za-z0-9_.-]{1,48}', source):
            raise ValueError('source must be a safe ASCII slug, maximum 48 characters')
        if not os.path.isabs(executable):
            raise ValueError('executable must be an absolute path')
        if not isinstance(lease_seconds, int) or not 5 <= lease_seconds <= 3600:
            raise ValueError('lease_seconds must be 5..3600')
        if not 0 < timeout <= 2:
            raise ValueError('timeout must be >0 and <=2 seconds')
        self.source, self.executable = source, executable
        self.lease_seconds, self.timeout = lease_seconds, timeout
        self.run_id = str(uuid.uuid4())
        self.sequence = 0
        self.state = 'unknown'
        self._emit = emitter or self._subprocess
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = None
        self._started = False
        self._closed = False

    def _subprocess(self, args):
        subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=self.timeout, check=False,
                       close_fds=True)

    def _report_locked(self):
        self.sequence += 1
        args = [self.executable, 'agent-event', '--source', self.source,
                '--run', self.run_id, '--state', self.state,
                '--sequence', str(self.sequence), '--lease-seconds', str(self.lease_seconds),
                '--started-at', str(self.started_at)]
        try:
            self._emit(args)
        except Exception:
            pass

    def _heartbeat(self):
        while not self._stop.wait(self.lease_seconds / 4):
            with self._lock:
                if self._closed or self._stop.is_set():
                    return
                self._report_locked()

    def __enter__(self):
        with self._lock:
            if self._started:
                raise RuntimeError('AgentRun instances are single-use')
            self.started_at = time.time()
            self._started = True
            self.state = 'working'
            self._report_locked()
            self._thread = threading.Thread(target=self._heartbeat, daemon=True)
            try:
                self._thread.start()
            except Exception:
                self._thread = None
        return self

    def set_state(self, state):
        if state not in STATES or state in ('completed', 'idle_ready'):
            raise ValueError('use context exit for terminal completion')
        with self._lock:
            if not self._started or self._closed:
                raise RuntimeError('run is not active')
            self.state = state
            self._report_locked()

    def needs_input(self):
        self.set_state('waiting_for_input')

    def blocked(self):
        self.set_state('blocked_error')

    def __exit__(self, exc_type, exc, traceback):
        self._stop.set()
        # Emitter calls serialize with this terminal event. The production emitter
        # is bounded by timeout; a test/custom emitter must satisfy that contract.
        with self._lock:
            self._closed = True
            if exc_type is not None:
                if self.state != 'blocked_error':
                    self.state = 'unknown'
            elif self.state not in ('blocked_error', 'waiting_for_input', 'unknown'):
                self.state = 'completed'
            self._report_locked()
        if self._thread is not None:
            self._thread.join(timeout=self.timeout + 0.1)
        return False


def instrument(source, **options):
    """Decorate synchronous operations only (not generators or async functions)."""
    def decorate(function):
        if (inspect.iscoroutinefunction(function) or inspect.isgeneratorfunction(function)
                or inspect.isasyncgenfunction(function)):
            raise TypeError('instrument requires a synchronous non-generator function')
        @wraps(function)
        def wrapped(*args, **kwargs):
            with AgentRun(source, **options):
                return function(*args, **kwargs)
        return wrapped
    return decorate


def main(argv=None):
    """Wrap a real command without capturing or recording its content or stdio."""
    parser = argparse.ArgumentParser(description='Report local command lifecycle to SidePulse')
    parser.add_argument('--source', required=True)
    parser.add_argument('--executable', default=DEFAULT_CLI)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command
    if command and command[0] == '--':
        command = command[1:]
    if not command:
        parser.error('a command is required after --')
    try:
        run = AgentRun(args.source, executable=args.executable)
    except ValueError as error:
        parser.error(str(error))
    try:
        with run:
            # This CLI runs on the main thread. Forward SIGTERM only to our own
            # child; never signal unrelated processes or mutate process groups.
            child = None
            terminated = False
            previous = signal.getsignal(signal.SIGTERM)
            def forward_term(signum, frame):
                nonlocal terminated
                terminated = True
                if child is not None:
                    try:
                        child.terminate()
                    except ProcessLookupError:
                        pass
            signal.signal(signal.SIGTERM, forward_term)
            try:
                child = subprocess.Popen(command)
                if terminated:
                    child.terminate()
                try:
                    code = child.wait()
                except KeyboardInterrupt:
                    child.terminate()
                    try:
                        child.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait()
                    raise
            finally:
                signal.signal(signal.SIGTERM, previous)
            if terminated or code < 0:
                run.set_state('unknown')
                return 143 if terminated else 128 - code
            if code:
                run.blocked()
            return code
    except KeyboardInterrupt:
        return 130
    except OSError:
        return 127


if __name__ == '__main__':
    raise SystemExit(main())
