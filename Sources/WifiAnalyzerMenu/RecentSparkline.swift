import SwiftUI
import WifiAnalyzerCore

struct SparklineSeries {
    let points: [RecentSample]
    var name = "Metric"
    var color: Color = .primary
    var dashed = false
}
enum SparklineScale {
    case latency, signal, zero(minimumMaximum: Double), binary
    func bounds(_ values: [Double]) -> (Double, Double) {
        switch self {
        case .latency: return (0, max(10, (values.max() ?? 0) * 1.08))
        case .signal: return (min(-100, (values.min() ?? -100) - 3), max(-30, (values.max() ?? -30) + 3))
        case .zero(let minimum): return (0, max(minimum, (values.max() ?? 0) * 1.08))
        case .binary: return (-0.1, 1.1)
        }
    }
}
/// Straight segments preserve spikes; unavailable measurements break the path.
struct RecentSparkline: View {
    let series: [SparklineSeries]
    let end: Double
    let window: Double
    var clockOrigin: TimeInterval? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let scale: SparklineScale
    let label: String
    var markers: [Double] = []
    var stepped = false
    var gapLimit = 1.75

    var body: some View {
        // Scroll against the recorder's monotonic clock, independently of its
        // 2 Hz snapshots. Only these small canvases redraw at animation cadence.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: clockOrigin == nil || reduceMotion)) { _ in
            let displayEnd = reduceMotion ? end : clockOrigin.map {
                max(end, ProcessInfo.processInfo.systemUptime - $0)
            } ?? end
            plot(endingAt: displayEnd)
        }
        .accessibilityLabel("\(label), last 5 minutes")
        .accessibilityValue(summary)
        .help("\(label) · Last 5 minutes\n\(summary)\nOrange: lag markers. Red: delayed or missing replies.")
    }
    private func plot(endingAt end: Double) -> some View {
        Canvas { context, size in
            guard size.width > 4, size.height > 4 else { return }
            let start = end - window
            let values = series.flatMap { $0.points.compactMap(\.value) }
            let (low, high) = scale.bounds(values)
            let x: (Double) -> CGFloat = { 2 + CGFloat(($0 - start) / window) * (size.width - 4) }
            let y: (Double) -> CGFloat = { 2 + CGFloat(1 - ($0 - low) / (high - low)) * (size.height - 4) }
            var baseline = Path()
            baseline.move(to: CGPoint(x: 2, y: size.height - 2))
            baseline.addLine(to: CGPoint(x: size.width - 2, y: size.height - 2))
            context.stroke(baseline, with: .color(.primary.opacity(0.06)), lineWidth: 0.5)
            for time in markers where time >= start && time <= end {
                var line = Path()
                line.move(to: CGPoint(x: x(time), y: 1))
                line.addLine(to: CGPoint(x: x(time), y: size.height - 1))
                context.stroke(line, with: .color(.orange.opacity(0.55)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
            }
            for item in series {
                var path = Path()
                var previous: RecentSample?
                for point in item.points where point.time >= start && point.time <= end {
                    if point.timedOut {
                        var tick = Path()
                        tick.move(to: CGPoint(x: x(point.time), y: size.height - 7))
                        tick.addLine(to: CGPoint(x: x(point.time), y: size.height - 1))
                        context.stroke(tick, with: .color(.red.opacity(0.85)), lineWidth: 1)
                    }
                    guard let value = point.value else { previous = nil; continue }
                    let position = CGPoint(x: x(point.time), y: y(value))
                    if let previous, let oldValue = previous.value, point.time - previous.time <= gapLimit {
                        if stepped { path.addLine(to: CGPoint(x: position.x, y: y(oldValue))) }
                        path.addLine(to: position)
                    } else {
                        path.move(to: position)
                        // A lone sample remains visible without inventing a trend.
                        context.fill(Path(ellipseIn: CGRect(x: position.x - 1, y: position.y - 1, width: 2, height: 2)), with: .color(item.color.opacity(0.85)))
                    }
                    previous = point
                }
                context.stroke(path, with: .color(item.color.opacity(0.85)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round, dash: item.dashed ? [2, 3] : []))
            }
        }
        .clipped()
    }
    private var summary: String {
        series.map { item in
            let values = item.points.compactMap(\.value)
            guard let low = values.min(), let high = values.max() else { return "\(item.name): No recent measurements" }
            let style = item.dashed ? "dashed" : "solid"
            return String(format: "%@ (%@): Min %.1f · Max %.1f", item.name, style, low, high)
        }.joined(separator: "\n")
    }
}
