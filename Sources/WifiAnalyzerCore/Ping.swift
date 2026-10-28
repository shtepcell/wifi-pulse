import Foundation

public struct PingReply: Equatable {
    public let sequence: Int
    public let latencyMS: Double
}

public enum PingParser {
    private static let response = try! NSRegularExpression(pattern: #"icmp_seq=(\d+).*?time[=<]([\d.]+)\s*ms"#)
    private static let request = try! NSRegularExpression(pattern: #"bytes to .*?icmp_seq=(\d+)"#)
    private static func captures(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: line).map { String(line[$0]) } }
    }
    public static func reply(_ line: String) -> PingReply? {
        guard let parts = captures(response, line), parts.count == 2,
              let seq = Int(parts[0]), let rtt = Double(parts[1]), rtt.isFinite, rtt >= 0 else { return nil }
        return PingReply(sequence: seq, latencyMS: rtt)
    }
    public static func sentSequence(_ line: String) -> Int? {
        captures(request, line).flatMap { Int($0[0]) }
    }
}

public struct Probe: Equatable {
    public let id: Int
    public let sequence: Int
    public let sent: Double
    public var latencyMS: Double?
    public var timedOut: Bool
}

public struct PingTracker {
    private var stored: [Int: Probe] = [:]
    public var probes: [Probe] { stored.values.sorted { $0.id < $1.id } }
    public private(set) var totalSent = 0
    private var latest: [Int: Int] = [:]
    private var pending: Set<Int> = []
    private let retention: Double?
    private let maxProbes: Int
    private var oldestID = 0
    public init(retention: Double? = nil, maxProbes: Int = .max) {
        self.retention = retention; self.maxProbes = max(1, maxProbes)
    }
    @discardableResult public mutating func sent(sequence: Int, at: Double) -> Int {
        let id = totalSent
        totalSent += 1
        stored[id] = Probe(id: id, sequence: sequence, sent: at, latencyMS: nil, timedOut: false)
        latest[sequence] = id
        pending.insert(id)
        while let first = stored[oldestID], stored.count > maxProbes || retention.map({ at - first.sent > $0 }) == true {
            stored.removeValue(forKey: oldestID)
            pending.remove(oldestID)
            if latest[first.sequence] == oldestID { latest.removeValue(forKey: first.sequence) }
            oldestID += 1
        }
        return id
    }
    public mutating func reply(sequence: Int, latencyMS: Double, at: Double) -> Probe? {
        guard let id = latest[sequence], var probe = stored[id], probe.latencyMS == nil else { return nil }
        probe.latencyMS = latencyMS
        probe.timedOut = probe.timedOut || latencyMS >= 1000
        stored[id] = probe
        pending.remove(id)
        return probe
    }
    public mutating func expire(at: Double, timeout: Double) -> [Probe] {
        let expired = pending.filter { stored[$0].map { at - $0.sent >= timeout } ?? false }.sorted()
        for id in expired { stored[id]?.timedOut = true; pending.remove(id) }
        return expired.compactMap { stored[$0] }
    }
}
