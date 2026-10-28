import Foundation

public struct LiveSnapshot {
    public private(set) var latestLatencyMS: Double?
    public private(set) var lastReplyAt: Double?
    public private(set) var lastMetricsAt: Double?
    public private(set) var rssiDBm: Int?
    public private(set) var noiseDBm: Int?
    public private(set) var linkMbps: Double?
    public private(set) var channel: Int?
    public private(set) var awdlUp: Bool?
    public private(set) var rxBytesPerSecond: Double?
    public private(set) var txBytesPerSecond: Double?
    public private(set) var sent = 0
    public private(set) var markers = 0
    public private(set) var missing = 0
    public private(set) var issues: [String] = []
    private var unanswered: [Int: Double] = [:]
    private var lastTrim = -Double.infinity
    public init() {}
    public mutating func consume(_ event: [String: Any]) {
        if let time = event["t"] as? Double, time - lastTrim >= 1 {
            unanswered = unanswered.filter { $0.value >= time - 900 }
            lastTrim = time
        }
        switch event["kind"] as? String {
        case "send": sent += 1
        case "timeout":
            if let id = event["id"] as? Int { unanswered[id] = event["sent"] as? Double ?? event["t"] as? Double ?? 0 }
        case "reply":
            if let id = event["id"] as? Int { unanswered.removeValue(forKey: id) }
            latestLatencyMS = event["latencyMS"] as? Double
            lastReplyAt = event["t"] as? Double
        case "marker": markers += 1
        case "metrics":
            let values = event["values"] as? [String: Any] ?? [:]
            lastMetricsAt = event["t"] as? Double
            rssiDBm = values["rssiDBm"] as? Int
            noiseDBm = values["noiseDBm"] as? Int
            linkMbps = values["linkMbps"] as? Double
            channel = values["channel"] as? Int
            awdlUp = values["awdlUp"] as? Bool
            rxBytesPerSecond = values["rxBytesPerSecond"] as? Double
            txBytesPerSecond = values["txBytesPerSecond"] as? Double
            issues = values["issues"] as? [String] ?? []
        default: break
        }
        missing = unanswered.count
    }
}
