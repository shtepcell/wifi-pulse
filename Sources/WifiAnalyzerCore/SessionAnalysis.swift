import Foundation

public struct AnalysisProbe: Sendable {
    public let time: Double
    public var latency: Double?
    public var timedOut = false
}
public struct AnalysisMarker: Identifiable, Sendable {
    public let id: Int
    public let time: Double
    public let message: String
}
public struct AnalysisStatistics: Sendable {
    public let sent: Int
    public let missing: Int
    public let pending: Int
    public let late: Int
    public let median: Double?
    public let p95: Double?
    public let maximum: Double?
}
public struct PlotColumn: Sendable {
    public let column: Int
    public let segment: Int
    public var first: Double
    public var last: Double
    public var minimum: Double
    public var maximum: Double
    public var firstTime: Double
    public var lastTime: Double
}
/// Native report data, independent of the generated HTML and its JavaScript.
public struct SessionAnalysis: Sendable {
    public let directory: URL
    public let gateway: String
    public let interface: String
    public let startedUTC: String
    public let intervalMS: Double?
    public let synthetic: Bool
    public let duration: Double
    public let probes: [AnalysisProbe]
    public let series: [RecentMetric: [RecentSample]]
    public let markers: [AnalysisMarker]
    public let warnings: [String]

    public static func load(directory: URL) throws -> SessionAnalysis {
        let metadataData = try Data(contentsOf: directory.appendingPathComponent("metadata.json"))
        guard let meta = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any], meta["schemaVersion"] as? Int == 1 else { throw AnalyzerError("Unsupported recording schema") }
        let data = try Data(contentsOf: directory.appendingPathComponent("events.jsonl"))
        let events = try SessionIO.readEvents(data)
        var probes: [Int: AnalysisProbe] = [:]
        var series: [RecentMetric: [RecentSample]] = [:]
        var markers: [AnalysisMarker] = []
        var warnings: [String] = []
        func number(_ value: Any?) -> Double? {
            guard let n = value as? NSNumber, n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        for (index, event) in events.enumerated() {
            let time = event["t"] as! Double // SessionIO validates the schema and timestamp.
            switch event["kind"] as? String {
            case "send":
                if let id = event["id"] as? Int { probes[id] = AnalysisProbe(time: time) }
            case "reply":
                if let id = event["id"] as? Int, probes[id] != nil {
                    probes[id]?.latency = number(event["latencyMS"])
                    if event["late"] as? Bool == true { probes[id]?.timedOut = true }
                }
            case "timeout":
                if let id = event["id"] as? Int, probes[id] != nil { probes[id]?.timedOut = true }
            case "metrics":
                let values = event["values"] as? [String: Any] ?? [:]
                let fields: [(RecentMetric, String, Double)] = [(.signal,"rssiDBm",1),(.noise,"noiseDBm",1),(.link,"linkMbps",1),(.download,"rxBytesPerSecond",8/1e6),(.upload,"txBytesPerSecond",8/1e6)]
                for (metric, field, scale) in fields {
                    series[metric, default: []].append(RecentSample(time: time, value: number(values[field]).map { $0 * scale }, timedOut: false))
                }
                series[.awdl, default: []].append(RecentSample(time: time, value: (values["awdlUp"] as? Bool).map { $0 ? 1 : 0 }, timedOut: false))
            case "marker": markers.append(AnalysisMarker(id: index, time: time, message: event["message"] as? String ?? "Lag"))
            default: break
            }
        }
        let sorted = probes.values.sorted { $0.time < $1.time }
        series[.latency] = sorted.map { RecentSample(time: $0.time, value: $0.latency, timedOut: $0.timedOut) }
        for metric in Array(series.keys) { series[metric]?.sort { $0.time < $1.time } }
        if !events.contains(where: { $0["kind"] as? String == "end" }) { warnings.append("Recording was interrupted. Probes without a timeout remain pending.") }
        if !data.isEmpty && data.last != 10 { warnings.append("The final event line may be incomplete.") }
        return SessionAnalysis(directory: directory, gateway: meta["gateway"] as? String ?? "Unknown router", interface: meta["interface"] as? String ?? "—", startedUTC: meta["startedUTC"] as? String ?? "", intervalMS: number(meta["requestedIntervalMS"]), synthetic: meta["synthetic"] as? Bool ?? false, duration: max(1, events.compactMap { $0["t"] as? Double }.max() ?? 0), probes: sorted, series: series, markers: markers.sorted { $0.time < $1.time }, warnings: warnings)
    }
    public func statistics(in range: ClosedRange<Double>) -> AnalysisStatistics {
        let selected = probes.filter { range.contains($0.time) }
        let values = selected.compactMap(\.latency).sorted()
        func percentile(_ q: Double) -> Double? { values.isEmpty ? nil : values[max(0, Int(ceil(Double(values.count) * q)) - 1)] }
        return AnalysisStatistics(sent: selected.count, missing: selected.filter { $0.latency == nil && $0.timedOut }.count, pending: selected.filter { $0.latency == nil && !$0.timedOut }.count, late: selected.filter { $0.latency != nil && $0.timedOut }.count, median: percentile(0.5), p95: percentile(0.95), maximum: values.last)
    }
    /// Per-pixel extrema keep rare spikes visible; missing values start a new segment.
    public static func envelope(_ points: [RecentSample], in range: ClosedRange<Double>, columns: Int, gapLimit: Double = 1.75) -> [PlotColumn] {
        let width = max(1, columns), span = max(0.001, range.upperBound - range.lowerBound)
        var result: [PlotColumn] = [], segment = 0
        var previousTime: Double?
        for point in points where range.contains(point.time) {
            if let previousTime, point.time - previousTime > gapLimit { segment += 1 }
            previousTime = point.time
            guard let value = point.value else { segment += 1; continue }
            let column = max(0, min(width - 1, Int((point.time - range.lowerBound) / span * Double(width))))
            if let last = result.last, last.column == column && last.segment == segment {
                let i = result.count - 1
                result[i].minimum = min(last.minimum, value); result[i].maximum = max(last.maximum, value)
                result[i].last = value; result[i].lastTime = point.time
            } else {
                result.append(PlotColumn(column: column, segment: segment, first: value, last: value, minimum: value, maximum: value, firstTime: point.time, lastTime: point.time))
            }
        }
        return result
    }
}
