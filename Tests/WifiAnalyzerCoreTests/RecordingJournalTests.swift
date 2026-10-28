import XCTest
@testable import WifiAnalyzerCore
final class RecordingJournalTests: XCTestCase {
    func testLiveJournalEmitsEventsWithoutCreatingOutputFiles() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var options = Options(); options.output = path.path
        let journal = try RecordingJournal(options: options, metadata: ["schemaVersion": 1], live: true)
        var events: [[String: Any]] = []
        journal.onEvent = { events.append($0) }
        try journal.append("send", at: 1, fields: ["id": 0])
        try journal.rawLine("64 bytes from router")
        try journal.sync(); try journal.close()
        XCTAssertNil(journal.directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(events.first?["t"] as? Double, 1)
        XCTAssertEqual(events.first?["kind"] as? String, "send")
        XCTAssertNotNil(events.first?["wallUTC"])
    }
    func testRecordingJournalStillPersistsCLIEvents() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        var options = Options(); options.output = path.path
        let journal = try RecordingJournal(options: options, metadata: ["schemaVersion": 1], live: false)
        try journal.append("marker", at: 2, fields: ["message": "Lag"])
        try journal.close()
        let events = try SessionIO.readEvents(Data(contentsOf: path.appendingPathComponent("events.jsonl")))
        XCTAssertEqual(events.first?["message"] as? String, "Lag")
    }
}
