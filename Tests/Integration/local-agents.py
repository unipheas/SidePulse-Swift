"""Exercise local lifecycle metadata with the real CLI and no device or network."""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

cli = Path(sys.argv[1]).resolve()
adapter = Path(__file__).resolve().parents[2] / 'Integrations/sidepulse_agent.py'
with tempfile.TemporaryDirectory(prefix='sidepulse-local-agents-') as folder:
    root = Path(folder)
    env = dict(os.environ, SIDEPULSE_USER_HOME=str(root / 'home'),
               SIDEPULSE_SWIFT_HOME=str(root / 'support'),
               XDG_CONFIG_HOME=str(root / 'config'), XDG_STATE_HOME=str(root / 'state'))

    def command(*args, ok=True):
        result = subprocess.run([str(cli), *map(str, args)], capture_output=True,
                                text=True, timeout=10, env=env)
        assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
        return result.stdout

    started = str(time.time())
    def event(source, run, state, sequence, lease=60):
        return json.loads(command('agent-event', '--source', source, '--run', run,
                                  '--started-at', started, '--state', state, '--sequence', sequence,
                                  '--lease-seconds', lease))['accepted']

    def status():
        return json.loads(command('agent-monitor', 'status', '--json'))

    assert event('ollama', 'one', 'working', 1)
    assert event('nova', 'one', 'working', 1)
    assert len(status()['sessions']) == 2
    assert event('ollama', 'one', 'completed', 2)
    assert status()['mode'] == 'working'
    assert not event('ollama', 'one', 'waiting_for_input', 1)
    assert not event('ollama', 'one', 'working', 3)
    assert event('nova', 'one', 'waiting_for_input', 2)
    assert status()['mode'] == 'waiting_for_input'
    assert event('nova', 'one', 'blocked_error', 3)
    assert status()['mode'] == 'blocked_error'
    assert event('nova', 'one', 'idle_ready', 4)
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        list(pool.map(lambda sequence: event('concurrent', 'shared', 'working', sequence), range(1, 25)))
    assert not event('concurrent', 'shared', 'blocked_error', 23)
    assert event('concurrent', 'shared', 'completed', 25)
    assert event('lease', 'short', 'working', 1, lease=5)
    time.sleep(5.1)
    assert status()['mode'] == 'unknown'
    assert event('lease', 'short', 'idle_ready', 2)
    command('agent-event', '--source', '../escape', '--run', 'bad', '--started-at', started, '--state', 'working', '--sequence', 1, ok=False)
    command('agent-event', '--source', 'safe', '--run', 'bad', '--started-at', started, '--state', 'working', '--sequence', 1, '--prompt', 'SECRET_SENTINEL', ok=False)
    for exit_code in (0, 7):
        child = subprocess.run(
            [sys.executable, str(adapter), '--source', 'wrapped', '--executable', str(cli),
             '--', sys.executable, '-c', f"print('SECRET_SENTINEL'); raise SystemExit({exit_code})"],
            env=env, capture_output=True, text=True, timeout=10)
        assert child.returncode == exit_code, child
        assert child.stdout == 'SECRET_SENTINEL\n', child.stdout
    assert status()['mode'] == 'blocked_error'
    allowed = {'version', 'source', 'run', 'sequence', 'state', 'startedAt', 'updatedAt', 'leaseSeconds'}
    snapshots = list((root / 'support/local-agents').glob('*.json'))
    assert len(snapshots) == 6, len(snapshots)
    for file in snapshots:
        assert set(json.loads(file.read_text())) == allowed
        assert file.stat().st_mode & 0o777 == 0o600
    for file in root.rglob('*'):
        if file.is_file():
            assert b'SECRET_SENTINEL' not in file.read_bytes(), file
print('Local agent CLI integration passed: overlap, ordering, attention, expiry, command wrapper, privacy.')
