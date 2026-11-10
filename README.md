<img src="Artwork/SidePulse.png" width="96" alt="SidePulse app icon">

# SidePulse

A native macOS companion for the SidePulse Pro SD card and SidePulse Dot USB device. Follow coding sessions from the menu bar, preview an animation on a virtual LED strip, or drive the lights on your desk. Requires macOS 14 or later.

[Download the Mac app](https://github.com/unipheas/SidePulse-Swift/releases) · [LED programming language](LEDS_FORMAT.md) · [Port coverage](PORTING.md) · [Testing](TESTING.md)

## Try it

1. Unzip the release and drag **SidePulse** into Applications. The 0.2.4 release is Developer ID signed and notarized. You can also build it locally.
2. Open the app and connect a SidePulse. **Overview** shows the detected model, firmware, and current agent state.
3. In **Settings**, set **Show Done for** to `15` seconds. The display returns to Idle when the timer expires and other agents are quiet.
4. If you already run SidePulse, Swift previews its hook events and reads your existing animation settings. Click **Use this installation for device output** when you want to try the native writer. **Restore previous installation** hands the lights back. On a fresh setup, the welcome panel offers agent hooks, background monitoring, Pro eject protection, opening at login, and the optional sleep helper. Follow the provider's normal hook trust prompts.

The app writes its settings under `~/Library/Application Support/SidePulse`. Existing Python preferences are read as initial values. A fresh installation defaults to a 20-minute Done hold. Setup is per user.

Use the appearance icon at the top right of the window to choose **Auto**, **Light**, or **Dark**. Auto follows macOS; an explicit choice applies throughout SidePulse and is remembered after relaunch.

## Command line

The app includes a standalone CLI. For the examples below, set a shell variable to its installed path.

```sh
pulse="/Applications/SidePulse.app/Contents/MacOS/sidepulsectl"
"$pulse" devices
"$pulse" agent-monitor status --json
"$pulse" settings done 15
"$pulse" write --dry-run '#30D158 800ms pulse\nrepeat'
"$pulse" firmware version
"$pulse" firmware upgrade --dry-run
"$pulse" --help
```

- **Monitoring.** Hooks for Codex, Claude Code, Cursor, Grok and Junie. Optional Codex and Claude transcript recovery. A headless launch agent is available with `service start`; `service stop` stops it, and `service uninstall` removes the job.
- **Notch lights.** Enable **Show lights beneath the notch** in Settings for a click-through strip. Choose agent status or battery level and adjust brightness. External displays use a narrow strip at the top edge.
- **Animations.** Choose a profile, edit an individual state, import or export a SidePulse profile, and preview it on a two- or eight-LED display. Reusable library animations can be renamed and updated without breaking the states and profiles that reference them. The preview uses the upstream firmware simulator through JavaScriptCore.
  In the Animations tab, **Output profiles** assigns built-in or saved profiles independently to **Dot**, **Pro**, and **Notch**. Dot and Pro choices apply to all connected devices of that model, including after reconnecting at another mount path. Select **Use global animations** to inherit the existing global editor. Missing/deleted profiles or unavailable animations also fall back to global animations. To make a custom output profile, edit the global animations, save a named profile, then assign it to that output.
  **Show Notch only when attention is needed** hides the entire Notch panel outside Needs input and Blocked, including when battery display or a power-change preview is selected. The Notch must still be enabled in Devices; manual display stays hidden. Hardware manual/battery priority, brightness, lid timing, and saved device preferences are unchanged. Assigned profiles supply model-sized lid animations when available. Phones and the overview/menu previews continue to use global animations.
- **Hybrid Pro display.** In Devices, choose **Battery + agent status** on a connected Pro to dedicate LED 0 to battery and LEDs 1–7 to aggregated agent state. It uses a fixed palette and animations rather than the selected Pro animation profile. Battery is shown in teal, blue, purple or dark purple by level, white while charging, and gray when unavailable. Brightness and lid animations still apply. The ordinary agent, battery and manual modes are unchanged; power-change previews do not replace the hybrid layout.
- **Hardware.** Mounted-volume LED writes, Pro READ2ME and Dot SPC2 fallback for read-only volumes, battery display, and model-specific firmware package verification. `sdejectguard start` installs an optional per-user eject guard; stop it before intentionally ejecting the Pro.
- **Mobile.** `link` displays a pairing QR code for the SidePulse mobile app. Use `links`, `push --to ID` and `unlink ID` to manage destinations. `relay send` and `relay receive` exchange agent events through a bridge channel.
- **Examples.** `audio-meter` animates input level from the microphone. `fifa-final --score 2-1 --dry-run` previews the scoreboard animation.
- **History.** Export status changes with `history history.csv` or `history history.html`. Export individual hook events and their interpreted status with `audit events.csv` or `audit events.html`.
- **Reply classification.** On supported Macs with Apple Intelligence available, `classify` uses Apple's on-device Foundation Models framework. Add `--json` for the label and raw model output.

## Claude background tasks

When Claude's session `Stop` hook lists a background task with `status: "running"`,
SidePulse keeps that session In progress and eligible for keep-awake instead of
showing Done. Questions and explicit status overrides still take priority, and
finished subagents do not acquire a background hold. Claude's `idle_prompt`
reminders do not clear this state or extend its timestamp; actual permission
requests, errors, completion notifications and later session events still apply.
Without another event, the existing stale timeout still expires the session.
This uses reported hook state, not independent process monitoring.

## Other local agents and Ollama

Use `agent-event` or the optional [Python lifecycle adapter](Integrations/README.md)
for local programs that do not provide coding-agent hooks. This is explicit
instrumentation of a task, not automatic detection of every running model or
cloud chat. A model remaining loaded in Ollama does not mean it is working.

```sh
run=$(uuidgen)
started=$(date +%s)
"$pulse" agent-event --source local-worker --run "$run" --started-at "$started" --state working --sequence 1
"$pulse" agent-event --source local-worker --run "$run" --started-at "$started" --state completed --sequence 2
```

Use a fresh run ID and a fixed start timestamp for each operation, with increasing
sequence numbers. Reuse the same start timestamp for every event of that run. Each run
is independent, so finishing one cannot clear another. Send a heartbeat before
the lease expires (60 seconds by default, configurable from 5 to 3,600 seconds).
An expired active lease becomes Unknown, not Done. Explicit `waiting_for_input`
and `blocked_error` remain visible until resumed or acknowledged with a newer
state; all snapshots leave the active list after 24 hours without an update.
A completed or acknowledged (`idle_ready`) run cannot be restarted. Use a new ID.

Only source label, run ID, state, sequence, start/update timestamps and lease are
stored locally. Storage is capped at 4,096 snapshots. At capacity, expired snapshots
are pruned as needed when a new run is admitted, and old start timestamps prevent delayed events from
recreating a pruned run. If the cap is reached, new telemetry is rejected while
existing run updates continue; the best-effort adapter does not fail the job.
Use fixed source labels, never user content. The interface accepts no prompts,
responses, command arguments, paths or credentials, and local events are excluded
from the existing network relay. No listener or startup service is installed.
The command wrapper can report ordinary process work and exit failures; only an
application's explicit lifecycle events can reliably report that it needs input.
ChatGPT cloud conversations need a supported lifecycle source or explicit reporting;
this integration does not claim universal cloud visibility.

## Build

Open `Package.swift` in Xcode or use a Mac with Xcode 16 or later.

```sh
swift test
# Full local suite, including UI automation (requires XcodeGen):
RUN_UI_TESTS=1 RUN_CLASSIFIER_TESTS=1 Scripts/test-coverage.sh
Scripts/package.sh --universal
Scripts/install.sh
open "/Applications/SidePulse.app"
```

The install script registers one copy in `/Applications`, keeps the distribution ZIP, and removes the loose build copy to avoid duplicate search results.

The package script builds both executables, includes their resources and icon, signs the bundle, and creates a ZIP in `dist`. The core uses Swift and Apple frameworks. A small C adapter provides access to the IOKit USB plug-in vtable. The build has no Python dependency. Sparkle provides the native updater; its license is included under `ThirdParty`. Publishing a signed update requires `Scripts/prepare-update.sh` and the release signing key stored in Keychain. The signed feed publishes SidePulse 0.2.4 (build 9); installed apps can use **Check for Updates…**. Release archives use Developer ID signing and Apple notarization; local builds remain ad-hoc signed unless a signing identity is supplied.

## Attribution

This independent port is based on [inteliwear/sidepulse](https://github.com/inteliwear/sidepulse) and the configurable Done duration in [upstream PR #79](https://github.com/inteliwear/sidepulse/pull/79). The bundled LED programs, profiles, LED format reference and firmware simulator come from that MIT-licensed project. The app icon and Swift implementation are part of this repository. See [LICENSE](LICENSE).

### Optional hardware and power controls

The app can preview battery changes when the Mac is plugged in and play lid-open and lid-closed animations. To enable the stronger closed-lid policy, an administrator can run `sudo Scripts/sleep-helper.sh install` and then select a policy in Settings. This installs a rule restricted to two `pmset` commands. Select **Never** before running `sudo Scripts/sleep-helper.sh uninstall`. The app records whether it changed the system setting so it can release its override.

For an unmounted single-FAT FAT12 device, `raw-write /dev/rdiskN --dry-run PROGRAM` checks the existing LED file and geometry. Raw writes require a whole device no larger than 300,000 bytes and preserve its existing allocation. Normal mounted-device writes are the usual path.

### Compatibility options

Custom hook paths are accepted with `agent-monitor install --log-dir DIRECTORY` or `--codex-log PATH` (and equivalent options for the other providers). Monitoring supports `--max-lines` and `--recent-seconds`. Mounted writes accept an explicit `.LED` path or `--file-name NAME.LED`.

`status-bar start --no-start` installs the app launch agent without launching it. `status-bar stop` quits it; `status-bar install-sleep-helper` and `status-bar uninstall-sleep-helper` manage the bundled privileged helper. The eject guard accepts `--scope user`, `system`, or `auto`; system scope requires root. The GUI and normal monitor run in the user's session.

### Optional local MLX classification

Apple Intelligence remains the default classifier. On Apple silicon, the packaged app also includes a Swift/Metal helper for the original MLX model:

```sh
sidepulsectl classify --backend mlx --json "Please approve the draft."
sidepulsectl classify --model mlx-community/Qwen2.5-0.5B-Instruct-4bit "Thanks!"
```

`--model` also accepts an absolute local model directory. The first remote-model use downloads its weights into the user's model cache. No Python runtime is used. Building the helper requires Xcode; `Scripts/package.sh --universal` includes it and the Metal resources. See [TESTING.md](TESTING.md) for coverage and the remaining validation work.
