import AppKit
import Combine
import Foundation
import WifiAnalyzerCore

@MainActor final class AppModel: ObservableObject {
    enum Phase { case idle, starting, recording, stopping }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var snapshot = LiveSnapshot()
    @Published private(set) var elapsed = 0.0
    @Published private(set) var route = "Local router · 50 ms"
    @Published private(set) var lastReport: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var hotKeyError: String?
    @Published private(set) var feedback = ""
    @Published var gatewayOverride = UserDefaults.standard.string(forKey: "gatewayOverride") ?? ""
    @Published var interfaceOverride = UserDefaults.standard.string(forKey: "interfaceOverride") ?? ""
    @Published private(set) var sessionsRoot: URL
    private var recorder: Recorder?
    private var accumulator = LiveSnapshot()
    private var refreshTimer: Timer?
    private var hotKey: GlobalHotKey?
    private lazy var microphoneHotKey = MicrophoneHotKey { [weak self] in self?.recordLagMarker("Lag · microphone key") }
    @Published private(set) var microphoneShortcutAvailable = false
    var markShortcutText: String { microphoneShortcutAvailable ? "Mic key · \(GlobalHotKey.display)" : GlobalHotKey.display }
    private var feedbackToken = UUID()
    private var quitAfterSave = false

    init() {
        let defaultRoot = Bundle.main.object(forInfoDictionaryKey: "WASessionsDirectory") as? String
        let path = UserDefaults.standard.string(forKey: "sessionsRoot") ?? defaultRoot
        sessionsRoot = path.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Wi-Fi Analyzer/Sessions", isDirectory: true)
        if let saved = UserDefaults.standard.string(forKey: "lastReport"), FileManager.default.fileExists(atPath: saved) { lastReport = URL(fileURLWithPath: saved) }
        do { hotKey = try GlobalHotKey { [weak self] in self?.markLag() } }
        catch { hotKeyError = String(describing: error) }
    }
    var busy: Bool { phase != .idle }
    var timeText: String { String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60) }
    var statusText: String {
        switch phase {
        case .idle: return "Ready to Record"
        case .starting: return "Connecting…"
        case .recording: return "Recording · \(timeText)"
        case .stopping: return "Saving Report…"
        }
    }
    var metricsFresh: Bool { snapshot.lastMetricsAt.map { elapsed - $0 < 3 } ?? false }
    var rttText: String {
        guard let at = snapshot.lastReplyAt, elapsed - at < 2, let rtt = snapshot.latestLatencyMS else { return phase == .recording ? "No Reply" : "—" }
        return String(format: "%.1f ms", rtt)
    }
    func start() {
        guard phase == .idle else { return }
        errorMessage = nil; feedback = ""; elapsed = 0
        accumulator = LiveSnapshot(); snapshot = accumulator
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = sessionsRoot.appendingPathComponent("session-\(stamp)-\(UUID().uuidString.prefix(6))")
        var args = ["record", "--output", folder.path]
        let gateway = gatewayOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let interface = interfaceOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !gateway.isEmpty { args += ["--gateway", gateway] }
        if !interface.isEmpty { args += ["--interface", interface] }
        let options: Options
        do { options = try Options.parse(args) }
        catch { errorMessage = String(describing: error); return }
        UserDefaults.standard.set(gateway, forKey: "gatewayOverride")
        UserDefaults.standard.set(interface, forKey: "interfaceOverride")
        phase = .starting
        // Router discovery and CoreWLAN initialization must not block the popover.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Recorder(options: options) }
            DispatchQueue.main.async { [weak self] in self?.begin(result) }
        }
    }
    private func begin(_ result: Result<Recorder, Error>) {
        do {
            let recorder = try result.get()
            self.recorder = recorder
            route = "\(recorder.interfaceName) → \(recorder.gatewayAddress) · 50 ms"
            recorder.onEvent = { [weak self] event in
                guard let self else { return }
                self.accumulator.consume(event)
                if event["kind"] as? String == "stopping" { self.disableMicrophoneKey(); self.phase = .stopping }
            }
            try recorder.start(interactive: false) { [weak self] result in self?.completed(result) }
            phase = .recording
            do {
                try microphoneHotKey.setEnabled(true)
                microphoneShortcutAvailable = true
            } catch { hotKeyError = String(describing: error) }
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.snapshot = self.accumulator
                    self.elapsed = self.recorder?.elapsed ?? self.elapsed
                }
            }
            refreshTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch {
            recorder = nil; phase = .idle
            errorMessage = "Couldn’t start recording: \(error)"
        }
    }
    func stop() {
        guard phase == .recording else { return }
        disableMicrophoneKey()
        phase = .stopping; recorder?.stop()
    }
    private func disableMicrophoneKey() {
        try? microphoneHotKey.setEnabled(false)
        microphoneShortcutAvailable = false
    }
    func markLag() { recordLagMarker("Lag · menu app") }
    private func recordLagMarker(_ label: String) {
        guard phase == .recording, let recorder, recorder.markLag(label) else { return }
        snapshot = accumulator; elapsed = recorder.elapsed
        let token = UUID(); feedbackToken = token
        feedback = "Marker \(accumulator.markers) · \(timeText)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.feedbackToken == token { self?.feedback = "" }
        }
    }
    private func completed(_ result: Result<URL, Error>) {
        disableMicrophoneKey()
        refreshTimer?.invalidate(); refreshTimer = nil
        snapshot = accumulator; elapsed = recorder?.elapsed ?? elapsed
        let possibleReport = recorder?.sessionDirectory.appendingPathComponent("report.html")
        recorder?.onEvent = nil; recorder = nil; phase = .idle
        switch result {
        case .success(let url):
            rememberReport(url); feedback = "Report Saved"
        case .failure(let error):
            errorMessage = "Recording ended with an error: \(error)"
            if let possibleReport, FileManager.default.fileExists(atPath: possibleReport.path) { rememberReport(possibleReport) }
        }
        if quitAfterSave { NSApp.reply(toApplicationShouldTerminate: true) }
    }
    private func rememberReport(_ url: URL) {
        lastReport = url; UserDefaults.standard.set(url.path, forKey: "lastReport")
    }
    func openReport() {
        guard let lastReport else { return }
        if !NSWorkspace.shared.open(lastReport) { errorMessage = "The report couldn’t be opened. It may have been moved." }
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
            sessionsRoot = url; UserDefaults.standard.set(url.path, forKey: "sessionsRoot")
        }
    }
    func prepareToQuit() -> NSApplication.TerminateReply {
        guard recorder != nil else { return .terminateNow }
        quitAfterSave = true
        if phase == .recording { stop() }
        return .terminateLater
    }
}
