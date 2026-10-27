import XCTest
@testable import WifiAnalyzerCore
final class SessionWriterTests: XCTestCase {
    func testObserverReceivesExactlyPersistedEventsForUI() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = try SessionWriter(directory: folder, metadata: ["schemaVersion": 1])
        var observed: [[String: Any]] = []
        writer.onEvent = { observed.append($0) }
        try writer.append("marker", at: 2.5, fields: ["message": "Lag"])
        try writer.close()
        let saved = try SessionIO.readEvents(Data(contentsOf: folder.appendingPathComponent("events.jsonl")))
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?["message"] as? String, saved.first?["message"] as? String)
        XCTAssertEqual(observed.first?["t"] as? Double, 2.5)
    }
}
