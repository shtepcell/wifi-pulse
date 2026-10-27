import AppKit
import SwiftUI
import WifiAnalyzerCore

@MainActor final class SessionReportStore: ObservableObject {
    @Published var report: SessionAnalysis?
    @Published var error: String?
    @Published private(set) var folder: URL
    @Published private(set) var recordings: [RecordingSummary] = []
    @Published private(set) var selectedDirectory: URL?
    @Published private(set) var libraryError: String?
    @Published private(set) var refreshing = false
    @Published private(set) var loading = false
    private var task: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var timer: Timer?
    private var preferred: URL?
    init(folder: URL) { self.folder = folder.standardizedFileURL }
    func useFolder(_ folder: URL) {
        let folder = folder.standardizedFileURL
        guard folder != self.folder else { return }
        task?.cancel(); scanTask?.cancel(); refreshing = false; loading = false
        self.folder = folder; recordings = []; selectedDirectory = nil; report = nil; error = nil; libraryError = nil; preferred = nil
        if timer != nil { refresh() }
    }
    func start(preferred: URL?) {
        self.preferred = preferred?.standardizedFileURL
        if timer == nil {
            let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        refresh()
    }
    func refresh(reloadSelected: Bool = false) {
        guard !refreshing else { return }
        refreshing = true
        let root = folder
        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Result { try SessionLibrary.scan(root) } }.value
            guard !Task.isCancelled, let self, self.folder == root else { return }
            self.refreshing = false
            switch result {
            case .success(let entries):
                self.libraryError = nil
                let previous = self.recordings.first { $0.directory == self.selectedDirectory }
                if self.recordings != entries { self.recordings = entries }
                let selected = entries.first { $0.directory == self.selectedDirectory } ?? entries.first { $0.directory == self.preferred } ?? entries.first
                if let selected {
                    if self.selectedDirectory != selected.directory || self.report == nil && !self.loading && self.error == nil || reloadSelected || previous?.complete != selected.complete {
                        self.select(selected.directory)
                    }
                } else {
                    self.task?.cancel(); self.report = nil; self.error = nil; self.selectedDirectory = nil; self.loading = false
                }
            case .failure(let error): self.libraryError = error.localizedDescription
            }
        }
    }
    func select(_ directory: URL) {
        task?.cancel(); selectedDirectory = directory; report = nil; error = nil; loading = true
        task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try SessionAnalysis.load(directory: directory) } }.value
            guard !Task.isCancelled, let self, self.selectedDirectory == directory else { return }
            self.loading = false
            switch result {
            case .success(let report): self.report = report
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }
    func clear() {
        timer?.invalidate(); timer = nil; scanTask?.cancel(); task?.cancel()
        refreshing = false; loading = false; report = nil; error = nil
    }
}

@MainActor final class SessionReportWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let store: SessionReportStore
    private let onFolderChange: (URL) -> Void
    init(folder: URL, onFolderChange: @escaping (URL) -> Void) {
        store = SessionReportStore(folder: folder)
        self.onFolderChange = onFolderChange
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Recordings"
        window.minSize = NSSize(width: 920, height: 540)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentViewController = NSHostingController(rootView: SessionReportRoot(store: store))
        window.delegate = self
        let toolbar = NSToolbar(identifier: "SessionReportToolbar")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly
        window.toolbar = toolbar; window.toolbarStyle = .unified
        window.setFrameAutosaveName("SessionReport"); window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configureFolder(_ folder: URL) { store.useFolder(folder) }
    func open(preferred: URL?) {
        store.start(preferred: preferred)
        if let window, !window.isVisible, let screen = AnalyzerPanel.presentationScreen {
            let size = NSSize(width: min(1180, screen.visibleFrame.width - 40), height: min(820, screen.visibleFrame.height - 40))
            window.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2, width: size.width, height: size.height), display: false)
        }
        showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("ChooseFolder"), .init("Refresh"), .init("ShowRecording")] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier); item.target = self
        switch identifier.rawValue {
        case "ChooseFolder":
            item.label = "Choose Recordings Folder…"; item.toolTip = "Choose the folder containing your recordings"
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: item.label); item.action = #selector(chooseFolder)
        case "Refresh":
            item.label = "Refresh Recordings"; item.toolTip = "Refresh recordings and reload the selected report"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: item.label); item.action = #selector(refresh)
        case "ShowRecording":
            item.label = "Show in Finder"; item.toolTip = "Show selected recording in Finder"
            item.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: item.label); item.action = #selector(showRecording)
        default: return nil
        }
        return item
    }
    @objc func chooseFolder() {
        let panel = NSOpenPanel(); panel.title = "Choose Recordings Folder"; panel.prompt = "Choose"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.directoryURL = store.folder
        if panel.runModal() == .OK, let url = panel.url { onFolderChange(url) }
    }
    @objc private func refresh() { store.refresh(reloadSelected: true) }
    @objc private func showRecording() { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (store.selectedDirectory ?? store.folder).path) }
    func windowWillClose(_ notification: Notification) { store.clear() }
}

private struct SessionReportRoot: View {
    @ObservedObject var store: SessionReportStore
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("Recordings").font(.headline); Spacer(); if store.refreshing { ProgressView().controlSize(.mini) } }
                    Text(store.folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).help(store.folder.path)
                    Text("\(store.recordings.count) available").font(.caption).foregroundStyle(.tertiary)
                }.padding(16)
                if let error = store.libraryError { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 16).padding(.bottom, 10) }
                List(selection: Binding<URL?>(get: { store.selectedDirectory }, set: { if let directory = $0 { store.select(directory) } })) {
                    ForEach(store.recordings) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.started.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "en_US")))).font(.system(.body, weight: .medium))
                            Text("\(entry.gateway) · \(stamp(entry.duration))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            if !entry.complete { Text("Incomplete").font(.caption2).foregroundStyle(.orange) }
                        }.padding(.vertical, 5).tag(entry.directory)
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
            }.frame(minWidth: 210, idealWidth: 240, maxWidth: 320).background(.bar)
            Group {
                if let report = store.report { SessionReportContent(report: report).id(report.directory) }
                else if store.loading { ProgressView("Opening Recording…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    VStack(spacing: 12) {
                        Image(systemName: store.error == nil ? "folder" : "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.secondary)
                        Text(store.error == nil ? "No Recordings Yet" : "Couldn’t Open Recording").font(.title2)
                        Text(store.error ?? "Recordings saved in this folder will appear here automatically. Use the folder button to choose a different location.").foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 400)
                    }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(minWidth: 650)
        }
    }
}

private struct SessionReportContent: View {
    let report: SessionAnalysis
    @State private var range: ClosedRange<Double> = 0...1
    @State private var cursor: Double?
    @State private var from = "0"
    @State private var to = "0"
    @State private var logarithmic = false
    @State private var rangeError = false
    var body: some View {
            VStack(spacing: 0) {
                rangeControls
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        if report.synthetic { Label("Synthetic demonstration — not measurements of your network", systemImage: "info.circle").foregroundStyle(.orange) }
                        ForEach(report.warnings, id: \.self) { Text($0).font(.callout).foregroundStyle(.orange) }
                        statistics
                        Text("Drag across a chart to zoom. Hover to compare measurements. Orange lines mark lag events; red ticks mark delayed or missing replies.").font(.caption).foregroundStyle(.secondary)
                        plot("Router Latency", unit: "ms", metrics: [.latency], gap: max(0.5, (report.intervalMS ?? 100) / 1000 * 3), log: logarithmic)
                        plot("Wi-Fi Signal and Noise", unit: "dBm", metrics: [.signal, .noise])
                        plot("Wi-Fi Link Rate", unit: "Mbps", metrics: [.link])
                        plot("Network Traffic", unit: "Mbps", metrics: [.download, .upload])
                        plot("AWDL Status", unit: "0 Off · 1 On", metrics: [.awdl], stepped: true)
                        Text("Missing measurements remain gaps. Link rate is the negotiated Wi-Fi rate. Traffic includes all apps on this interface. AWDL is sampled once per second.").font(.caption).foregroundStyle(.secondary)
                    }.padding(24)
                }.background(Color(nsColor: .windowBackgroundColor))
            }
        .onAppear { select(0...report.duration) }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Session Overview").font(.system(size: 28, weight: .semibold))
            Text("\(report.interface) → \(report.gateway) · \(stamp(report.duration))\(report.intervalMS.map { " · \(Int($0)) ms probes" } ?? "")").foregroundStyle(.secondary)
            if !report.startedUTC.isEmpty { Text(report.startedUTC).font(.caption).foregroundStyle(.tertiary) }
            Menu {
                ForEach(report.markers) { marker in
                    Button("\(stamp(marker.time)) · \(marker.message)") {
                        select(max(0, marker.time - 10)...min(report.duration, marker.time + 10)); cursor = marker.time
                    }
                }
            } label: { Label("\(report.markers.count) Lag Markers", systemImage: "flag") }
            .fixedSize().disabled(report.markers.isEmpty)
        }.textSelection(.enabled)
    }
    private var rangeControls: some View {
        HStack(spacing: 10) {
            Text("From").foregroundStyle(.secondary)
            TextField("Start", text: $from).frame(width: 65).accessibilityLabel("Range start in seconds")
            Text("to").foregroundStyle(.secondary)
            TextField("End", text: $to).frame(width: 65).accessibilityLabel("Range end in seconds")
            Text("s").foregroundStyle(.secondary)
            Button("Apply", action: applyRange)
            Button("Full Session") { select(0...report.duration) }
            Spacer()
            Toggle("Log RTT", isOn: $logarithmic).toggleStyle(.checkbox)
        }.font(.callout).textFieldStyle(.roundedBorder).padding(14)
            .overlay(alignment: .bottomLeading) { if rangeError { Text("Enter a valid range within this recording.").font(.caption2).foregroundStyle(.red).padding(.leading, 14) } }
    }
    private var statistics: some View {
        let stats = report.statistics(in: range)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                stat("Median RTT", value: ms(stats.median))
                stat("RTT · p95", value: ms(stats.p95))
                stat("Maximum RTT", value: ms(stats.maximum))
                stat("Unanswered", value: "\(stats.missing)")
                stat("Late Replies", value: "\(stats.late)")
            }
            Text("\(stamp(range.lowerBound)) – \(stamp(range.upperBound)) · \(stats.sent) probes · \(stats.pending) pending").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
    private func stat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 21, weight: .medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func plot(_ title: String, unit: String, metrics: [RecentMetric], gap: Double = 1.75, stepped: Bool = false, log: Bool = false) -> some View {
        let series = metrics.map { ReportChartSeries(name: name($0), points: report.series[$0] ?? []) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack { Text(title).font(.headline); Spacer(); Text(unit).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 18) {
                ForEach(Array(series.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 5) {
                        Circle().fill(index == 0 ? Color.blue : .orange).frame(width: 6, height: 6)
                        Text(item.name)
                        if let cursor { Text(nearest(item.points, to: cursor).map { String(format: "%.1f", $0) } ?? "—").monospacedDigit() }
                    }
                }
                Spacer()
                if let cursor { Text(stamp(cursor)).monospacedDigit() }
            }.font(.caption).foregroundStyle(.secondary).frame(height: 16)
            ReportChart(series: series, range: range, markers: report.markers, cursor: $cursor, select: select, gapLimit: gap, stepped: stepped, logarithmic: log, signal: metrics.first == .signal, binary: metrics.first == .awdl).frame(height: 150)
        }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 12))
    }
    private func select(_ value: ClosedRange<Double>) {
        range = value; from = String(format: "%.1f", value.lowerBound); to = String(format: "%.1f", value.upperBound); rangeError = false
    }
    private func applyRange() {
        guard let a = Double(from), let b = Double(to), a.isFinite, b.isFinite, a >= 0, b <= report.duration, b > a else { rangeError = true; return }
        select(a...b)
    }
    private func nearest(_ points: [RecentSample], to time: Double) -> Double? {
        var low = 0, high = points.count
        while low < high { let mid = (low + high) / 2; if points[mid].time < time { low = mid + 1 } else { high = mid } }
        let candidates = [low - 1, low].filter { points.indices.contains($0) }
        guard let i = candidates.min(by: { abs(points[$0].time - time) < abs(points[$1].time - time) }), abs(points[i].time - time) < 2 else { return nil }
        return points[i].value
    }
    private func name(_ metric: RecentMetric) -> String {
        switch metric { case .latency: return "Replies"; case .signal: return "Signal"; case .noise: return "Noise"; case .link: return "Link Rate"; case .download: return "Download"; case .upload: return "Upload"; case .awdl: return "AWDL" }
    }
    private func ms(_ value: Double?) -> String { value.map { String(format: "%.1f ms", $0) } ?? "—" }
}
private func stamp(_ time: Double) -> String { String(format: "%02d:%02d", Int(time) / 60, Int(time) % 60) }

struct ReportChartSeries { let name: String; let points: [RecentSample] }
private struct ReportChart: View {
    let series: [ReportChartSeries]
    let range: ClosedRange<Double>
    let markers: [AnalysisMarker]
    @Binding var cursor: Double?
    let select: (ClosedRange<Double>) -> Void
    let gapLimit: Double
    let stepped: Bool
    let logarithmic: Bool
    let signal: Bool
    let binary: Bool
    @State private var drag: (Double, Double)?
    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 52)
            let height = geometry.size.height - 26
            let span = max(0.001, range.upperBound - range.lowerBound)
            Canvas { context, size in
                let visible = series.map { $0.points.filter { range.contains($0.time) } }
                let values = visible.flatMap { $0.compactMap(\.value) }
                let low = binary ? -0.1 : signal ? min(-100, (values.min() ?? -100) - 3) : 0
                let high = binary ? 1.1 : signal ? max(-25, (values.max() ?? -25) + 3) : max(1, (values.max() ?? 0) * 1.08)
                func transform(_ value: Double) -> Double { logarithmic ? log10(max(0, value) + 1) : value }
                func y(_ value: Double) -> CGFloat { 4 + CGFloat(1 - (transform(value) - transform(low)) / max(0.001, transform(high) - transform(low))) * (height - 8) }
                func x(_ time: Double) -> CGFloat { 44 + CGFloat((time - range.lowerBound) / span) * width }
                for value in (binary ? [0.0, 1.0] : [low, (low + high) / 2, high]) {
                    let yy = y(value)
                    var line = Path(); line.move(to: CGPoint(x: 44, y: yy)); line.addLine(to: CGPoint(x: 44 + width, y: yy))
                    context.stroke(line, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
                    context.draw(Text(String(format: "%.0f", value)).font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: 36, y: yy), anchor: .trailing)
                }
                for marker in markers where range.contains(marker.time) {
                    var line = Path(); line.move(to: CGPoint(x: x(marker.time), y: 0)); line.addLine(to: CGPoint(x: x(marker.time), y: height))
                    context.stroke(line, with: .color(.orange.opacity(0.65)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                for (index, points) in visible.enumerated() {
                    let columns = SessionAnalysis.envelope(points, in: range, columns: Int(width), gapLimit: gapLimit)
                    var path = Path(), previous: PlotColumn?
                    for column in columns {
                        let xx = 44 + CGFloat(column.column)
                        if let previous, previous.segment == column.segment, column.firstTime - previous.lastTime <= gapLimit {
                            if stepped { path.addLine(to: CGPoint(x: xx, y: y(previous.last))) }
                            path.addLine(to: CGPoint(x: xx, y: y(column.first)))
                        } else {
                            path.move(to: CGPoint(x: xx, y: y(column.first)))
                            // A single reply or metric sample must stay visible.
                            context.fill(Path(ellipseIn: CGRect(x: xx - 1.3, y: y(column.first) - 1.3, width: 2.6, height: 2.6)), with: .color(index == 0 ? .blue : .orange))
                        }
                        path.addLine(to: CGPoint(x: xx, y: y(column.minimum)))
                        path.addLine(to: CGPoint(x: xx, y: y(column.maximum)))
                        path.addLine(to: CGPoint(x: xx, y: y(column.last)))
                        previous = column
                    }
                    context.stroke(path, with: .color(index == 0 ? .blue : .orange), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: index == 0 ? [] : [3, 2]))
                    for point in points where point.timedOut {
                        var tick = Path(); tick.move(to: CGPoint(x: x(point.time), y: height - 7)); tick.addLine(to: CGPoint(x: x(point.time), y: height))
                        context.stroke(tick, with: .color(.red), lineWidth: 1)
                    }
                }
                if values.isEmpty {
                    context.draw(Text("No measurements in this range").font(.callout).foregroundColor(.secondary), at: CGPoint(x: 44 + width / 2, y: height / 2))
                }
                if let cursor, range.contains(cursor) {
                    var line = Path(); line.move(to: CGPoint(x: x(cursor), y: 0)); line.addLine(to: CGPoint(x: x(cursor), y: height))
                    context.stroke(line, with: .color(.primary.opacity(0.35)), lineWidth: 0.7)
                }
                if let drag { let a = x(min(drag.0, drag.1)), b = x(max(drag.0, drag.1)); context.fill(Path(CGRect(x: a, y: 0, width: b - a, height: height)), with: .color(.accentColor.opacity(0.13))) }
                for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                    let time = range.lowerBound + span * fraction
                    context.draw(Text(stamp(time)).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: x(time), y: height + 14), anchor: fraction == 1 ? .trailing : .center)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase { case .active(let location): cursor = time(at: location.x, width: width); case .ended: cursor = nil }
            }
            .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                drag = (time(at: value.startLocation.x, width: width), time(at: value.location.x, width: width))
            }.onEnded { _ in
                if let drag, abs(drag.1 - drag.0) > 0.1 { select(min(drag.0, drag.1)...max(drag.0, drag.1)) }
                drag = nil
            })
            .accessibilityLabel("\(series.map(\.name).joined(separator: ", ")) chart. Range \(stamp(range.lowerBound)) to \(stamp(range.upperBound)). Use the range fields to zoom.")
        }
    }
    private func time(at x: CGFloat, width: CGFloat) -> Double {
        range.lowerBound + Double(max(0, min(1, (x - 44) / width))) * (range.upperBound - range.lowerBound)
    }
}
