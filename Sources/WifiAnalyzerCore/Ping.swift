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
    public private(set) var probes: [Probe] = []
    private var latest: [Int: Int] = [:]
    private var pending: Set<Int> = []
    public init() {}
    public mutating func sent(sequence: Int, at: Double) {
        let id = probes.count
        probes.append(Probe(id: id, sequence: sequence, sent: at, latencyMS: nil, timedOut: false))
        latest[sequence] = id
        pending.insert(id)
    }
    public mutating func reply(sequence: Int, latencyMS: Double, at: Double) -> Probe? {
        guard let id = latest[sequence], probes[id].latencyMS == nil else { return nil }
        probes[id].latencyMS = latencyMS
        probes[id].timedOut = probes[id].timedOut || latencyMS >= 1000
        pending.remove(id)
        return probes[id]
    }
    public mutating func expire(at: Double, timeout: Double) -> [Probe] {
        let expired = pending.filter { at - probes[$0].sent >= timeout }.sorted()
        for id in expired { probes[id].timedOut = true; pending.remove(id) }
        return expired.map { probes[$0] }
    }
}
