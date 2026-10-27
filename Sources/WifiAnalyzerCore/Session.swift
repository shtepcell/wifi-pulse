import Foundation
import Darwin

public struct AnalyzerError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct RouteInfo: Equatable, Codable {
    public let gateway: String
    public let interface: String
    public static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) && UInt8($0) != nil }
    }
    public static func isLocalIPv4(_ text: String) -> Bool {
        guard isIPv4(text) else { return false }
        let p = text.split(separator: ".").map { Int($0)! }
        return p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) ||
            (p[0] == 192 && p[1] == 168) || (p[0] == 169 && p[1] == 254) ||
            (p[0] == 100 && (64...127).contains(p[1]))
    }
    public static func parse(_ text: String) throws -> RouteInfo {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { fields[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        guard let gateway = fields["gateway"], isIPv4(gateway), let interface = fields["interface"], !interface.isEmpty else {
            throw AnalyzerError("Cannot determine IPv4 router/interface. Use --gateway and --interface for a local router; check Wi-Fi and VPN routing.")
        }
        return RouteInfo(gateway: gateway, interface: interface)
    }
    public static func current() throws -> RouteInfo {
        let result = try runCommand("/sbin/route", ["-n", "get", "default"])
        guard result.status == 0 else { throw AnalyzerError("Cannot read default route: \(result.text)") }
        return try parse(result.text)
    }
}

public struct Options: Sendable {
    public var command = "record"
    public var gateway: String?
    public var interface: String?
    public var interval = 0.05
    public var duration: Double?
    public var output: String?
    public var session: String?
    public static func parse(_ args: [String]) throws -> Options {
        var result = Options(), tokens = args
        if let first = tokens.first, !first.hasPrefix("-") { result.command = tokens.removeFirst() }
        if tokens == ["--help"] || result.command == "help" { result.command = "help"; return result }
        guard ["record", "report", "demo"].contains(result.command) else { throw AnalyzerError("Unknown command: \(result.command)") }
        if result.command == "report" {
            guard tokens.count == 1, !tokens[0].hasPrefix("-") else { throw AnalyzerError("Usage: wifi-analyzer report SESSION_FOLDER") }
            result.session = tokens[0]; return result
        }
        while !tokens.isEmpty {
            let flag = tokens.removeFirst()
            guard ["--gateway", "--interface", "--interval-ms", "--duration", "--output"].contains(flag), !tokens.isEmpty else { throw AnalyzerError("Unknown option or missing value: \(flag)") }
            let value = tokens.removeFirst()
            switch flag {
            case "--gateway":
                guard RouteInfo.isLocalIPv4(value) else { throw AnalyzerError("--gateway must be a local IPv4 address, not an internet target.") }
                result.gateway = value
            case "--interface":
                guard value.range(of: #"^[a-zA-Z][a-zA-Z0-9]{0,15}$"#, options: .regularExpression) != nil else { throw AnalyzerError("Invalid interface name") }
                result.interface = value
            case "--interval-ms":
                guard let ms = Double(value), ms.isFinite, (10...10000).contains(ms) else { throw AnalyzerError("--interval-ms must be between 10 and 10000") }
                result.interval = ms / 1000
            case "--duration":
                guard let seconds = Double(value), seconds.isFinite, seconds > 0 else { throw AnalyzerError("--duration must be positive seconds") }
                result.duration = seconds
            default:
                guard !value.isEmpty else { throw AnalyzerError("Empty output folder") }
                result.output = value
            }
        }
        if result.command == "demo", result.gateway != nil || result.interface != nil || result.duration != nil || result.interval != 0.05 {
            throw AnalyzerError("demo only accepts --output")
        }
        return result
    }
}

public struct ByteRate {
    private var previous: (UInt64, Double)?
    public init() {}
    public mutating func update(bytes: UInt64, at: Double) -> Double? {
        defer { previous = (bytes, at) }
        guard let (old, time) = previous, bytes >= old, at > time else { return nil }
        return Double(bytes - old) / (at - time)
    }
}

public enum SessionIO {
    public static func readEvents(_ data: Data) throws -> [[String: Any]] {
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        var events: [[String: Any]] = []
        for (index, line) in lines.enumerated() where !line.isEmpty {
            let object: Any
            do { object = try JSONSerialization.jsonObject(with: Data(line)) }
            catch {
                if index == lines.count - 1 && data.last != 10 { break }
                throw AnalyzerError("Malformed JSONL at line \(index + 1)")
            }
            guard let event = object as? [String: Any], event["schemaVersion"] as? Int == 1,
                  let kind = event["kind"] as? String, !kind.isEmpty,
                  let time = event["t"] as? Double, time.isFinite, time >= 0 else {
                throw AnalyzerError("Invalid or unsupported event at line \(index + 1)")
            }
            events.append(event)
        }
        return events
    }
    public static func safeJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
    public static func newDirectory(_ output: String?, prefix: String = "session") throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let path = output ?? "sessions/\(prefix)-\(stamp)-\(UUID().uuidString.prefix(6))"
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { throw AnalyzerError("Output already exists: \(url.path). Choose a new folder.") }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    public static func writeJSON(_ object: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}

final class SessionWriter {
    var onEvent: (([String: Any]) -> Void)?
    let directory: URL
    private let events: FileHandle
    private let raw: FileHandle
    private let start = ProcessInfo.processInfo.systemUptime
    private let formatter: ISO8601DateFormatter
    var elapsed: Double { ProcessInfo.processInfo.systemUptime - start }
    init(directory: URL, metadata: [String: Any]) throws {
        self.directory = directory
        formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        let rawURL = directory.appendingPathComponent("ping.log")
        guard FileManager.default.createFile(atPath: eventsURL.path, contents: nil), FileManager.default.createFile(atPath: rawURL.path, contents: nil) else { throw AnalyzerError("Cannot create session files") }
        events = try FileHandle(forWritingTo: eventsURL)
        raw = try FileHandle(forWritingTo: rawURL)
        try SessionIO.writeJSON(metadata, to: directory.appendingPathComponent("metadata.json"))
    }
    func append(_ kind: String, at time: Double? = nil, fields: [String: Any] = [:]) throws {
        var event = fields
        event["schemaVersion"] = 1; event["kind"] = kind
        event["t"] = time ?? elapsed; event["wallUTC"] = formatter.string(from: Date())
        var data = try JSONSerialization.data(withJSONObject: event, options: .sortedKeys)
        data.append(10); try events.write(contentsOf: data)
        onEvent?(event)
    }
    func rawLine(_ line: String) throws { try raw.write(contentsOf: Data((line + "\n").utf8)) }
    func sync() throws { try events.synchronize(); try raw.synchronize() }
    func close() throws { try sync(); try events.close(); try raw.close() }
    deinit { try? events.close(); try? raw.close() }
}

func runCommand(_ executable: String, _ arguments: [String]) throws -> (status: Int32, text: String) {
    let child = Process(), pipe = Pipe()
    child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
    child.standardOutput = pipe; child.standardError = pipe
    child.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new }
    try child.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    child.waitUntilExit()
    return (child.terminationStatus, String(decoding: data, as: UTF8.self))
}
