#!/usr/bin/env python3
"""Real installed-bundle acceptance, exclusively on disposable GitHub-hosted Macs.
Never invoke on a developer computer. No pairing codes or child output are logged.
"""
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def run(*args, check=True):
    result = subprocess.run([str(a) for a in args], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=45)
    if check and result.returncode:
        # Child diagnostics can contain generated relay tokens. Do not emit them.
        raise RuntimeError(f'{Path(str(args[0])).name} failed (exit {result.returncode})')
    return result


def require(condition, message):
    if not condition:
        raise RuntimeError(message)



def launch_environment_members(output, selected):
    # Only the GUI domain's top-level environment block, not nested service data.
    blocks = re.findall(r'^\tenvironment = \{\n(.*?)^\t\}', output, re.MULTILINE | re.DOTALL)
    require(len(blocks) == 1, 'Cannot identify launch environment snapshot')
    return {key for key in selected if re.search(
        r'^\t\t' + re.escape(key) + r' =>(?: .*|)$', blocks[0], re.MULTILINE)}


def main():
    require(sys.platform == 'darwin' and os.getuid() != 0
            and os.environ.get('GITHUB_ACTIONS') == 'true'
            and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted',
            'Installed acceptance requires a disposable GitHub-hosted macOS runner.')
    root = Path(__file__).resolve().parent.parent
    binary, profiles = (Path(p).resolve() for p in sys.argv[1:])
    domain = f'gui/{os.getuid()}'
    prefix = 'com.unipheas.SidePulseSwift.'
    labels = [prefix + name for name in ('app', 'service', 'sdejectguard')]
    home = Path.home()
    run('launchctl', 'print', domain)
    require(not any(p.exists() for p in [Path('/Applications/SidePulse.app'),
            home / 'Applications/SidePulse.app', home / 'Library/Application Support/SidePulse',
            home / '.config/sidepulse', home / '.local/state/sidepulse']), 'Existing SidePulse installation or settings found.')
    require(run('pgrep', '-if', r'(^|/)(SidePulse|sidepulsectl)( |$)', check=False).returncode == 1,
            'Existing SidePulse process found.')
    for label in labels + ['io.sidepulse.agentstatus', 'io.sidepulse.service', 'io.sidepulse.sdejectguard']:
        for scope in (domain, 'system'):
            require(run('launchctl', 'print', f'{scope}/{label}', check=False).returncode != 0,
                    'Existing SidePulse launch job found.')
        for folder in (home / 'Library/LaunchAgents', Path('/Library/LaunchAgents'),
                       Path('/Library/LaunchDaemons')):
            require(not (folder / (label + '.plist')).exists(), 'Existing launch plist found.')
    profiles.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='sidepulse-installed-'))
    app = stage / 'SidePulse.app'
    contents = app / 'Contents'
    saved = {}
    registered = False
    cleanup_errors = []
    env = os.environ.copy()

    def cli(*args):
        result = subprocess.run([str(contents / 'MacOS/sidepulsectl'), *args], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
        require(result.returncode == 0, 'Installed CLI command failed: ' + ' '.join(args))

    def app_alive():
        return run('pgrep', '-f', '^' + re.escape(str(contents / 'MacOS/SidePulse')) + '$',
                   check=False).returncode == 0

    def await_app(expected):
        for _ in range(100):
            if app_alive() == expected:
                return
            time.sleep(.1)
        raise RuntimeError('Installed app lifecycle timed out')

    def owned_job(label):
        name = label.removeprefix(prefix)
        executable = contents / 'MacOS' / ('SidePulse' if name == 'app' else 'sidepulsectl')
        arguments = [str(executable)] + ([] if name == 'app' else [name, 'run'])
        file = stage / 'home/Library/LaunchAgents' / (label + '.plist')
        if not file.is_file():
            return False
        config = plistlib.loads(file.read_bytes())
        if config.get('Label') != label or config.get('ProgramArguments') != arguments:
            return False
        status = run('launchctl', 'print', f'{domain}/{label}', check=False)
        if status.returncode != 0:
            return False
        programs = re.findall(r'^\s*program = (.+)$', status.stdout.decode(), re.MULTILINE)
        return programs == [str(executable)]

    def fixture_processes_alive():
        # Exact executable and accepted launch arguments, not arbitrary substring matches.
        commands = run('ps', '-axo', 'command=').stdout.decode().splitlines()
        expected = {str(contents / 'MacOS/SidePulse'),
                    str(contents / 'MacOS/sidepulsectl') + ' service run',
                    str(contents / 'MacOS/sidepulsectl') + ' sdejectguard run'}
        return any(command.strip() in expected for command in commands)

    def await_fixture_exit():
        for _ in range(100):
            if not fixture_processes_alive():
                return
            time.sleep(.1)
        raise RuntimeError('Owned app or service process did not exit')

    def cleanup_step(description, action):
        try:
            action()
        except Exception:
            # Includes TimeoutExpired and OSError, without exposing child output.
            cleanup_errors.append(description)

    try:
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'Resources').mkdir()
        (contents / 'Frameworks').mkdir()
        for name in ('SidePulse', 'sidepulsectl'):
            shutil.copy2(binary / name, contents / 'MacOS' / name)
        shutil.copytree(binary / 'SidePulseSwift_PulseCore.bundle',
                        contents / 'Resources/SidePulseSwift_PulseCore.bundle')
        run('ditto', '--norsrc', '--noextattr',
            root / '.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework',
            contents / 'Frameworks/Sparkle.framework')
        for source in ('Artwork/SidePulse.icns', 'Scripts/sleep-helper.sh', 'LICENSE'):
            shutil.copy2(root / source, contents / 'Resources' / Path(source).name)
        info = plistlib.loads((root / 'Artwork/Info.plist').read_bytes())
        info.update(SUEnableAutomaticChecks=False, SUAllowsAutomaticUpdates=False,
                    SUFeedURL='https://127.0.0.1:9/fixture-appcast.xml')
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        run('codesign', '--force', '--sign', '-', contents / 'MacOS/sidepulsectl')
        run('codesign', '--force', '--sign', '-', app)
        run('codesign', '--verify', '--deep', '--strict', app)
        isolation = {
            'SIDEPULSE_USER_HOME': str(stage / 'home'),
            'SIDEPULSE_SWIFT_HOME': str(stage / 'settings'),
            'XDG_CONFIG_HOME': str(stage / 'config'),
            'XDG_STATE_HOME': str(stage / 'state'),
            # receiver() generates a local UUID, but service subsequently connects.
            # Keep even that connection loopback-only.
            'SIDEPULSE_SERVER': 'http://127.0.0.1:9',
            'LLVM_PROFILE_FILE': str(profiles / 'installed-%m-%p.profraw'),
        }
        members = launch_environment_members(
            run('launchctl', 'print', domain).stdout.decode(), isolation)
        for key, value in isolation.items():
            # getenv returns success with empty output for an absent key on macOS.
            saved[key] = (run('launchctl', 'getenv', key).stdout.decode().removesuffix('\n')
                          if key in members else None)
            run('launchctl', 'setenv', key, value)
            env[key] = value
        registrar = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
        run(registrar, '-f', app)
        registered = True
        cli('status-bar', 'start', '--foreground')
        await_app(True)
        time.sleep(7)  # Production Dashboard discovery is asynchronous.
        cli('status-bar', 'stop')
        await_app(False)
        cli('service', 'start', '--scope', 'user')
        require(owned_job(prefix + 'service'), 'Unexpected service executable')
        cli('service', 'stop', '--scope', 'user')
        cli('service', 'uninstall', '--scope', 'user')
        cli('setup', '--sd-eject-guard-scope', 'user')
        for label in labels:
            require(owned_job(label), 'Unexpected setup executable')
        await_app(True)
        cli('status-bar', 'stop')
        await_app(False)
        for name in ('service', 'sdejectguard'):
            cli(name, 'uninstall', '--scope', 'user')
        await_fixture_exit()
        require(any(p.stat().st_size > 0 for p in profiles.glob('installed-*.profraw')),
                'No installed coverage profiles produced')
    finally:
        # Cancellation must not interrupt restoration after cleanup has started.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            for label in labels:
                def remove_owned(label=label):
                    if owned_job(label):
                        run('launchctl', 'bootout', f'{domain}/{label}')
                cleanup_step('Failed to remove owned job', remove_owned)
            def quit_owned_app():
                if app_alive():
                    run('osascript', '-e',
                        'tell application id "com.unipheas.SidePulseSwift" to quit')
                await_app(False)
            cleanup_step('Owned app did not exit', quit_owned_app)
            cleanup_step('Owned processes did not exit', await_fixture_exit)
            if registered:
                cleanup_step('Failed to unregister fixture', lambda: run(registrar, '-u', app))
        finally:
            # Each restoration is independent, even when an earlier subprocess times out.
            for key, previous in saved.items():
                def restore(key=key, previous=previous):
                    if previous is None:
                        run('launchctl', 'unsetenv', key)
                    else:
                        run('launchctl', 'setenv', key, previous)
                cleanup_step('Failed to restore launch environment: ' + key, restore)
        if not cleanup_errors:
            cleanup_step('Failed to remove fixture directory', lambda: shutil.rmtree(stage))
        require(not cleanup_errors, '; '.join(cleanup_errors))
    print('Installed app and CLI lifecycle acceptance passed.')


if __name__ == '__main__':
    # Ensure cancellation takes the cleanup path too.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    main()
