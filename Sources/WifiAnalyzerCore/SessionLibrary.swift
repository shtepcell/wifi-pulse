import Foundation

public struct RecordingSummary: Identifiable, Equatable, Sendable {
    public var id: URL { directory }
    public let directory: URL
    public let started: Date
    public let gateway: String
    public let duration: Double
    public let complete: Bool
}
public enum SessionLibrary {
    /// Only immediate child folders with raw session data; HTML is not required.
    /// Read a small event tail instead of parsing every session to populate the list.
    public static func scan(_ root: URL) throws -> [RecordingSummary] {
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
        let iso = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var entries: [RecordingSummary] = []
        for folder in children {
            guard let attributes = try? folder.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]), attributes.isDirectory == true,
                  let metadataData = try? Data(contentsOf: folder.appendingPathComponent("metadata.json")),
                  let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any], metadata["schemaVersion"] as? Int == 1,
                  let handle = try? FileHandle(forReadingFrom: folder.appendingPathComponent("events.jsonl")) else { continue }
            let tail: [String: Any]? = { () -> [String: Any]? in
                defer { try? handle.close() }
                guard let size = try? handle.seekToEnd(), (try? handle.seek(toOffset: size > 8192 ? size - 8192 : 0)) != nil,
                      let data = try? handle.readToEnd() else { return nil }
                for line in data.split(separator: 10).reversed() {
                    if let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { return event }
                }
                return nil
            }()
            let date = (metadata["startedUTC"] as? String).flatMap { iso.date(from: $0) ?? fractional.date(from: $0) } ?? attributes.contentModificationDate ?? .distantPast
            let time = (tail?["t"] as? NSNumber)?.doubleValue ?? 0
            entries.append(RecordingSummary(directory: folder.standardizedFileURL, started: date, gateway: metadata["gateway"] as? String ?? "Unknown router", duration: time.isFinite ? max(0, time) : 0, complete: tail?["kind"] as? String == "end"))
        }
        return entries.sorted { $0.started == $1.started ? $0.directory.path > $1.directory.path : $0.started > $1.started }
    }
}
