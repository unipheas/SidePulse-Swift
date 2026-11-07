"""Exercise the real native executable with private files and a loopback phone bridge."""
import json
import os
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
class Bridge(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_POST(self):
        posted.append((self.path, json.loads(self.rfile.read(int(self.headers["Content-Length"])))))
        self.send_response(204)
        self.end_headers()
    def do_GET(self):
        self.send_response(200)
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
    assert "macOS" in run("--help")
    assert "SidePulse" in run("--version")
    assert "releases" in run("update","--dry-run")
    assert "cyan-roll-8" in run("animations")
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
    for event, mode in [("UserPromptSubmit","working"),("Stop","completed")]:
        run("hook-log","--provider","codex","--event",event,stdin='{"session_id":"demo"}')
        status = json.loads(run("agent-monitor","status","--json"))
        assert status["mode"] == mode and status["sessions"][0]["session"] == "demo"
    run("settings","done","0")
    assert json.loads(run("agent-monitor","status","--json"))["mode"] == "idle_ready"
    run("agent-monitor","uninstall","all")
    run("profile","export",root/"profile.json")
    run("profile","import",root/"profile.json")
    run("audit", root/"audit.csv")
    assert '"audited_at"' in (root/"audit.csv").read_text()
    assert '"completed"' in (root/"audit.csv").read_text()
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
    run("unlink",ios[:12])
    stream[:] = [{"v":1,"type":"ios_registration","device":{"bundle_id":"io.sidepulse.ios","name":"Paired","push_token":ios}}]
    assert "Phone linked" in run("link")
    assert "Paired" in run("unlink")
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
    server.shutdown()
print("Native CLI, simulated volume, hook lifecycle, phone pairing, push and relay passed.")
