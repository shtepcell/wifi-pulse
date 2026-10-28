# Live Monitor Implementation Plan

> **For agentic workers:** Implement task-by-task with test-first checks in the current session. The user approved implementation; preserve existing uncommitted report changes.

**Goal:** Always-on monitoring with 15 minutes of bounded RAM history and bounded saved lag episodes.
**Architecture:** Recorder emits events without a disk writer in live mode. LiveCapture retains bounded event history and a single bounded episode; a serial, capacity-limited EpisodeStore persists compatible reports and enforces retention. AppModel owns lifecycle, retries, sleep handling, and visible progress.
**Tech Stack:** Swift, Foundation, AppKit, SwiftUI; existing system frameworks only, macOS 13+.
**Spec:** docs/superpowers/specs/2026-10-28-live-monitor-design.md

## Global Constraints
- 900 seconds of history, 30 seconds after a lag, 960 seconds maximum per episode.
- At most 100 saved live episodes, 7 days, 500 MiB including temporary output.
- Protect existing sessions and symbolic links. Preserve CLI behavior.
- No files for ordinary live sampling. No main-thread report generation.

## Review Focus
- All probes lost for days: tracker and unanswered state must remain bounded.
- Delayed metrics and late replies across window boundaries: no orphaned probe losses.
- Repeated markers and slow disk: bounded capture and save queue; reject excess work visibly.
- Sleep, quit during startup, and route changes: no leaked ping or automatic unwanted restart.
- Corrupt managed folders and symlinks: cleanup must not delete ordinary recordings or traverse links.

### Task 1: Bounded collection and episode state
Files: Ping.swift, LiveSnapshot.swift, new LiveCapture.swift; corresponding core tests.
- [x] Add failing tests for tracker pruning/IDs, loss-state eviction, 900-second history, event/byte caps, episode merging and hard cutoff, truncation, normalized times and probe references.
- [x] Run focused tests; implement bounded tracking and capture APIs; rerun focused suite.

### Task 2: Safe bounded persistence
Files: new EpisodeStore.swift; EpisodeStoreTests.swift.
- [x] Add failing tests for native/HTML report round trip, retention count/age/bytes, corrupt data, unowned files and symlink protection, failure cleanup and queue saturation.
- [x] Implement serial persistence, managed ownership markers, bounded temporary output and cleanup; run focused tests.

### Task 3: Live recorder and application lifecycle
Files: Recorder.swift, AppModel.swift, WifiAnalyzerMenuApp.swift; recorder/menu tests where independent of host networking.
- [x] Add failing tests for live journal mode producing no files and state transitions for automatic retry/pause/sleep/quit.
- [x] Make SessionWriter optional in live Recorder, publish metadata and events, bound tracker; preserve CLI recording.
- [x] Connect capture/store to automatic live, Pause/Resume, markers, saved feedback, retry, and sleep/wake; keep exit responsive while flushing bounded work.
- [x] Update 15-minute graph labels, controls and retention explanation.

### Task 4: Documentation and verification
Files: README.md and design/plan status.
- [x] Document startup, capture range, retention, keyboard reservation, sleep/network behavior and manual CLI recording.
- [x] Run full Swift suite, Node report tests, release packaging, inspect diff, and report any runtime checks not exercised.

## Verification notes
- 52 Swift tests passed with `WIFI_PULSE_LIVE_TEST=1` and `--skip MicrophoneHotKeyTests`, including the real local-router integration. The full unfiltered suite was also attempted: the microphone-key test reported `-9868` because the existing Applications build owns that shortcut. The running recording was preserved.
- Eight Node report tests passed. Read-only independent review found a quota-accounting issue with damaged live folders; it was fixed and re-reviewed successfully.
- Physical sleep/wake and actual route-switch transitions were not induced on the user’s Mac; their lifecycle state and truncation behavior have automated tests.
- Initial CLI smoke attempts exposed a pre-existing timing assumption: the script measured marker delay from process launch instead of recorder readiness, so router discovery shortened the observed session interval. The script now waits for the flushed recording-start message. Final release smoke passed: 22 sends/replies, median interval 108.91 ms; marker, Ctrl+C, regeneration, and overwrite protection verified.
- Release packaging completed at `dist/Wi-Fi Pulse.app`; ad-hoc signing and `codesign --verify --strict` passed. The installed/running Applications build was not replaced or stopped.
