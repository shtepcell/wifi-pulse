# Wi-Fi Pulse

A native macOS menu bar app for investigating Wi-Fi stutters while streaming games, making calls, or using other latency-sensitive apps. Record latency to your local router alongside Wi-Fi signal, link rate, traffic, and AWDL state, then compare them around a lag marker.

<img src="Assets/AppIcon.png" width="128" height="128" alt="Wi-Fi Pulse icon">

## Features

- **Always-on live monitoring:** starts when the menu app opens; router probes every 100 ms and Wi-Fi metrics once per second. No internet probes, speed tests, or Wi-Fi scans. **Pause Live** releases the microphone shortcut and stops collection.
- **Bounded live history:** the last 15 minutes stay in memory, with event and byte caps. The floating panel works over fullscreen apps; graph scrolling pauses when hidden and respects Reduce Motion.
- **Lag episodes:** press the microphone key without Fn during live monitoring, or click **Mark Lag**, to save up to 15 minutes before the marker and 30 seconds after it. Nearby markers share an episode, capped at 16 minutes total. Standard F5 is unchanged. Shortcut availability depends on the keyboard and macOS settings.
- **Bounded storage:** live episodes are limited to 100, seven days, and 500 MiB in total, including HTML and temporary output. Oldest live episodes are removed automatically; ordinary recordings are preserved.
- **Native report library:** browse recordings in a chosen folder, newest first. New sessions appear automatically while the window is open. Interrupted sessions are marked **Incomplete**.
- **Interactive analysis:** select a time range, drag to zoom, jump to a lag marker, hover to compare measurements, and switch to logarithmic latency. Median, p95, maximum, unanswered, and late-reply statistics follow the selected range.
- **Portable reports:** every session also includes a self-contained HTML report that works offline in a browser.
- **CLI:** use the same recorder from a terminal, including automatic stop and report regeneration.

![Native report library showing synthetic sample data](docs/images/reports.png)

## Requirements

- **Runtime deployment target:** macOS 13 Ventura or later. Liquid Glass is used on macOS 26+; earlier versions use a material background.
- **Build:** Xcode 26 or later with the macOS 26 SDK or newer, plus Python 3 for app packaging. The source uses system frameworks only, with no external Swift package dependencies.
- **Network:** a connected Wi-Fi interface and an IPv4 router on its local subnet. No `sudo` is required.

Runtime recording and the physical microphone key have been tested on Apple Silicon with macOS 27.0.1. Compilation checks for older deployment targets do not replace runtime testing on those systems. See [compatibility notes](docs/COMPATIBILITY.md).

## Build and run

From the repository directory:

```sh
./build-app.sh
open "dist/Wi-Fi Pulse.app"
```

This builds the menu app and CLI in release mode and packages the app in `dist/`. The app is signed locally with an ad-hoc signature; it is not a notarized distribution. Quit the app before replacing its bundle with a new build. Quitting while recording saves the session first.

The build scripts explicitly use SwiftPM's native build system to preserve the deployment target declared in `Package.swift` across toolchains. Build products are ignored by Git.

To rebuild the CLI without packaging the app:

```sh
swift build --build-system native -c release
./wifi-analyzer --help
```

The launcher builds the CLI on first use if its release binary is missing. After source changes, rebuild it explicitly.

## Use the menu app

<img src="docs/images/menu-bar.png" width="366" alt="Wi-Fi Pulse menu bar panel with live latency, signal, link rate, and traffic graphs">

1. Open the app: live monitoring starts automatically. Play or use your network normally; no session files are written until a lag is marked.
2. When a stutter occurs, press the microphone key or click **Mark Lag**. Account for your reaction time when inspecting the result.
3. Wait for the 30-second follow-up capture and **Lag episode saved**, then open **Reports**. Repeated markers extend the follow-up, within the 16-minute episode limit.
4. Choose an episode in the sidebar. Use **Lag Markers** to inspect the ten seconds on either side of a marker, or select a range yourself.

Closing the panel keeps live running. **Pause Live / Resume Live** control monitoring. Pausing, quitting, sleep, or a network change saves any marked episode with the available follow-up and an explanation if truncated. Unmarked history is discarded. After waking or a detected route change, the app retries the connection every five seconds and starts a fresh buffer; periods on different routes are not combined. Sleep is excluded from loss measurement.

**More → Settings…** provides router and interface overrides, useful when a VPN changes the default route. Pause live to edit settings. Blank fields select them automatically. The microphone key remains reserved while live is active; pause live to restore its normal action.

The menu app initially saves sessions in:

```text
~/Library/Application Support/Wi-Fi Pulse/Sessions/
```

The folder button in **Reports** changes the shared location used for browsing and future episodes. The chosen folder persists between launches. Existing recordings are not moved automatically. Live retention applies to the current folder; folders no longer selected are not maintained. The app does not install a background helper or enable launch at login.

Live buffers each hold at most 40,000 events / 12 MiB of encoded data; auxiliary probe tracking is capped too. A full buffer drops old history; a full marked episode omits further measurements and records a warning. The writer accepts at most two captures/saves combined. If it is busy, a new marker is rejected with a message. Saving and HTML generation run in the background. Only app-owned `live-UUID` folders with valid ownership markers and known regular files can be cleaned up. A damaged managed folder blocks further saves and reports an error, preserving its contents. Temporary saves count toward the storage budget and valid interrupted staging folders are cleaned up. Limits cover managed live episodes, not pre-existing manual recordings.

## Command line

```sh
# Record until Ctrl+C. Enter adds a lag marker.
./wifi-analyzer record

# Stop automatically after ten minutes.
./wifi-analyzer record --duration 600

# Override router and interface, for example when using a VPN.
./wifi-analyzer record --gateway 192.168.1.1 --interface en0

# Use fewer probes and choose a new session folder.
./wifi-analyzer record --interval-ms 200 --output sessions/evening-game

# Rebuild an HTML report, including after an interrupted recording.
./wifi-analyzer report sessions/evening-game

# Generate synthetic sample data without network requests.
./wifi-analyzer demo
```

The CLI saves sessions under `sessions/` relative to the current working directory unless `--output` is set. Session folders must not already exist. `report` replaces only `report.html`. To browse CLI sessions in the native app, choose their parent folder in **Reports**.

While recording, **Enter** adds a marker, optional text before Enter labels it, and **Ctrl+C** saves the session. The microphone shortcut belongs to the menu app; the CLI uses terminal input.

Only local IPv4 router addresses on the chosen Wi-Fi subnet are accepted. DNS names, public internet addresses, and non-Wi-Fi interfaces are rejected. A default-route change ends the session to avoid mixing network paths.

## Measurements and interpretation

| Measurement | Sampling | Meaning |
| --- | --- | --- |
| Router RTT | Every 100 ms by default | System ICMP ping, best-effort traffic class |
| Replies, timeouts, late replies | Each event | Probes have unique IDs across ICMP sequence wraparound |
| RSSI, noise, link rate, channel | Once per second | CoreWLAN readings without scanning |
| AWDL state | Once per second | Administrative UP/DOWN flag, not proof of transmission |
| Download and upload | Once per second | Total traffic across all apps on the selected interface |
| Lag markers | Manual | Time of the key press or button click |

A probe is marked timed out after one second. A later reply is retained and no longer counts as unanswered. Probes still waiting at the recording cutoff remain **pending**. Missing measurements are gaps rather than zeros, and chart aggregation preserves per-pixel minima and maxima.

High router latency near a stutter suggests a problem on the local path or with the router's handling of ICMP. Normal router latency does not rule out ISP, streaming-service, routing, or video-decoding problems. This app cannot see the router's total traffic, including traffic from a phone or other device. Link rate is the negotiated Wi-Fi transmit rate, not internet throughput. Brief AWDL changes between samples may be missed. Sampling cadence depends on system scheduling and load; correlation does not establish cause.

The recorder does not change AWDL, Wi-Fi, Bluetooth, router, or Location Services settings. If you use another tool to control AWDL, leave it in your preferred state. Recording adds some load: compare the experience with and without recording under similar conditions.

## Session files and privacy

Each CLI recording contains:

- `metadata.json`: schema version, app version, start time, OS, selected router/interface, and sampling configuration.
- `events.jsonl`: timestamped sends, replies, timeouts, measurements, markers, diagnostics, and recording boundaries.
- `ping.log`: original system ping output and its timestamps.
- `report.html`: a self-contained report containing the session data.

Live episodes use the same metadata, event, and HTML formats, plus a small ownership marker for retention. They omit the redundant raw `ping.log`; unsaved live data never reaches disk. CLI recording retains its existing full-session behavior.

The native report reads `metadata.json` and `events.jsonl` directly; it does not embed a browser. Both reports offer Clock time / Elapsed display for chart axes, hover labels, and lag markers. Clock time uses the viewing Mac’s local time zone; range fields remain seconds from the start. HTML additionally supports Option-scroll zoom. A truncated final JSONL line is ignored with a warning; malformed complete lines are rejected.

All data remains on this Mac. The app does not collect SSIDs, BSSIDs, MAC addresses, or packet contents, and does not upload recordings. Sessions do contain local router addresses, timestamps, network metrics, and marker text. Review them before sharing. The report-library screenshot uses synthetic data; the menu-bar screenshot shows a live recording.

## Development

```sh
swift test
node --test Tests/report.test.cjs

# Optional live integration test; sends probes to the local Wi-Fi router.
python3 Tests/smoke.py .build/debug/wifi-analyzer

# Optional live-buffer integration: no unmarked files, then save a marked episode.
WIFI_PULSE_LIVE_TEST=1 swift test --filter LiveRecorderIntegrationTests
```

Pause menu-app live monitoring (or stop an older app’s recording) before running the microphone hotkey test, which reserves the same physical key. To run the other tests while monitoring continues:

```sh
swift test --skip MicrophoneHotKeyTests
```

Node.js is needed only for HTML report tests. Python 3 is needed for packaging and the optional live test. Network and keyboard checks depend on the host environment.

The app version has one source: `Sources/WifiAnalyzerCore/Resources/VERSION`. The build script, CLI, and generated recording metadata use it. Session schema versioning is independent.

To regenerate the icon artwork and its macOS sizes:

```sh
swift Scripts/generate-app-icon.swift Assets
./build-app.sh
```

## License

[MIT](LICENSE) © 2026 shtepcell.
