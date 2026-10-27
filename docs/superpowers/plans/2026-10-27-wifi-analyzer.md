# Wi-Fi Analyzer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a macOS CLI recorder and offline interactive report for Wi-Fi lag investigation.

**Architecture:** Swift executable records an append-only session stream. Independent ping and metrics workers use one monotonic timeline. A report generator reads the persisted session and embeds data into a standalone HTML viewer.

**Tech Stack:** Swift Package Manager, Foundation, CoreWLAN, Darwin, HTML/JavaScript/Canvas.

**Spec:** docs/superpowers/specs/2026-10-27-wifi-analyzer-design.md

## Global Constraints
- Probe only the local IPv4 router, every 50 ms by default; configurable interval.
- Read current Wi-Fi RSSI, noise, channel and negotiated transmit rate once per second with CoreWLAN; do not scan networks.
- Observe AWDL administrative state and network byte counters once per second.
- No external network probes, uploads, packet-content capture, or network configuration changes.
- Missing or restricted metrics are explicitly unavailable, never invented as zero.
- Session folder contains versioned JSONL measurements, metadata, markers and a self-contained interactive HTML report.

## Review Focus
- Outstanding and late replies must not become duplicate or premature loss events.
- Permission failures and absent/disconnected Wi-Fi must be visible and must not fabricate healthy metrics.
- Ctrl+C during missing replies or child-process failure must preserve data and terminate the child.
- Gateway/interface changes and counter resets must not yield misleading latency or negative traffic.
- Truncated session files and HTML-sensitive strings must not break report regeneration or inject scripts.

### Task 1: Session model and ping accounting
**Files:** Package.swift; Sources/WifiAnalyzer/Session.swift; Sources/WifiAnalyzer/Ping.swift; Tests/WifiAnalyzerTests/PingTests.swift
**Interfaces:** Codable Event with schema version, wall-clock and monotonic time; PingTracker consumes sequence/reply events and produces probe records; SessionWriter appends events serially.
- [ ] Write failing tests for normal replies, delayed/out-of-order replies, duplicates, timeouts followed by late replies, sequence wrap and shutdown with outstanding probes.
- [ ] Run swift test and verify failure precedes implementation.
- [ ] Implement event models, monotonic clock, durable JSONL writer and ping parser/accounting using observed macOS ping output formats.
- [ ] Run tests and verify all accounting assertions pass.

### Task 2: Native recording and CLI lifecycle
**Files:** Sources/WifiAnalyzer/main.swift; Sources/WifiAnalyzer/Recorder.swift; Sources/WifiAnalyzer/Metrics.swift; Tests/WifiAnalyzerTests/RecorderTests.swift
**Interfaces:** record(options) writes a session; options contain gateway, interface, interval, duration and output; MetricsSampler.sample() returns values plus availability/errors.
- [ ] Write failing tests for invalid options, gateway discovery parsing, permission failure, counter reset, route/interface changes and graceful stop.
- [ ] Implement record/help commands, route discovery with overrides, persistent system ping subprocess, CoreWLAN current-value reads, getifaddrs counters, AWDL flags and Enter markers.
- [ ] Implement Ctrl+C handling, child exit reporting, unique output directories and finalization of pending probes.
- [ ] Run unit tests and short local recordings; verify actual 50 ms probe spacing, raw artifacts, markers and absence of external targets. Document sandbox restrictions if a live probe cannot run.

### Task 3: Offline report and delivery
**Files:** Sources/WifiAnalyzer/Report.swift; Sources/WifiAnalyzer/Resources/report.html; Tests/WifiAnalyzerTests/ReportTests.swift; README.md; .gitignore
**Interfaces:** generateReport(sessionDirectory) loads versioned artifacts and writes report.html; report command regenerates; demo command generates explicitly synthetic artifacts.
- [ ] Write failing tests for truncated final JSONL line, malformed records, unavailable metrics, HTML escaping and chart aggregation that preserves extrema and losses.
- [ ] Implement synchronized interactive plots for latency/loss, RSSI/noise, link rate, traffic and AWDL; range selection/reset, marker navigation, tooltips and metric availability notices.
- [ ] Add report and demo commands; warn that ICMP is not game traffic and avoid causal claims.
- [ ] Document build, record, mark, stop, view and regeneration; timing resolution, permissions, limits and overhead comparison.
- [ ] Run swift test, release build, demo generation and report regeneration. Inspect report visually and verify marker navigation/zoom and a short live recording where permitted.

## Execution
Implement natively in the current chat. No subagent or Git worktree is needed for this empty project. Do not initialize a repository or commit unless requested. After plan review, load executing-plans, test-driven-development and verification-before-completion as applicable.
