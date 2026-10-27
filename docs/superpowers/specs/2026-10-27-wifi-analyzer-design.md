# Wi-Fi Analyzer: agreed design

## Purpose
Record macOS Wi-Fi diagnostics while playing GeForce NOW, then inspect lag events locally. AWDL suppression already runs separately; this tool observes and never changes network settings.

## Approach
The user selected a CLI recorder producing session artifacts and a local interactive HTML report. An Electron viewer was considered but deferred because rendering is unnecessary during gameplay. Browser reports avoid installing a separate viewer; documented raw data permits one later.

## Requirements
- macOS, Swift, system frameworks; no third-party runtime dependencies.
- Probe only the local IPv4 router, every 50 ms by default; configurable interval.
- Preserve individual replies, missing replies, and late replies without treating an outstanding probe as immediately lost.
- Read current Wi-Fi RSSI, noise, channel and negotiated transmit rate once per second with CoreWLAN; do not scan networks.
- Observe AWDL administrative state and network byte counters once per second.
- Enter adds a lag marker in the terminal; Ctrl+C stops gracefully and writes the report.
- Use monotonic time for durations and UTC timestamps for correlation.
- Session folder contains versioned JSONL measurements, metadata, markers and a self-contained interactive HTML report.
- Report supports selecting a lag marker, zooming and comparing synchronized plots; preserve spikes in visual downsampling.
- No external network probes, uploads, packet-content capture, or network configuration changes.
- Missing or restricted metrics are explicitly unavailable, never invented as zero. Zero RSSI/noise from CoreWLAN is unavailable.
- Explain that router ICMP latency differs from forwarded game traffic and cannot establish the cause of every lag.

## Builder decisions
Implement as a Swift package with separate recording, parsing/storage, metrics and reporting modules. Wrap the system ping process instead of requiring raw-socket privileges. Default output is a unique directory under ./sessions. Support explicit gateway/interface overrides, a finite-duration recording, offline report regeneration and a clearly labeled synthetic demo. No global hotkey in version one. The report has no remote libraries or fonts. Compilation and actual collection require a local Mac; restricted execution failures are recorded and explained.
