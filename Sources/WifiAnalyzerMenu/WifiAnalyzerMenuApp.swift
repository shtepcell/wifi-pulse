import SwiftUI
import AppKit
import Combine
import WifiAnalyzerCore

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
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private var controlWindow: AnalyzerPanel?
    private var phaseObserver: AnyCancellable?
    private var sizeObserver: NSKeyValueObservation?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.setAccessibilityLabel("Wi-Fi Pulse")
        item.button?.toolTip = "Wi-Fi Pulse"
        let host = NSHostingController(rootView: MenuContent(model: model, onClose: { [weak self] in self?.controlWindow?.orderOut(nil) }).fixedSize(horizontal: false, vertical: true))
        host.sizingOptions = [.preferredContentSize]
        let window = AnalyzerPanel()
        window.contentViewController = host
        window.title = "Wi-Fi Pulse"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isMovableByWindowBackground = true
        window.setFrame(NSRect(x: 0, y: 0, width: 360, height: max(250, host.view.fittingSize.height)), display: false)
        controlWindow = window
        model.onPresentReport = { [weak self] in self?.controlWindow?.orderOut(nil) }
        window.delegate = self
        sizeObserver = host.observe(\.preferredContentSize, options: [.new]) { [weak window] _, change in
            guard let window, let size = change.newValue, size.width > 0, size.height > 0 else { return }
            let top = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            window.setFrame(NSRect(x: top.x, y: top.y - size.height, width: size.width, height: size.height), display: true)
        }
        phaseObserver = model.$phase.sink { [weak self] phase in
            let image = NSImage(systemSymbolName: phase == .recording ? "record.circle" : "waveform.path.ecg", accessibilityDescription: "Wi-Fi Pulse")
            image?.isTemplate = true
            self?.statusItem?.button?.image = image
        }
        model.activateLive()
        showPanel()
    }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        model.panelVisible = window.occlusionState.contains(.visible)
    }
    @objc private func togglePanel() {
        if controlWindow?.isVisibleOnPresentationScreen == true { controlWindow?.orderOut(nil) } else { showPanel() }
    }
    private func showPanel() {
        guard let window = controlWindow else { return }
        window.present(near: statusItem?.button)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { model.prepareToQuit() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
private struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    let onClose: () -> Void
    @State private var settingsExpanded = false
    private var hasSession: Bool { model.busy || model.snapshot.sent > 0 }
    private var fresh: Bool { hasSession && model.metricsFresh }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if hasSession {
                latency.padding(.top, 26).padding(.bottom, 24)
                HStack(alignment: .top, spacing: 0) {
                    measurement("Signal", value: signal, unit: "dBm", detail: "Noise \(noise) dBm", metric: .signal)
                    Spacer(minLength: 12)
                    Rectangle().fill(.primary.opacity(0.09)).frame(width: 1, height: 79).padding(.trailing, 22)
                    measurement("Link Rate", value: link, unit: "Mbps", detail: "Channel \(channel)", metric: .link)
                }
                .padding(.bottom, 20)

                HStack {
                    Label("AWDL", systemImage: "antenna.radiowaves.left.and.right")
                    Text(awdl).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "arrow.down").font(.system(size: 10, weight: .medium))
                    Text(rate(model.snapshot.rxBytesPerSecond))
                    Image(systemName: "arrow.up").font(.system(size: 10, weight: .medium))
                    Text(rate(model.snapshot.txBytesPerSecond))
                    Text("Mbps")
                }.font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                HStack(spacing: 18) {
                    chart([.awdl], scale: .binary, label: "AWDL", stepped: true).frame(width: 80, height: 16)
                    chart([.download, .upload], scale: .zero(minimumMaximum: 1), label: "Download / upload (Mbps)").frame(height: 20)
                }.padding(.top, 5)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    Text(model.liveEnabled ? "Waiting for Wi-Fi" : "Live paused").font(.system(size: 30, weight: .light))
                    Text("The last 15 minutes stay in memory. Mark a lag to save an episode.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 28).padding(.bottom, 4)
            }

            if hasSession {
                HStack(spacing: 5) {
                    Text("\(model.snapshot.sent) probes")
                    Text("·")
                    Text("\(model.snapshot.missing) unanswered")
                    Spacer()
                    if model.snapshot.markers > 0 { Label("\(model.snapshot.markers)", systemImage: "flag") }
                }.font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().padding(.top, 9)
            }
            messages
            controls.padding(.top, 22)
            HStack {
                Button(action: model.openReport) {
                    Label("Reports", systemImage: "doc.text")
                }
                Spacer()
                if model.phase == .recording && model.microphoneShortcutAvailable {
                    Text("Mic key").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Menu {
                    Button(settingsExpanded ? "Hide Settings" : "Settings…") { settingsExpanded.toggle() }
                    Button("Browse Recordings", action: model.openRecording)
                    Button("Show Recordings in Finder", action: model.showSessions)
                    Divider()
                    Button("Quit Wi-Fi Pulse") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium)).frame(width: 24, height: 22)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More")
            }.font(.system(size: 12, weight: .medium)).buttonStyle(.plain)
                .foregroundStyle(.secondary).padding(.top, 17)
            if settingsExpanded { settings.padding(.top, 20) }
        }
        .padding(22)
        .frame(width: 360)
        .modifier(PanelMaterial())
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 15, weight: .semibold))
            Text("Wi-Fi Pulse").font(.system(size: 14, weight: .semibold))
            Spacer()
            if model.phase == .starting || model.phase == .stopping {
                ProgressView().controlSize(.mini)
            } else {
                if model.phase == .recording { Circle().fill(.red).frame(width: 5, height: 5) }
                Text(model.phase == .recording ? "Live · \(model.timeText)" : model.statusText)
                    .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 22, height: 22)
                    .background(.primary.opacity(0.06), in: Circle())
            }.buttonStyle(.plain).help("Close Panel").accessibilityLabel("Close Panel")
        }
    }
    private var latency: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.phase == .idle && hasSession ? "Last router latency" : "Router latency")
                Spacer()
                Text("Last 15 min").font(.system(size: 10))
            }.font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(latencyValue).font(.system(size: 62, weight: .light)).monospacedDigit()
                    .contentTransition(.numericText())
                if latencyValue != "—" { Text("ms").font(.system(size: 20, weight: .regular)).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }.accessibilityElement(children: .combine)
            chart([.latency], scale: .latency, label: "Router latency (ms)", gapLimit: 0.25).frame(height: 38).padding(.vertical, 5)
            Text(model.rttText == "No Reply" ? "Waiting for a router response…" : model.route)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
    private func measurement(_ title: String, value: String, unit: String, detail: String, metric: RecentMetric) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 23, weight: .medium)).monospacedDigit()
                Text(unit).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            chart(metric == .signal ? [.signal, .noise] : [.link], scale: metric == .signal ? .signal : .zero(minimumMaximum: 100), label: metric == .signal ? "Signal / noise (dBm)" : "Link rate (Mbps)").frame(height: 24)
            Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
        }.frame(minWidth: 110, alignment: .leading)
    }
    private func chart(_ metrics: [RecentMetric], scale: SparklineScale, label: String, stepped: Bool = false, gapLimit: Double = 1.75) -> some View {
        RecentSparkline(series: metrics.enumerated().map { index, metric in
            SparklineSeries(points: model.history.samples(for: metric), name: metricName(metric), color: index == 0 ? .primary : .secondary, dashed: index > 0)
        }, end: model.history.endTime, window: model.history.window, clockOrigin: model.phase == .recording && model.panelVisible ? model.historyClockOrigin : nil, scale: scale, label: label, markers: model.history.markers, stepped: stepped, gapLimit: gapLimit)
    }
    private func metricName(_ metric: RecentMetric) -> String {
        switch metric {
        case .latency: return "Latency"
        case .signal: return "Signal"
        case .noise: return "Noise"
        case .link: return "Link rate"
        case .download: return "Download"
        case .upload: return "Upload"
        case .awdl: return "AWDL"
        }
    }
    private var controls: some View {
        HStack(spacing: 10) {
            actionButton(model.liveEnabled ? "Pause Live" : "Resume Live", symbol: model.liveEnabled ? "pause.fill" : "play.fill", primary: true, disabled: model.phase == .stopping) {
                model.liveEnabled ? model.stop() : model.start()
            }
            actionButton("Mark Lag", symbol: "flag", primary: false, disabled: model.phase != .recording, action: model.markLag)
        }
    }
    @ViewBuilder private func actionButton(_ title: String, symbol: String, primary: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        if primary {
            Button(action: action) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    // Fixed colors avoid inactive-window/vibrancy dimming in the
                    // nonactivating panel. Only real disabled state lowers opacity.
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    .background(colorScheme == .dark ? Color.white : Color.black, in: Capsule())
            }.buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.4 : 1)
        } else {
            let button = Button(action: action) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity).padding(.vertical, 3)
            }.disabled(disabled).controlSize(.large)
            if #available(macOS 26.0, *) {
                button.buttonStyle(.glass).buttonBorderShape(.capsule).opacity(disabled ? 0.35 : 1)
            } else {
                button.buttonStyle(.bordered).opacity(disabled ? 0.35 : 1)
            }
        }
    }
    @ViewBuilder private var messages: some View {
        if let error = model.errorMessage { notice(error, symbol: "exclamationmark.circle", color: .red) }
        if let warning = model.hotKeyError { notice(warning, symbol: "keyboard", color: .orange) }
        if model.phase == .recording && !model.snapshot.issues.isEmpty {
            notice(model.snapshot.issues.joined(separator: "; "), symbol: "exclamationmark.triangle", color: .orange)
        }
        if model.phase == .recording && !model.metricsFresh {
            notice("Waiting for Wi-Fi measurements…", symbol: "wifi", color: .secondary)
        }
        if let remaining = model.captureRemaining {
            notice("Lag episode · \(remaining)s remaining", symbol: "flag", color: .secondary)
        } else if model.savingEpisodes > 0 {
            notice("Saving lag episode…", symbol: "square.and.arrow.down", color: .secondary)
        } else if !model.feedback.isEmpty { notice(model.feedback, symbol: "checkmark", color: .secondary) }
    }
    private func notice(_ message: String, symbol: String, color: Color) -> some View {
        Label(message, systemImage: symbol).font(.system(size: 11)).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.top, 12)
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Connection Settings").font(.system(size: 12, weight: .semibold))
            TextField("Router · Automatic", text: $model.gatewayOverride).textFieldStyle(.roundedBorder)
            TextField("Wi-Fi Interface · Automatic", text: $model.interfaceOverride).textFieldStyle(.roundedBorder)
            Text("Leave blank to detect automatically. If you use a VPN, enter your local router and Wi-Fi interface.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Recordings Folder…", action: model.chooseSessionsFolder)
            Text("Live episodes: up to 100, 7 days, or 500 MiB. Oldest episodes are deleted automatically; ordinary recordings are kept.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(model.sessionsRoot.path).font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }.disabled(model.busy)
    }
    private var latencyValue: String {
        guard hasSession else { return "—" }
        return model.rttText.hasSuffix(" ms") ? String(model.rttText.dropLast(3)) : "—"
    }
    private var signal: String { fresh ? model.snapshot.rssiDBm.map(String.init) ?? "—" : "—" }
    private var noise: String { fresh ? model.snapshot.noiseDBm.map(String.init) ?? "—" : "—" }
    private var link: String { fresh ? model.snapshot.linkMbps.map { String(format: "%.0f", $0) } ?? "—" : "—" }
    private var channel: String { fresh ? model.snapshot.channel.map(String.init) ?? "—" : "—" }
    private var awdl: String { fresh ? model.snapshot.awdlUp.map { $0 ? "On" : "Off" } ?? "—" : "—" }
    private func rate(_ value: Double?) -> String {
        guard fresh, let value else { return "—" }
        return String(format: "%.1f", value * 8 / 1e6)
    }
}
private struct PanelMaterial: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }
}
