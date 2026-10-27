import Foundation

public enum RecentMetric: CaseIterable, Sendable {
    case latency, signal, noise, link, download, upload, awdl
}
public struct RecentSample: Equatable, Sendable {
    public let time: Double
    public let value: Double?
    public let timedOut: Bool
}
/// Bounded live history. Original measurements remain in the session artifacts.
public struct RecentHistory {
    public let window: Double
    public private(set) var endTime = 0.0
    private var latency: [Int: RecentSample] = [:]
    private var series: [RecentMetric: [RecentSample]] = [:]
    private var markerTimes: [Double] = []
    private var lastTrim = -Double.infinity
    public init(window: Double = 300) {
        precondition(window.isFinite && window > 0)
        self.window = window
    }
    public mutating func consume(_ event: [String: Any]) {
        guard let time = number(event["t"]), time >= 0 else { return }
        advance(to: time)
        switch event["kind"] as? String {
        case "reply", "timeout":
            guard let id = event["id"] as? Int else { return }
            let sent = number(event["sent"]) ?? time
            guard sent >= endTime - window else { return }
            let old = latency[id]
            if event["kind"] as? String == "timeout" {
                latency[id] = RecentSample(time: sent, value: old?.value, timedOut: true)
            } else {
                latency[id] = RecentSample(time: sent, value: number(event["latencyMS"]), timedOut: old?.timedOut == true || event["late"] as? Bool == true)
            }
        case "metrics":
            guard time >= endTime - window else { return }
            let values = event["values"] as? [String: Any] ?? [:]
            let fields: [(RecentMetric, String, Double)] = [(.signal,"rssiDBm",1),(.noise,"noiseDBm",1),(.link,"linkMbps",1),(.download,"rxBytesPerSecond",8/1e6),(.upload,"txBytesPerSecond",8/1e6)]
            for (metric, field, scale) in fields {
                series[metric, default: []].append(RecentSample(time: time, value: number(values[field]).map { $0 * scale }, timedOut: false))
            }
            series[.awdl, default: []].append(RecentSample(time: time, value: (values["awdlUp"] as? Bool).map { $0 ? 1 : 0 }, timedOut: false))
        case "marker":
            if time >= endTime - window { markerTimes.append(time) }
        default: break
        }
    }
    public mutating func advance(to time: Double) {
        guard time.isFinite, time >= 0 else { return }
        endTime = max(endTime, time)
        guard endTime - lastTrim >= 1 else { return }
        let cutoff = endTime - window
        latency = latency.filter { $0.value.time >= cutoff }
        for metric in Array(series.keys) { series[metric]?.removeAll { $0.time < cutoff } }
        markerTimes.removeAll { $0 < cutoff }
        lastTrim = endTime
    }
    public func samples(for metric: RecentMetric) -> [RecentSample] {
        let points = metric == .latency ? Array(latency.values) : series[metric, default: []]
        return points.filter { $0.time >= endTime - window && $0.time <= endTime }.sorted { $0.time < $1.time }
    }
    public var markers: [Double] { markerTimes.filter { $0 >= endTime - window && $0 <= endTime }.sorted() }
    private func number(_ object: Any?) -> Double? {
        guard let value = object as? NSNumber else { return nil }
        let number = value.doubleValue
        return number.isFinite ? number : nil
    }
}
