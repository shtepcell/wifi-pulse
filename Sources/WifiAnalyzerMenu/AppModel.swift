import AppKit
import Combine
import Foundation
import WifiAnalyzerCore

@MainActor final class AppModel: ObservableObject {
    enum Phase { case idle, starting, recording, stopping }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var snapshot = LiveSnapshot()
    @Published private(set) var history = RecentHistory(window: 900)
    @Published private(set) var historyClockOrigin: TimeInterval?
    @Published var panelVisible = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var route = "Local router · 100 ms"
    @Published private(set) var lastReport: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var hotKeyError: String?
    @Published private(set) var feedback = ""
    @Published private(set) var liveEnabled = true
    @Published private(set) var captureRemaining: Int?
    @Published private(set) var savingEpisodes = 0
    @Published var gatewayOverride = UserDefaults.standard.string(forKey: "gatewayOverride") ?? ""
    @Published var interfaceOverride = UserDefaults.standard.string(forKey: "interfaceOverride") ?? ""
    @Published private(set) var sessionsRoot: URL
    var onPresentReport: (() -> Void)?
    private var reportWindow: SessionReportWindowController?
    private var recorder: Recorder?
    private var accumulator = LiveSnapshot()
    private var historyAccumulator = RecentHistory(window: 900)
    private var capture = LiveCapture()
    private var captureReserved = false
    private var captureRoot: URL?
    private var currentMetadata: [String: Any] = [:]
    private let store = EpisodeStore()
    private var lifecycle = LiveLifecycle()
    private var refreshTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var retryAt = Date.distantPast
    private var maintenanceAt = Date.distantPast
    private var stopReason = "Monitoring stopped"
    private var markerAccepted = false
    private var flushStarted = false
    private var discoveryInFlight = false
    private lazy var microphoneHotKey = MicrophoneHotKey { [weak self] in self?.recordLagMarker("Lag · microphone key") }
    @Published private(set) var microphoneShortcutAvailable = false

    init() {
        let path = UserDefaults.standard.string(forKey: "sessionsRoot")
        sessionsRoot = path.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Wi-Fi Pulse/Sessions", isDirectory: true)
        if let saved = UserDefaults.standard.string(forKey: "lastReport"), FileManager.default.fileExists(atPath: URL(fileURLWithPath: saved).deletingLastPathComponent().appendingPathComponent("events.jsonl").path) { lastReport = URL(fileURLWithPath: saved) }
    }
    var busy: Bool { phase != .idle }
    var timeText: String { String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60) }
    var statusText: String {
        switch phase {
        case .idle: return liveEnabled ? "Waiting for Wi-Fi" : "Live Paused"
        case .starting: return "Connecting…"
        case .recording: return "Live · \(timeText)"
        case .stopping: return "Pausing…"
        }
    }
    var metricsFresh: Bool { snapshot.lastMetricsAt.map { elapsed - $0 < 3 } ?? false }
    var rttText: String {
        guard let at = snapshot.lastReplyAt, elapsed - at < 2, let rtt = snapshot.latestLatencyMS else { return phase == .recording ? "No Reply" : "—" }
        return String(format: "%.1f ms", rtt)
    }
    func activateLive() {
        guard refreshTimer == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        })
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refreshTimer = timer; RunLoop.main.add(timer, forMode: .common)
        refresh()
    }
    private func refresh() {
        if phase == .recording || phase == .stopping {
            elapsed = recorder?.elapsed ?? elapsed
            if phase == .recording, let episode = capture.advance(to: elapsed) { save(episode) }
            snapshot = accumulator
            historyAccumulator.advance(to: elapsed)
            // Hidden panels do not need full history copies or graph invalidation.
            if panelVisible { history = historyAccumulator }
            captureRemaining = capture.captureDeadline.map { max(0, Int(ceil($0 - elapsed))) }
        }
        if lifecycle.shouldRun, phase == .idle, Date() >= retryAt { connect() }
        if Date() >= maintenanceAt {
            maintenanceAt = Date().addingTimeInterval(600)
            store.maintain(root: sessionsRoot) { [weak self] error in
                if let error { self?.errorMessage = "Live storage cleanup: \(error)" }
            }
        }
    }
    func start() {
        guard !lifecycle.quitting else { return }
        lifecycle.resume(); liveEnabled = true; retryAt = .distantPast
        if phase == .idle { connect() }
    }
    private func connect() {
        guard lifecycle.shouldRun, phase == .idle, !discoveryInFlight else { return }
        var args = ["record"]
        let gateway = gatewayOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let interface = interfaceOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !gateway.isEmpty { args += ["--gateway", gateway] }
        if !interface.isEmpty { args += ["--interface", interface] }
        let options: Options
        do { options = try Options.parse(args) }
        catch { errorMessage = String(describing: error); retryAt = Date().addingTimeInterval(5); return }
        UserDefaults.standard.set(gateway, forKey: "gatewayOverride")
        UserDefaults.standard.set(interface, forKey: "interfaceOverride")
        phase = .starting; discoveryInFlight = true
        let generation = lifecycle.generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try Recorder(options: options, live: true) }
            DispatchQueue.main.async { [weak self] in self?.begin(result, generation: generation) }
        }
    }
    private func begin(_ result: Result<Recorder, Error>, generation: Int) {
        discoveryInFlight = false
        guard lifecycle.shouldRun, lifecycle.generation == generation, phase == .starting else { return }
        do {
            let recorder = try result.get()
            self.recorder = recorder
            accumulator = LiveSnapshot(); snapshot = accumulator
            historyAccumulator = RecentHistory(window: 900); history = historyAccumulator
            capture = LiveCapture(); elapsed = 0; historyClockOrigin = nil
            currentMetadata = recorder.metadata
            errorMessage = nil; stopReason = "Network changed or monitoring stopped"
            route = "\(recorder.interfaceName) → \(recorder.gatewayAddress) · 100 ms"
            recorder.onEvent = { [weak self] event in self?.consume(event) }
            try recorder.start(interactive: false) { [weak self] result in self?.completed(result) }
            historyClockOrigin = ProcessInfo.processInfo.systemUptime - recorder.elapsed
            phase = .recording
            hotKeyError = nil
            do {
                try microphoneHotKey.setEnabled(true)
                microphoneShortcutAvailable = true
            } catch { hotKeyError = String(describing: error) }
        } catch {
            recorder?.onEvent = nil; recorder = nil; phase = .idle
            errorMessage = "Waiting for Wi-Fi: \(error)"
            retryAt = Date().addingTimeInterval(5)
        }
    }
    private func consume(_ event: [String: Any]) {
        let kind = event["kind"] as? String
        let time = event["t"] as? Double ?? elapsed
        if kind == "stopping" {
            disableMicrophoneKey(); phase = .stopping
            if let episode = capture.finish(at: time, reason: stopReason) { save(episode) }
        } else if kind != "end" {
            do {
                if let episode = try capture.consume(event) { save(episode) }
                if kind == "marker" { markerAccepted = true }
            } catch {
                errorMessage = "Live capture: \(error)"
                if !capture.isCapturing, captureReserved { store.release(); captureReserved = false }
                if kind == "marker" { return }
            }
        }
        accumulator.consume(event)
        historyAccumulator.consume(event)
    }
    func stop() {
        lifecycle.pause(); liveEnabled = false
        stopRecorder(reason: "Live paused")
    }
    private func stopRecorder(reason: String) {
        stopReason = reason; disableMicrophoneKey()
        if phase == .starting { phase = .idle }
        if phase == .recording { phase = .stopping; recorder?.stop() }
    }
    func willSleep() {
        lifecycle.sleep()
        stopRecorder(reason: "Mac went to sleep")
    }
    func didWake() {
        lifecycle.wake(); retryAt = .distantPast
        // A stale recorder must finish before a new network period can start.
        if lifecycle.shouldRun, phase == .idle { connect() }
    }
    private func disableMicrophoneKey() {
        try? microphoneHotKey.setEnabled(false); microphoneShortcutAvailable = false
    }
    func markLag() { recordLagMarker("Lag · menu app") }
    private func recordLagMarker(_ label: String) {
        guard phase == .recording, let recorder else { return }
        if let episode = capture.advance(to: recorder.elapsed) { save(episode) }
        if !capture.isCapturing {
            guard store.reserve() else { errorMessage = "Episode queue is full. Wait for a save to finish, then mark the lag again."; return }
            captureReserved = true; captureRoot = sessionsRoot
        }
        markerAccepted = false
        guard recorder.markLag(label), markerAccepted else {
            if !capture.isCapturing, captureReserved { store.release(); captureReserved = false }
            return
        }
        snapshot = accumulator; elapsed = recorder.elapsed
        historyAccumulator.advance(to: elapsed); history = historyAccumulator
        captureRemaining = capture.captureDeadline.map { max(0, Int(ceil($0 - elapsed))) }
        feedback = "Lag marked · collecting 30 seconds after the event"
    }
    private func save(_ episode: LiveEpisode) {
        guard captureReserved else { errorMessage = "Episode could not be saved: no queue reservation"; return }
        captureReserved = false; savingEpisodes += 1
        captureRemaining = nil
        store.submitReserved(episode, metadata: currentMetadata, root: captureRoot ?? sessionsRoot) { [weak self] result in
            guard let self else { return }
            self.savingEpisodes -= 1
            switch result {
            case .success(let url): self.rememberReport(url); self.feedback = "Lag episode saved"
            case .failure(let error): self.errorMessage = "Couldn’t save lag episode: \(error)"
            }
        }
    }
    private func completed(_ result: Result<URL?, Error>) {
        disableMicrophoneKey()
        elapsed = recorder?.elapsed ?? elapsed
        if let episode = capture.finish(at: elapsed, reason: stopReason) { save(episode) }
        if captureReserved { store.release(); captureReserved = false }
        snapshot = accumulator; history = historyAccumulator; historyClockOrigin = nil
        recorder?.onEvent = nil; recorder = nil; phase = .idle
        if case .failure(let error) = result { errorMessage = "Live interrupted: \(error)" }
        retryAt = Date().addingTimeInterval(5)
        if lifecycle.quitting { finishQuit() }
    }
    private func rememberReport(_ url: URL) {
        lastReport = url; UserDefaults.standard.set(url.path, forKey: "lastReport")
    }
    func openReport() {
        do { try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true) }
        catch { errorMessage = "Couldn’t open the recordings folder: \(error)"; return }
        if reportWindow == nil {
            reportWindow = SessionReportWindowController(folder: sessionsRoot) { [weak self] folder in self?.setSessionsRoot(folder) }
        }
        onPresentReport?()
        reportWindow?.open(preferred: lastReport?.deletingLastPathComponent())
    }
    func openRecording() { openReport() }
    private func setSessionsRoot(_ url: URL) {
        sessionsRoot = url.standardizedFileURL
        UserDefaults.standard.set(sessionsRoot.path, forKey: "sessionsRoot")
        reportWindow?.configureFolder(sessionsRoot)
    }
    func showSessions() {
        do {
            try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
            NSWorkspace.shared.open(sessionsRoot)
        } catch { errorMessage = "Couldn’t open the folder: \(error)" }
    }
    func chooseSessionsFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Recordings Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = sessionsRoot
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            setSessionsRoot(url)
        }
    }
    func prepareToQuit() -> NSApplication.TerminateReply {
        lifecycle.quit(); liveEnabled = false
        refreshTimer?.invalidate(); refreshTimer = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        stopRecorder(reason: "App closed")
        if recorder == nil { finishQuit() }
        return .terminateLater
    }
    private func finishQuit() {
        guard !flushStarted else { return }
        flushStarted = true
        store.flush { NSApp.reply(toApplicationShouldTerminate: true) }
    }
}
