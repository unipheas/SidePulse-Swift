# Port coverage

The comparison baseline is inteliwear/sidepulse at ffb1d3c2 plus the Done duration in 30b5e2c8. This project targets the macOS companion. The command line is named `sidepulsectl`; the app is named **SidePulse**.

| Area | Swift implementation | Verification |
| --- | --- | --- |
| Mac app | SwiftUI window, menu bar, session list, compact live LEDs for all eight states, animation and lid editors, icon, login item | Hosted views and actual UI automation for settings, profiles, navigation and status transitions |
| Agent monitor | Five hook adapters, JSONL tailing, transcript recovery, priority and completion timing | Python reference fixtures, permission and transcript tests, real CLI and visible UI transitions |
| Settings and animations | Legacy import, embedded custom programs, per-device output/brightness, profiles, lid animations | Migration, profile round trips, firmware simulator, UI profile workflow |
| Battery | Charge display, charging animation, health/cycle/temperature and charger diagnostics, automatic wattage baseline, power-change preview settings | 160 LED reference cases, 15 registry reference snapshots, live MacBook read |
| LED output | Synced mounted writes, locking, retry, battery and lid overrides | Temporary-volume tests and physical Pro; 15-second Done hold observed as 14.7 seconds |
| Read-only transports | Pro READ2ME; Dot SPC2 through IOKit | Protocol negotiation, CRC, busy/error and transaction tests; physical fallback checks pending |
| Firmware | ZIP/SHA verification, model/version checks, dry run or transfer | Simulated-volume transfer, malformed packages, official Pro package dry run; no physical flash |
| Phone and relay | QR pairing, tokens, notifications, sender/receiver commands | Real native CLI against loopback HTTP and SSE; physical mobile/Dot checks deferred |
| Power and launch | Login item, headless agent, awake assertion, opt-in closed-lid helper, eject guard | Launch rollback, power policy and exclusive ownership tests, sanitizer checks; privileged hardware checks pending |
| History and diagnostics | State, battery, charger, sleep and lid history charts, event audit with payload previews, CSV/HTML export, hook/service diagnostics and service logs | Export escaping, duplicate suppression, rotation, malformed rows and CLI tests |
| Raw FAT12 | Bounded whole-device utility preserving existing allocation | Actual disposable disk image, byte-for-byte verification and detach cleanup |
| Distribution | Universal app and CLI, MIT license, package/install scripts, targeted app registration and CI | Apple Silicon and Intel test jobs; ad-hoc signing. Developer ID signing/notarization unavailable |

See [TESTING.md](TESTING.md) for exact coverage and test limitations. The implementation does not yet have complete source coverage. Custom hook paths, bounded scans, explicit LED filenames, service scopes, Ghostty focus, legacy power-history import, reusable animations, and the notch display are implemented. The native Sparkle updater is integrated, but signed release publication and an actual update installation are still pending. Reply classification supports Apple Intelligence and the native MLX backend, including model selection, local model directories, legacy label parsing, and JSON output. The MLX prompt tokens and captured outputs match the Python reference. History ranges persist, disconnected device preferences remain editable, and menu bar sessions offer open/resume actions. Linux packaging and Python library APIs do not apply to this native macOS app.

The native setup flow now offers the original first-run choices. CLI setup installs monitoring and eject protection even when the menu-bar app is omitted. Legacy sleep/timing fields remain effective, reusable library edits preserve references, and battery output deduplicates unchanged programs and retries transport failures. The interactive terminal watch redraws its current snapshot, supports `--no-color`, and restores the cursor when cancelled. The installer restarts both existing native monitoring and eject-guard jobs after an upgrade.

Optional sleep-control failures no longer stop LED output. Phone mirroring tracks delivery per recipient, retries failed pushes after a backoff, and sends changed programs even when the agent state itself stays the same. One unavailable phone does not block the remaining recipients.

The installer supplies native `sidepulse` and `agent-monitor` compatibility commands. Paired phones retain the legacy `ios/` device identity, support individual Manual/Agent display selection and animation previews, and receive source Mac/battery metadata. Unlinking removes that phone's saved display preference. Physical mobile testing remains deferred.

Battery previews share timing across the Pro, paired phones, and notch lights. Done-to-Idle preserves the five-minute awake grace period. Lid closing respects the selected sleep policy, holds the closing animation while sleep is allowed, and releases that hold when work resumes. External-display operation on AC uses normal macOS clamshell behavior. Failed service upgrades restore the previous launch configuration, and `--no-start` does not stop a running job.

Event logs and transcript recovery share bounded file reads, with EOF/truncation checks. Preview loaders keep the existing draft or turn preview lights off if a resource is unavailable. Diagnostics display unavailable registry values explicitly instead of negative sentinels. Native URL and update-failure tests use isolated app metadata and an unreachable loopback feed; they cannot install a release.

Receiver shutdown now waits for cancellation to finish. The CLI stops its relay before returning or propagating an error, so receiver tasks cannot outlive the monitor that owns them. Both cancellation during a network request and retry backoff are tested.
