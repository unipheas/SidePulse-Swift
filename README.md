<img src="Artwork/SidePulse.png" width="96" alt="SidePulse Swift app icon">

# SidePulse Swift

A native macOS companion for the SidePulse Pro SD card and SidePulse Dot USB device. Follow coding sessions from the menu bar, preview an animation on a virtual LED strip, or drive the lights on your desk. Requires macOS 14 or later.

[Download the Mac app](https://github.com/unipheas/SidePulse-Swift/releases) · [LED programming language](LEDS_FORMAT.md) · [Port coverage](PORTING.md)

## Try it

1. Unzip the release and drag **SidePulse Swift** into Applications. The preview build is ad-hoc signed. You can also build it locally.
2. Open the app and connect a SidePulse. **Overview** shows the detected model, firmware, and current agent state.
3. In **Settings**, set **Show Done for** to `15` seconds. The display returns to Idle when the timer expires and other agents are quiet.
4. If you already run SidePulse, Swift previews its hook events and reads your existing animation settings. Click **Use Swift for device output** when you want to try the native writer. **Restore original SidePulse service** hands the lights back. On a fresh setup, install hooks for your provider in Settings. Follow the provider's normal hook trust prompts.

The app writes its settings under `~/Library/Application Support/SidePulse Swift`. Existing Python preferences are read as initial values. A fresh installation defaults to a 20-minute Done hold. Setup is per user.

## Command line

The app includes a standalone CLI. For the examples below, set a shell variable to its installed path.

```sh
pulse="/Applications/SidePulse Swift.app/Contents/MacOS/sidepulse-swift"
"$pulse" devices
"$pulse" agent-monitor status --json
"$pulse" settings done 15
"$pulse" write --dry-run '#30D158 800ms pulse\nrepeat'
"$pulse" firmware version
"$pulse" firmware upgrade --dry-run
"$pulse" --help
```

- **Monitoring.** Hooks for Codex, Claude Code, Cursor, Grok and Junie. Optional Codex and Claude transcript recovery. A headless launch agent is available with `service start`; `service stop` removes the job.
- **Animations.** Choose a profile, edit an individual state, import or export a SidePulse profile, and preview it on a two- or eight-LED display. The preview uses the upstream firmware simulator through JavaScriptCore.
- **Hardware.** Mounted-volume LED writes, Pro READ2ME and Dot SPC2 fallback for read-only volumes, battery display, and model-specific firmware package verification. `sdejectguard start` installs an optional per-user eject guard; stop it before intentionally ejecting the Pro.
- **Mobile.** `link` displays a pairing QR code for the SidePulse mobile app. Use `links`, `push --to ID` and `unlink ID` to manage destinations. `relay send` and `relay receive` exchange agent events through a bridge channel.
- **History.** Export status changes with `history history.csv` or `history history.html`.
- **Reply classification.** On supported Macs with Apple Intelligence available, `classify` uses Apple's on-device Foundation Models framework.

## Build

Open `Package.swift` in Xcode or use a Mac with Xcode 16 or later.

```sh
swift test
Scripts/package.sh --universal
open "dist/SidePulse Swift.app"
```

The script builds both executables, includes their resources and icon, signs the bundle, and creates a ZIP in `dist`. The core uses Swift and Apple frameworks. A small C adapter provides access to the IOKit USB plug-in vtable. The build has no Python dependency.

## Attribution

This independent port is based on [inteliwear/sidepulse](https://github.com/inteliwear/sidepulse) and the configurable Done duration in [upstream PR #79](https://github.com/inteliwear/sidepulse/pull/79). The bundled LED programs, profiles, LED format reference and firmware simulator come from that MIT-licensed project. The app icon and Swift implementation are part of this repository. See [LICENSE](LICENSE).
