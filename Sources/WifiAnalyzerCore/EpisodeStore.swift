import Foundation

/// A serial writer. Admission includes the episode being captured, so disk stalls cannot build an unbounded queue.
public final class EpisodeStore {
    private let queue = DispatchQueue(label: "wifi-pulse.episodes", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private var maintaining = false
    private let maxCount: Int, maxBytes: Int, maxAge: TimeInterval, maxPending: Int
    private static let owner = ".live-owner.json"
    private static let allowed: Set<String> = [owner, "metadata.json", "events.jsonl", "report.html"]
    public init(maxCount: Int = 100, maxBytes: Int = 500 * 1024 * 1024, maxAge: TimeInterval = 7 * 86400, maxPending: Int = 2) {
        self.maxCount = maxCount; self.maxBytes = maxBytes; self.maxAge = maxAge; self.maxPending = maxPending
    }
    public func reserve() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pending < maxPending else { return false }
        pending += 1; return true
    }
    public func release() { lock.lock(); pending = max(0, pending - 1); lock.unlock() }
    /// Caller must hold one reservation, obtained before starting capture.
    public func submitReserved(_ episode: LiveEpisode, metadata: [String: Any], root: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            let result = Result { try self.save(episode, metadata: metadata, root: root) }
            self.release()
            DispatchQueue.main.async { completion(result) }
        }
    }
    public func maintain(root: URL, completion: @escaping (Error?) -> Void = { _ in }) {
        lock.lock()
        guard !maintaining else { lock.unlock(); return }
        maintaining = true; lock.unlock()
        queue.async {
            var failure: Error?
            do { try self.cleanup(root: root) } catch { failure = error }
            self.lock.lock(); self.maintaining = false; self.lock.unlock()
            DispatchQueue.main.async { completion(failure) }
        }
    }
    /// Barrier used on quit, after any active episode has been submitted.
    public func flush(completion: @escaping () -> Void) { queue.async { DispatchQueue.main.async(execute: completion) } }

    func save(_ episode: LiveEpisode, metadata: [String: Any], root: URL, now: Date = Date()) throws -> URL {
        var metadata = metadata
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let origin = (metadata["startedUTC"] as? String).flatMap { formatter.date(from: $0) ?? plain.date(from: $0) } ?? now
        metadata["startedUTC"] = formatter.string(from: origin.addingTimeInterval(episode.start))
        metadata["managedLiveEpisode"] = 1
        metadata["captureNote"] = episode.reason
        metadata["captureLimited"] = episode.limited
        metadata["captureTruncated"] = episode.truncated
        let events = try episode.events()
        var lines = Data()
        for event in events {
            lines.append(try JSONSerialization.data(withJSONObject: event, options: .sortedKeys)); lines.append(10)
        }
        let meta = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .prettyPrinted])
        let html = Data(try Report.render(metadata: metadata, events: events).utf8)
        let id = UUID().uuidString.lowercased()
        let ownership = try JSONSerialization.data(withJSONObject: ["version": 1, "id": id, "created": now.timeIntervalSince1970], options: .sortedKeys)
        let required = lines.count + meta.count + html.count + ownership.count
        guard required <= maxBytes, maxCount > 0 else { throw AnalyzerError("Episode exceeds the live storage limit") }
        try cleanup(root: root, now: now, reservingBytes: required, reservingCount: 1)
        let temporary = root.appendingPathComponent(".live-tmp-\(id)", isDirectory: true)
        let final = root.appendingPathComponent("live-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        do {
            // No atomic per-file copies: the complete staging folder is renamed on success.
            try ownership.write(to: temporary.appendingPathComponent(Self.owner))
            try meta.write(to: temporary.appendingPathComponent("metadata.json"))
            try lines.write(to: temporary.appendingPathComponent("events.jsonl"))
            try html.write(to: temporary.appendingPathComponent("report.html"))
            try FileManager.default.moveItem(at: temporary, to: final)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return final.appendingPathComponent("report.html")
    }
    private struct Entry {
        let folder: URL
        let created: Date
        let bytes: Int
        let temporary: Bool
    }
    /// Only our UUID folders with a valid owner marker and regular, known files may be removed.
    private func entries(root: URL) throws -> [Entry] {
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        var result: [Entry] = []
        for child in children {
            let name = child.lastPathComponent
            let temporary = name.hasPrefix(".live-tmp-")
            let prefix = temporary ? ".live-tmp-" : "live-"
            guard name.hasPrefix(prefix), let uuid = UUID(uuidString: String(name.dropFirst(prefix.count))) else { continue }
            let attributes = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard attributes.isSymbolicLink != true, attributes.isDirectory == true else { continue }
            let files = try fm.contentsOfDirectory(at: child, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            var bytes = 0, safe = true
            for file in files {
                let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                if !Self.allowed.contains(file.lastPathComponent) || values.isSymbolicLink == true || values.isRegularFile != true { safe = false; break }
                bytes += values.fileSize ?? 0
            }
            guard safe else { throw AnalyzerError("Live episode \(name) contains unexpected files or links. Move or repair that folder before saving more episodes.") }
            let ownerURL = child.appendingPathComponent(Self.owner)
            let ownerSize = try? ownerURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let ownerSize, ownerSize < 4096,
                  let data = try? Data(contentsOf: ownerURL),
                  let owner = try? JSONSerialization.jsonObject(with: data) as? [String: Any], owner["version"] as? Int == 1,
                  let id = owner["id"] as? String, UUID(uuidString: id) == uuid,
                  let created = owner["created"] as? Double, created.isFinite else {
                throw AnalyzerError("Live episode \(name) has an incomplete ownership marker. Move or repair that folder before saving more episodes.")
            }
            result.append(Entry(folder: child, created: Date(timeIntervalSince1970: created), bytes: bytes, temporary: temporary))
        }
        return result.sorted { $0.created == $1.created ? $0.folder.path < $1.folder.path : $0.created < $1.created }
    }
    public func cleanup(root: URL, now: Date = Date()) throws {
        try cleanup(root: root, now: now, reservingBytes: 0, reservingCount: 0)
    }
    private func cleanup(root: URL, now: Date, reservingBytes: Int, reservingCount: Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard rootValues.isSymbolicLink != true, rootValues.isDirectory == true else { throw AnalyzerError("Live recordings folder must be a real directory") }
        let entries = try entries(root: root)
        var bytes = entries.reduce(0) { $0 + $1.bytes } + reservingBytes
        var count = entries.count + reservingCount
        for entry in entries {
            if entry.temporary || now.timeIntervalSince(entry.created) > maxAge || count > maxCount || bytes > maxBytes {
                try fm.removeItem(at: entry.folder)
                count -= 1; bytes -= entry.bytes
            }
        }
        guard bytes <= maxBytes, count <= maxCount else { throw AnalyzerError("Cannot make room for the live episode") }
    }
}
