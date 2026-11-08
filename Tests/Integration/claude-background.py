"""Exercise Claude background lifecycle through the real CLI using isolated files only."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

cli = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory() as folder:
    root = Path(folder)
    env = dict(os.environ, SIDEPULSE_USER_HOME=str(root),
               SIDEPULSE_SWIFT_HOME=str(root / "native"),
               XDG_CONFIG_HOME=str(root / "config"), XDG_STATE_HOME=str(root / "state"))

    def run(*args, stdin=""):
        result = subprocess.run([cli, *args], input=stdin, capture_output=True,
                                text=True, timeout=20, env=env)
        assert result.returncode == 0, (args, result.stdout, result.stderr)
        return result.stdout

    # A finished Claude turn can still own background jobs. Idle reminders must
    # not clear active work; genuine attention and final completion still work.
    for payload, mode in [
        ({"hook_event_name": "Stop", "background_tasks": [{"type": "shell", "status": "running"}]}, "long_task_progress"),
        ({"hook_event_name": "Notification", "notification_type": "idle_prompt", "message": "Claude is waiting for your input"}, "long_task_progress"),
        ({"hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "Please approve"}, "waiting_for_input"),
        ({"hook_event_name": "Stop", "background_tasks": [{"status": "running"}], "last_assistant_message": "Should I proceed?"}, "waiting_for_input"),
        ({"hook_event_name": "Stop", "background_tasks": [{"status": "running"}]}, "long_task_progress"),
        ({"hook_event_name": "Stop", "background_tasks": [{"status": "completed"}]}, "completed"),
    ]:
        run("hook-log", "--provider", "claude", stdin=json.dumps(dict(payload, session_id="background-fixture")))
        status = json.loads(run("agent-monitor", "status", "--json"))
        assert status["mode"] == mode, (payload, status)
    run("settings", "done", "0")
    assert json.loads(run("agent-monitor", "status", "--json"))["mode"] == "idle_ready"
print("Claude background tasks, idle reminders, attention and completion passed.")
