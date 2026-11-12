"""Check failed-turn hooks through the real CLI with temporary state only."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

cli = Path(sys.argv[1]).resolve()
for provider in ("claude", "cursor"):
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        env = dict(os.environ, SIDEPULSE_USER_HOME=str(root / "home"),
                   SIDEPULSE_SWIFT_HOME=str(root / "native"),
                   XDG_CONFIG_HOME=str(root / "config"), XDG_STATE_HOME=str(root / "state"))

        def run(*args, stdin=""):
            result = subprocess.run([cli, *args], input=stdin, capture_output=True,
                                    text=True, timeout=20, env=env)
            assert result.returncode == 0, (args, result.stdout, result.stderr)
            return result.stdout

        def report(event, payload, expected):
            identity = {"session_id": "failure-fixture"} if provider == "claude" else {"conversation_id": "failure-fixture"}
            run("hook-log", "--provider", provider, "--event", event,
                stdin=json.dumps(dict(payload, **identity)))
            status = json.loads(run("agent-monitor", "status", "--json"))
            assert status["mode"] == expected, (provider, event, payload, status)

        if provider == "claude":
            path = root / "home/.claude/settings.json"
            path.parent.mkdir(parents=True)
            unrelated = {"hooks": [{"type": "command", "command": "echo keep"}]}
            path.write_text(json.dumps({"untouched": 42, "hooks": {"StopFailure": [unrelated]}}))
            run("agent-monitor", "install", "claude")
            installed = path.read_bytes()
            entries = json.loads(installed)["hooks"]["StopFailure"]
            assert len(entries) == 2 and entries[0] == unrelated
            assert entries[1]["hooks"][0]["command"].endswith(" --event StopFailure # sidepulse-swift")
            run("agent-monitor", "install", "claude")
            assert path.read_bytes() == installed
            run("agent-monitor", "uninstall", "claude")
            remaining = json.loads(path.read_bytes())
            assert remaining["hooks"]["StopFailure"] == [unrelated] and remaining["untouched"] == 42

        # The real hook command's --event path must retain status:error and
        # clear a tracked permission when the turn fails instead of completing.
        run("settings", "done", "0")
        report("PermissionRequest", {"tool_name": "shell", "tool_input": {"command": "fixture"}}, "waiting_for_input")
        report("StopFailure" if provider == "claude" else "stop",
               {"status": "error", "error": "rate_limit", "last_assistant_message": "Fixture limit reached"},
               "blocked_error")
        report("PreToolUse", {"tool_name": "shell", "tool_input": {"command": "fixture"}}, "tool_running")
        report("UserPromptSubmit", {}, "working")
        report("Stop" if provider == "claude" else "stop", {"status": "completed"}, "idle_ready")
        if provider == "cursor":
            report("stop", {"status": "aborted"}, "idle_ready")
print("Provider failure hooks, permission cleanup, recovery, and completion passed.")
