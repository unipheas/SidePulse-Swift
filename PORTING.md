# Port coverage

The comparison baseline is inteliwear/sidepulse at ffb1d3c2 plus the Done duration in 30b5e2c8. This release targets the macOS companion. Its command line uses the name sidepulsectl so both implementations can be present.

| Area | Swift implementation | Verification |
| --- | --- | --- |
| Mac app | SwiftUI window, menu-bar status, session list, virtual LEDs, animation editor, app icon, login item | App launched on Apple Silicon and detected a SidePulse Pro running firmware 1.1.0 |
| Agent monitor | Five hook adapters, JSONL tailing, transcript recovery, state priority, completion timing | Event fixtures, UI readback and live Codex activity |
| Settings and animation | Legacy settings import, per-device output, custom programs, built-in and saved profiles, import/export | Firmware simulator and configuration tests |
| LED output | Synced writes to mounted volumes, per-device locking, brightness, battery mode | Temporary volume writes and a mounted Pro test. With a 15-second setting, All Clear returned to Night Patrol in 14.7 seconds measured between device-file observations |
| Read-only transports | Pro READ2ME with aligned uncached reads; Dot SPC2 through IOKit | Implemented; physical read-only Pro and Dot verification pending |
| Firmware | List versions, verify ZIPs and SHA-256, select device and model, dry run or transfer | Official Pro ZIP verified against the mounted card with dry run |
| Phone and relay | QR pairing, token storage, explicit notifications, receiver and sender commands | Wire-format implementation; paired iPhone, Android and remote receiver tests pending |
| Power and launch | Login item, headless launch agent, awake assertion, opt-in privileged closed-lid policy and SD eject veto | Build and local battery read; sleep/wake and eject hardware testing pending |
| Distribution | Universal macOS app and CLI, MIT license, reproducible package script, GitHub Actions | Apple Silicon build and signature verification; Intel execution and notarization pending |

The upstream Python suite is a behavior reference. Swift tests run against the native implementation. Linux packaging, the Python library API, and the optional MLX classifier are outside this macOS build. The native classifier uses Apple Intelligence. The raw FAT12 utility and privileged closed-lid operation have not been exercised against a live disk or system power setting. Updates open the project release page. Upstream options, diagnostics, service internals and developer scripts do not have one-to-one coverage.
