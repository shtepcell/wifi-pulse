import Foundation

/// Encoded payloads keep both retained bytes and event count measurable and bounded.
private struct BufferedEvent {
    let time: Double
    let data: Data
}

public struct LiveEpisode {
    public let start: Double
    public let end: Double
    public let limited: Bool
    public let reason: String
    public let truncated: Bool
    static func warnings(metadata: [String: Any]) -> [String] {
        guard metadata["managedLiveEpisode"] as? Int == 1 else { return [] }
        var result: [String] = []
        if metadata["captureLimited"] as? Bool == true { result.append("Capture reached its memory limit; some measurements were omitted.") }
        if metadata["captureTruncated"] as? Bool == true { result.append(metadata["captureNote"] as? String ?? "Post-event capture was truncated.") }
        return result
    }
    fileprivate let records: [Data]
    public var eventCount: Int { records.count }
    public var byteCount: Int { records.reduce(0) { $0 + $1.count } }

    /// Rebase the window, preserving wall timestamps. Replies outside retained sends are censored.
    public func events() throws -> [[String: Any]] {
        let decoded = try records.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
            .enumerated().sorted {
                let a = $0.element["t"] as! Double, b = $1.element["t"] as! Double
                return a == b ? $0.offset < $1.offset : a < b
            }.map(\.element)
        var ids: [Int: Int] = [:]
        for event in decoded where event["kind"] as? String == "send" {
            if let id = event["id"] as? Int { ids[id] = ids.count }
        }
        var result: [[String: Any]] = [["schemaVersion": 1, "kind": "start", "t": 0.0, "message": "Live lag episode"]]
        for var event in decoded {
            let time = event["t"] as! Double
            guard time >= start, time <= end else { continue }
            let kind = event["kind"] as? String ?? ""
            guard !["start", "stopping", "end"].contains(kind) else { continue }
            if ["send", "reply", "timeout"].contains(kind) {
                guard let old = event["id"] as? Int, let id = ids[old] else { continue }
                event["id"] = id
            }
            event["t"] = time - start
            if let sent = event["sent"] as? Double { event["sent"] = sent - start }
            result.append(event)
        }
        if limited { result.append(["schemaVersion": 1, "kind": "diagnostic", "t": end - start, "message": "Capture reached its memory limit; some measurements were omitted"]) }
        result.append(["schemaVersion": 1, "kind": "end", "t": max(0, end - start), "message": reason])
        return result
    }
}

public struct LiveCapture {
    private let maxEvents: Int
    private let maxBytes: Int
    private var history: [BufferedEvent?] = []
    private var head = 0
    public private(set) var historyBytes = 0
    public var historyCount: Int { history.count - head }
    private var clock = 0.0
    private var active: [Data]?
    private var activeBytes = 0
    private var start = 0.0, deadline = 0.0
    private var limited = false
    private var capacityEvictedThrough = -Double.infinity
    public var isCapturing: Bool { active != nil }
    public var captureDeadline: Double? { active == nil ? nil : deadline }
    public init(maxEvents: Int = 40_000, maxBytes: Int = 12 * 1024 * 1024) {
        precondition(maxEvents > 0 && maxBytes > 0)
        self.maxEvents = maxEvents; self.maxBytes = maxBytes
    }
    @discardableResult public mutating func consume(_ event: [String: Any]) throws -> LiveEpisode? {
        guard let time = event["t"] as? Double, time.isFinite, time >= 0 else { throw AnalyzerError("Invalid live timestamp") }
        let data = try JSONSerialization.data(withJSONObject: event, options: .sortedKeys)
        guard data.count <= maxBytes else { throw AnalyzerError("Live event exceeds the memory limit") }
        let completed = advance(to: time)
        history.append(BufferedEvent(time: time, data: data)); historyBytes += data.count
        trim()
        if event["kind"] as? String == "marker" {
            if active == nil {
                start = max(0, time - 900)
                active = history.compactMap { entry in entry.flatMap { $0.time >= start ? $0.data : nil } }
                activeBytes = active!.reduce(0) { $0 + $1.count }
                limited = capacityEvictedThrough >= start
            } else {
                guard appendActive(data) else { throw AnalyzerError("Episode is full; wait for it to save before adding a marker") }
            }
            deadline = min(start + 960, time + 30)
        } else if active != nil { _ = appendActive(data) }
        return completed
    }
    private mutating func appendActive(_ data: Data) -> Bool {
        guard active!.count < maxEvents, activeBytes + data.count <= maxBytes else { limited = true; return false }
        active!.append(data); activeBytes += data.count
        return true
    }
    public mutating func advance(to time: Double) -> LiveEpisode? {
        clock = max(clock, time)
        trim()
        guard active != nil, clock >= deadline else { return nil }
        return take(end: deadline, reason: "Post-event capture complete", truncated: false)
    }
    public mutating func finish(at time: Double, reason: String) -> LiveEpisode? {
        guard active != nil else { return nil }
        return take(end: min(time, deadline), reason: time < deadline ? "\(reason); post-event capture truncated" : "Post-event capture complete", truncated: time < deadline)
    }
    private mutating func take(end: Double, reason: String, truncated: Bool) -> LiveEpisode {
        let result = LiveEpisode(start: start, end: end, limited: limited, reason: reason, truncated: truncated, records: active!)
        active = nil; activeBytes = 0
        return result
    }
    private mutating func trim() {
        while head < history.count, let first = history[head], first.time < clock - 900 || historyCount > maxEvents || historyBytes > maxBytes {
            if historyCount > maxEvents || historyBytes > maxBytes {
                capacityEvictedThrough = max(capacityEvictedThrough, first.time)
            }
            historyBytes -= first.data.count; history[head] = nil; head += 1
        }
        if head >= 1024 && head * 2 >= history.count { history.removeFirst(head); head = 0 }
    }
    public func historyEvents() throws -> [[String: Any]] {
        try history.compactMap { $0 }.filter { $0.time >= clock - 900 }.map { try JSONSerialization.jsonObject(with: $0.data) as! [String: Any] }
    }
}
