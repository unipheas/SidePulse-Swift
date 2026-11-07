"""Exercise the real native executable with private files and a loopback phone bridge."""
import json
import os
import pty
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

cli = Path(sys.argv[1]).resolve()
ios = "ab" * 32
android = "fcm_reg:42_" + "f" * 32
posted = []
stream = []
get_requests = []
bridge_status = 200
class Bridge(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_POST(self):
        posted.append((self.path, json.loads(self.rfile.read(int(self.headers["Content-Length"])))))
        self.send_response(204 if bridge_status == 200 else bridge_status)
        self.end_headers()
    def do_GET(self):
        get_requests.append(self.path)
        self.send_response(bridge_status)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for event in stream:
            self.wfile.write(b"data: " + json.dumps(event).encode() + b"\n\n")
        self.wfile.flush()

with tempfile.TemporaryDirectory() as folder, ThreadingHTTPServer(("127.0.0.1", 0), Bridge) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    root = Path(folder)
    env = dict(os.environ, SIDEPULSE_SERVER="http://127.0.0.1:" + str(server.server_port),
               SIDEPULSE_USER_HOME=str(root), SIDEPULSE_SWIFT_HOME=str(root/"native"),
               XDG_CONFIG_HOME=str(root/"config"), XDG_STATE_HOME=str(root/"state"))
    def run(*args, stdin="", ok=True):
        result = subprocess.run([cli, *map(str, args)], input=stdin, capture_output=True,
                                text=True, timeout=20, env=env)
        assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
        return result.stdout
    volume = root/"Pro"
    volume.mkdir()
    (volume/"STATUS.TXT").write_text("release_version 1.1.0\nserial fixture123\n")
    master, slave = pty.openpty()
    try:
        result = subprocess.run([cli, "write"], stdin=slave, capture_output=True, text=True, timeout=20, env=env)
        assert result.returncode != 0 and "Supply an LED program" in result.stderr
    finally:
        os.close(master)
        os.close(slave)
    assert "macOS" in run("--help")
    assert "SidePulse" in run("--version")
    for name in ("sidepulse", "agent-monitor"):
        alias = root / name
        alias.symlink_to(cli)
        for option in ("--version", "--help"):
            result = subprocess.run([alias, option], capture_output=True, text=True, timeout=20, env=env)
            assert result.returncode == 0 and "sidepulse" in result.stdout.lower(), result
        if name == "agent-monitor":
            result = subprocess.run([alias, "status", "--json"], capture_output=True, text=True, timeout=20, env=env)
            assert result.returncode == 0 and json.loads(result.stdout) is not None, result
    assert "releases" in run("update","--dry-run")
    assert "cyan-roll-8" in run("animations")
    assert "SidePulse Pro" in run("devices", "--device", volume)
    assert str(root/"native/settings.json") in run("settings")
    run("settings", "invalid", ok=False)
    run("settings", "done", "invalid", ok=False)
    run("profile", "invalid", root/"profile.json", ok=False)
    run("classify", "--backend", "unknown", "Hello", ok=False)
    run("classify", "--backend", "apple", "--model", "model", "Hello", ok=False)
    run("hook-log", ok=False)
    run("hook-log", "--provider", "codex", stdin=" " * 2_097_153)
    denied = root/"not-a-directory"
    denied.write_text("preserve this file")
    result = subprocess.run([cli, "hook-log", "--provider", "codex", "--log", str(denied/"event.jsonl")],
                            input='{"session_id":"failure","hook_event_name":"Stop"}', text=True,
                            capture_output=True, timeout=20, env=env)
    assert result.returncode == 0 and "hook logging failed" in result.stderr
    assert denied.read_text() == "preserve this file"
    run("setup", "--sd-eject-guard-scope", "invalid", ok=False)
    run("setup", "--no-status-bar", "--dry-run")
    run("setup", "--no-status-bar", "--sd-eject-guard-scope", "system", ok=False)
    assert "installed" in run("status-bar", "sleep-helper-status")
    run("status-bar", "install-sleep-helper", "--dry-run", ok=False)
    run("service", "start", "--scope", "system", ok=False)
    run("service", "status")
    run("service", "run", "--once", "--dry-run", "--device", volume)
    for arguments in [("battery", "status", "--json"), ("battery", "leds", "--device", str(volume), "--once", "--dry-run")]:
        result = subprocess.run([cli, *arguments], text=True, capture_output=True, timeout=20, env=env)
        if result.returncode:
            assert "No internal battery found" in result.stderr
        elif arguments[1] == "status":
            assert 0 <= json.loads(result.stdout)["percent"] <= 100
    result = subprocess.run([cli, "classify", "The build finished successfully."],
                            text=True, capture_output=True, timeout=60, env=env)
    if result.returncode:
        assert "requires Apple Intelligence" in result.stderr
    else:
        assert result.stdout.strip() in ["NO_REPLY_REQUIRED", "REPLY_REQUIRED", "UNCERTAIN"]
    assert json.loads(run("firmware","version","--device",volume,"--json"))[0]["serial"] == "fixture123"
    run("write","--device",volume,"--dry-run","off")
    assert not (volume/"LEDS.LED").exists()
    run("write","--device",volume,"-",stdin="#123456 100ms")
    assert (volume/"LEDS.LED").read_text() == "#123456 100ms"
    run("write","--device",volume,"--to","phone","off",ok=False)
    run("write","--device",volume,"--title","Message",ok=False)
    run("migrate")
    run("battery","configure","--display","agent","--full-watts","96","--show-on-power-change","no","--power-change-preview-seconds","2")
    config = json.loads((root/"native/settings.json").read_text())
    assert config["battery_monitoring"]["full_charge_watts"] == 96
    run("battery","configure","--full-watts","auto")
    run("battery","configure","--display","invalid",ok=False)
    run("agent-monitor","leds","--device",volume,"--once","--dry-run")
    run("fifa-final","--score","2-1","--dry-run")
    run("fifa-final","--score","-1-2","--dry-run",ok=False)
    run("settings","done","15")
    assert json.loads((root/"native/settings.json").read_text())["agent_list"]["completed_visible_seconds"] == 15
    run("agent-monitor","install","all","--dry-run")
    assert not (root/".codex/config.toml").exists()
    run("agent-monitor","install","all")
    assert all(row["status"] == "installed" for row in json.loads(run("agent-monitor","doctor","--json")))
    assert "codex" in run("agent-monitor", "doctor").lower()
    run("agent-monitor", "hook-log", "--provider", "codex", stdin='{"session_id":"alias","hook_event_name":"SessionEnd"}')
    for event, mode in [("UserPromptSubmit","working"),("Stop","completed")]:
        run("hook-log","--provider","codex","--event",event,stdin='{"session_id":"demo"}')
        status = json.loads(run("agent-monitor","status","--json"))
        assert status["mode"] == mode and status["sessions"][0]["session"] == "demo"
    run("settings","done","0")
    assert json.loads(run("agent-monitor","status","--json"))["mode"] == "idle_ready"
    run("agent-monitor","uninstall","all")
    run("link", "fixture_receiver_channel")
    assert json.loads((root/"native/relay.json").read_text())["outbound_channel"] == "fixture_receiver_channel"
    run("profile","export",root/"profile.json")
    run("profile","import",root/"profile.json")
    run("audit", root/"audit.csv")
    assert 'audited_at' in (root/"audit.csv").read_text()
    assert 'completed' in (root/"audit.csv").read_text()
    for job in ["service", "sdejectguard"]:
        run(job, "start", "--dry-run")
        run(job, "uninstall", "--dry-run")
        run(job, "status", "--invalid", ok=False)
        (root/"native"/(job + ".err.log")).write_text("one\ntwo\nthree\n")
        output = run(job, "logs", "--lines", "2")
        assert "two\nthree" in output and "one" not in output
        run(job, "logs", "--lines", "-1", ok=False)
    run("history", root/"history.csv")
    assert (root/"history.csv").read_text().startswith("time_utc")
    run("link",ios.upper(),"--name","Test iPhone")
    run("link",android,"--name","Test Pixel")
    assert "Test Pixel" in run("links")
    run("push","--to","Test iPhone","--message","Done","off")
    path, body = posted.pop()
    assert path.endswith("/apns_" + ios) and body["aps"]["alert"]["body"] == "Done" and body["leds"] == "off"
    run("write","--to","Test Pixel","--title","Finished")
    path, body = posted.pop()
    assert path.endswith(android) and body["sidepulse_event_id"] == body["data"]["sidepulse_event_id"]
    run("push","--to","phone","off",ok=False)
    run("push","--to","Test Pixel","--dry-run","off")
    assert not posted
    run("relay","send","sample_channel","grok",stdin='{"hook_event_name":"Stop","session_id":"r"}')
    _, message = posted.pop()
    stream[:] = [dict(message,v=2),message]
    run("relay","receive","sample_channel","--once")
    assert "relay:" in (root/"native/events/grok.jsonl").read_text()
    # Exercise the actual long-running native writer and its default relay/phone adapters.
    # Every destination is the private volume or loopback bridge; power assertions stay off.
    config_file = root/"native/settings.json"
    previous_config = config_file.read_text()
    config = json.loads(previous_config)
    config.update(sleep_prevention_policy="never", swift_closed_lid="never", swift_phone_mirror=True)
    config_file.write_text(json.dumps(config))
    relay_file = root/"native/relay.json"
    previous_relay = relay_file.read_text()
    relay_config = json.loads(previous_relay)
    relay_config["receiver_channel"] = "fixture_receive_channel"
    relay_file.write_text(json.dumps(relay_config))
    import time
    writer = subprocess.Popen([cli, "agent-monitor", "leds", "--device", str(volume), "--interval", "0.05"],
                              env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.5)
    assert writer.poll() is None
    writer.terminate()
    stdout, stderr = writer.communicate(timeout=5)
    assert writer.returncode == 0, stderr
    assert any(body.get("type") == "agent_event" for _, body in posted)
    assert any("leds" in body for _, body in posted)
    posted.clear()
    config_file.write_text(previous_config)
    relay_file.write_text(previous_relay)

    run("unlink",ios[:12])
    stream[:] = [{"v":1,"type":"ios_registration","device":{"bundle_id":"io.sidepulse.ios","name":"Paired","push_token":ios}}]
    assert "Phone linked" in run("link")
    assert "Paired" in run("unlink")
    stream[:] = [
        {"v": 1, "type": "android_registration", "device": {"push_token": android}},
        {"v": 1, "type": "android_registration", "device": {"package_id": "io.sidepulse.android", "push_token": android}},
    ]
    assert "Phone linked" in run("link")
    assert "Phone" in run("links")
    stream[:] = [{"v": 1, "type": "agent_event", "event_id": "missing-optional-metadata",
                 "provider": "grok", "line": {"hook_event_name": "UserPromptSubmit"}}]
    run("relay", "receive", "sample_channel", "--once")
    assert "relay:remote:default" in (root/"native/events/grok.jsonl").read_text()
    for args in [("link","invalid"),("unlink","missing"),("firmware","upgrade","--device",volume,"--version","bad"),
                 ("raw-write","invalid","off"),("settings","done","nan"),("unknown",),("hook-log","--provider"),
                 ("agent-monitor","install","none"),("classify",""),("relay","send","bad","badprovider")]:
        run(*args,ok=False)
    process = subprocess.Popen([cli,"agent-monitor","live","--interval","0.05"],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    import time
    time.sleep(0.3)
    process.terminate()
    process.communicate(timeout=5)
    assert process.returncode == 0
    guard = subprocess.Popen([cli,"sdejectguard","run"],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    time.sleep(0.5)
    assert guard.poll() is None
    guard.terminate()
    guard.communicate(timeout=5)
    assert guard.returncode == 0
    stream[:] = []
    run("relay", "receive", "sample_channel", "--once", ok=False)
    bridge_status = 503
    run("relay", "send", "sample_channel", "codex", stdin='{"hook_event_name":"Stop"}', ok=False)
    run("relay", "receive", "sample_channel", "--once", ok=False)
    before_retry = len(get_requests)
    receiver = subprocess.Popen([cli, "relay", "receive", "sample_channel"], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    deadline = time.monotonic() + 6
    while len(get_requests) < before_retry + 3 and time.monotonic() < deadline:
        time.sleep(0.1)
    assert len(get_requests) >= before_retry + 3, "Relay did not retry failed requests"
    assert receiver.poll() is None
    receiver.terminate()
    receiver.communicate(timeout=5)
    assert receiver.returncode == 0
    server.shutdown()
    server.server_close()
    run("relay", "send", "sample_channel", "codex", stdin='{"hook_event_name":"Stop"}', ok=False)
print("Native CLI, simulated volume, hook lifecycle, phone pairing, push and relay passed.")
