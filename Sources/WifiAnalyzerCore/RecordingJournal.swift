import Foundation

/// Live collection never opens a SessionWriter. The CLI keeps its original on-disk journal.
final class RecordingJournal {
    private let writer: SessionWriter?
    private let started = ProcessInfo.processInfo.systemUptime
    private let formatter: ISO8601DateFormatter
    let metadata: [String: Any]
    var onEvent: (([String: Any]) -> Void)? {
        didSet { writer?.onEvent = onEvent }
    }
    var directory: URL? { writer?.directory }
    var elapsed: Double { writer?.elapsed ?? ProcessInfo.processInfo.systemUptime - started }
    init(options: Options, metadata: [String: Any], live: Bool) throws {
        self.metadata = metadata
        formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        writer = live ? nil : try SessionWriter(directory: SessionIO.newDirectory(options.output), metadata: metadata)
    }
    func append(_ kind: String, at time: Double? = nil, fields: [String: Any] = [:]) throws {
        if let writer { try writer.append(kind, at: time, fields: fields); return }
        var event = fields
        event["schemaVersion"] = 1; event["kind"] = kind
        event["t"] = time ?? elapsed; event["wallUTC"] = formatter.string(from: Date())
        onEvent?(event)
    }
    func rawLine(_ line: String) throws { try writer?.rawLine(line) }
    func sync() throws { try writer?.sync() }
    func close() throws { try writer?.close() }
}
