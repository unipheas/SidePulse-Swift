"""Regenerate event fixtures with PYTHONPATH pointing to the Python fork's src."""
import json
import re
from pathlib import Path
from sidepulse import collector, cursor_hook, providers

cases = []
def capture(provider, raw):
    event = dict(raw, timestamp="2026-01-01T00:00:00Z")
    normalized = cursor_hook.normalize_payload(raw["hook_event_name"], event) if provider == "cursor" else event
    record = providers.parse_log_line(provider, json.dumps(normalized))
    mode = collector.mode_for_event(record) if record else None
    cases.append(dict(provider=provider, event=event, mode=mode.value if mode else None))

for provider in providers.HOOK_PROVIDERS:
    for event in getattr(providers, provider.upper() + "_EVENTS"):
        capture(provider, {"hook_event_name": event})
        if provider != "cursor":
            capture(provider, {"eventName": re.sub(r"(?<!^)(?=[A-Z])", "_", event).lower()})
for message in ["Anything else?", "Can you confirm?", "Choose a folder.", "Finished. Want me to publish?", "Please choose a file:\nREADME.md", "How should I proceed?\n* Recap: built", "Done. `which file?`", "```\nWhich file?\n```", "All good?", "What now?", "Done."]:
    capture("claude", {"hook_event_name":"Stop","last_assistant_message":message})
for text in ["ask", "waiting-for-input", "long task progress", "blocked", "tool-running", "idle", "done", "bogus"]:
    for template in ["<!-- sidepulse: %s -->", "[agent_monitor mode: %s]", "<!-- SidePulse status: %s -->", "Example: <!-- sidepulse: %s -->"]:
        capture("codex", {"hook_event_name":"Stop","last_assistant_message":template % text})
for value in [{"exit_code":0}, {"success":False}, {"interrupted":True}, {"exit_code":137}, "Traceback (most recent call last)", "exit code: 1", "ok"]:
    capture("grok", {"hookEventName":"PostToolUse","toolResponse":value})
for message in ["input parsed", "task completed; waiting for input", "please confirm", "done", "waiting for your input"]:
    capture("claude", {"hook_event_name":"Notification","notification_type":"idle_prompt","message":message})
target = Path(__file__).resolve().parents[1] / "Tests/PulseCoreTests/Fixtures/reference-events.json"
target.write_text(json.dumps(cases, indent=2) + "\n")

from sidepulse.battery import BatterySnapshot, program_for_battery
batteries = []
for count in [2, 8]:
    for percent in [0, 1, 13, 20, 21, 49, 50, 51, 99, 100]:
        for watts, plugged, charging in [(0, False, False), (30, True, False), (30, True, True), (96, True, True)]:
            snapshot = BatterySnapshot(percent=percent, is_charging=charging, is_plugged=plugged, adapter_watts=watts)
            batteries.append(dict(count=count, percent=percent, watts=watts, plugged=plugged, charging=charging,
                                  program=program_for_battery(snapshot, led_count=count, full_charge_watts=96)))
target.with_name("reference-battery.json").write_text(json.dumps(batteries, indent=2) + "\n")

# Registry conversion fixtures cover missing keys, invalid values, charger families,
# alternate capacity units, and negotiated PD fallback independently of this Mac.
from sidepulse.battery import snapshot_from_ioreg_props, snapshot_with_full_charge_watts
properties = [{}, {"BatteryInstalled":False},
    {"CurrentCapacity":6543,"StateOfCharge":76,"AppleRawMaxCapacity":7000,"AppleRawCurrentCapacity":5432,
     "DesignCapacity":8000,"Voltage":12000,"Amperage":-1500,"Temperature":3200,"CycleCount":42,
     "AvgTimeToEmpty":120,"PermanentFailureStatus":1},
    {"CurrentCapacity":80,"IsCharging":True,"FullyCharged":True,"ExternalConnected":True,
     "Amperage":0,"InstantAmperage":1500,"Voltage":12000,"AvgTimeToFull":20},
    {"CurrentCapacity":-1,"StateOfCharge":120,"Temperature":"unknown","MaxCapacity":100},
]
for family in [-1, 3, 4, 65280, 0xE0004001, 99]:
    properties.append({"AdapterDetails":{"FamilyCode":family,"Watts":70,"AdapterVoltage":20000,
        "Current":3500,"Name":"Adapter","Manufacturer":"Maker","Model":"A1","SerialString":"fixture"}})
properties += [{"AdapterDetails":{"Voltage":20000,"Current":3000}},
    {"AdapterDetails":{"UsbHvcMenu":[None,{}, {"MaxVoltage":20000,"MaxCurrent":5000},
        {"MaxVoltage":5000,"MaxCurrent":3000}, {"MaxVoltage":-1,"MaxCurrent":1000}]}},
    {"AdapterDetails":{"UsbHvcMenu":"invalid","SerialNumber":123}},
    {"AdapterDetails":None,"Temperature":0,"AppleRawMaxCapacity":1,"DesignCapacity":8},
]
records = [dict(properties=p, expected=snapshot_with_full_charge_watts(snapshot_from_ioreg_props(p),96).to_dict()) for p in properties]
target.with_name("reference-power.json").write_text(json.dumps(records, indent=2) + "\n")
