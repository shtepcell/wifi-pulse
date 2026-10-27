import SwiftUI
import AppKit
import Combine

@main struct WifiAnalyzerMenuApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

/// A small SwiftUI control window is opened from a persistent menu-bar item.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private var controlWindow: NSWindow?
    private var phaseObserver: AnyCancellable?
    private var sizeObserver: NSKeyValueObservation?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.setAccessibilityLabel("Wi-Fi Analyzer")
        item.button?.toolTip = "Wi-Fi Analyzer"
        let host = NSHostingController(rootView: MenuContent(model: model).fixedSize(horizontal: false, vertical: true))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.title = "Wi-Fi Analyzer"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 380, height: max(350, host.view.fittingSize.height)))
        controlWindow = window
        sizeObserver = host.observe(\.preferredContentSize, options: [.new]) { [weak window] _, change in
            guard let window, let size = change.newValue, size.width > 0, size.height > 0 else { return }
            let top = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            window.setContentSize(size)
            window.setFrameTopLeftPoint(top)
        }
        phaseObserver = model.$phase.sink { [weak self] phase in
            let image = NSImage(systemSymbolName: phase == .recording ? "record.circle" : "wifi", accessibilityDescription: "Wi-Fi Analyzer")
            image?.isTemplate = true
            self?.statusItem?.button?.image = image
        }
        showPanel()
    }
    @objc private func togglePanel() {
        if controlWindow?.isVisible == true { controlWindow?.orderOut(nil) } else { showPanel() }
    }
    private func showPanel() {
        guard let window = controlWindow else { return }
        if !window.isVisible, let screen = statusItem?.button?.window?.screen ?? NSScreen.main {
            window.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - window.frame.width - 12, y: screen.visibleFrame.maxY - 8))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { model.prepareToQuit() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
private struct MenuContent: View {
    @ObservedObject var model: AppModel
    @State private var settingsExpanded = false
    private var hasSession: Bool { model.busy || model.snapshot.sent > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "wifi")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Wi-Fi Analyzer").font(.system(.title3, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle().fill(model.phase == .recording ? Color.red : Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
                        Text(model.statusText).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.phase == .starting || model.phase == .stopping { ProgressView().controlSize(.small) }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.phase == .idle && hasSession ? "Last Router Latency" : "Router Latency")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if model.busy { Text(model.timeText).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
                Text(hasSession ? model.rttText : "—")
                    .font(.system(size: 32, weight: .medium)).monospacedDigit()
                    .contentTransition(.numericText())
                HStack {
                    Label(model.route, systemImage: "network").lineLimit(1)
                    Spacer(minLength: 0)
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(14).nativeCard()

            VStack(spacing: 0) {
                metricRow("Signal / Noise", value: signalText)
                Divider().padding(.horizontal, 12)
                metricRow("Link Rate", value: linkText)
                Divider().padding(.horizontal, 12)
                metricRow("Channel", value: channelText)
                Divider().padding(.horizontal, 12)
                metricRow("AWDL", value: awdlText)
                Divider().padding(.horizontal, 12)
                metricRow("Download / Upload", value: trafficText)
            }.nativeCard()

            if hasSession {
                HStack {
                    Text("\(model.snapshot.sent) probes")
                    Text("·")
                    Text("\(model.snapshot.missing) unanswered")
                    Spacer()
                    if model.snapshot.markers > 0 { Label("\(model.snapshot.markers)", systemImage: "flag") }
                }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if model.phase == .recording && !model.metricsFresh {
                Text("Waiting for current Wi-Fi measurements…").font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage { notice(error, symbol: "exclamationmark.circle", color: .red) }
            if let warning = model.hotKeyError { notice(warning, symbol: "keyboard", color: .orange) }
            if model.phase == .recording, !model.snapshot.issues.isEmpty {
                notice(model.snapshot.issues.joined(separator: "; "), symbol: "exclamationmark.triangle", color: .orange)
            }
            if !model.feedback.isEmpty { notice(model.feedback, symbol: "checkmark.circle", color: .secondary) }

            VStack(spacing: 8) {
                Button(action: { model.phase == .recording ? model.stop() : model.start() }) {
                    Label(model.phase == .recording ? "Stop Recording" : "Start Recording", systemImage: model.phase == .recording ? "stop.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.phase == .starting || model.phase == .stopping)
                Button(action: model.markLag) {
                    HStack {
                        Label("Mark Lag", systemImage: "flag")
                        Spacer()
                        Text(GlobalHotKey.display).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).controlSize(.large).disabled(model.phase != .recording)
            }
            HStack {
                Button(action: model.openReport) { Label("Open Report", systemImage: "doc.richtext") }
                    .disabled(model.lastReport == nil)
                Spacer()
                Button(action: model.showSessions) { Image(systemName: "folder") }
                    .help("Show Recordings in Finder")
                    .accessibilityLabel("Show Recordings in Finder")
            }.buttonStyle(.borderless).font(.subheadline)
            Divider()
            DisclosureGroup("Settings", isExpanded: $settingsExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Router").font(.caption).foregroundStyle(.secondary)
                        TextField("Automatic", text: $model.gatewayOverride).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Wi-Fi Interface").font(.caption).foregroundStyle(.secondary)
                        TextField("Automatic", text: $model.interfaceOverride).textFieldStyle(.roundedBorder)
                    }
                    Text("Leave blank to detect automatically. If you use a VPN, enter your local router and Wi-Fi interface.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Recordings Folder…", action: model.chooseSessionsFolder)
                    Text(model.sessionsRoot.path).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }.padding(.top, 10).disabled(model.busy)
            }.font(.subheadline)
            HStack {
                Text("Local measurements only").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit Wi-Fi Analyzer") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(18).frame(width: 380)
            .background(Color(nsColor: .windowBackgroundColor))
    }
    private func metricRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).monospacedDigit()
        }.font(.subheadline).padding(.horizontal, 12).padding(.vertical, 9)
    }
    private func notice(_ message: String, symbol: String, color: Color) -> some View {
        Label(message, systemImage: symbol).font(.caption).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
    private var signalText: String {
        guard hasSession, model.metricsFresh else { return "—" }
        return "\(model.snapshot.rssiDBm.map(String.init) ?? "—") / \(model.snapshot.noiseDBm.map(String.init) ?? "—") dBm"
    }
    private var linkText: String {
        guard hasSession, model.metricsFresh else { return "—" }
        return model.snapshot.linkMbps.map { String(format: "%.0f Mbps", $0) } ?? "—"
    }
    private var channelText: String {
        guard hasSession, model.metricsFresh else { return "—" }
        return model.snapshot.channel.map(String.init) ?? "—"
    }
    private var awdlText: String {
        guard hasSession, model.metricsFresh else { return "—" }
        return model.snapshot.awdlUp.map { $0 ? "On" : "Off" } ?? "—"
    }
    private var trafficText: String {
        guard hasSession, model.metricsFresh else { return "—" }
        let rx = model.snapshot.rxBytesPerSecond.map { String(format: "%.1f", $0 * 8 / 1e6) } ?? "—"
        let tx = model.snapshot.txBytesPerSecond.map { String(format: "%.1f", $0 * 8 / 1e6) } ?? "—"
        return "\(rx) / \(tx) Mbps"
    }
}
private extension View {
    func nativeCard() -> some View {
        self.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }
}
