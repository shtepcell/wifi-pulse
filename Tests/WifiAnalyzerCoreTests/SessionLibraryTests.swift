import XCTest
@testable import WifiAnalyzerCore

final class SessionLibraryTests: XCTestCase {
    func testListsRawRecordingsNewestFirstWithoutRequiringHTML() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func session(_ name: String, started: String, complete: Bool) throws {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try SessionIO.writeJSON(["schemaVersion": 1, "startedUTC": started, "gateway": "192.168.2.1", "interface": "en0"], to: folder.appendingPathComponent("metadata.json"))
            let text = complete ? "{\"schemaVersion\":1,\"kind\":\"end\",\"t\":42}\n" : "{\"schemaVersion\":1,\"kind\":\"send\",\"t\":0,\"id\":0}\n"
            try Data(text.utf8).write(to: folder.appendingPathComponent("events.jsonl"))
        }
        try session("older", started: "2026-10-27T10:00:00Z", complete: true)
        try session("newer", started: "2026-10-27T11:00:00Z", complete: false)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("unrelated"), withIntermediateDirectories: true)
        let entries = try SessionLibrary.scan(root)
        XCTAssertEqual(entries.map { $0.directory.lastPathComponent }, ["newer", "older"])
        XCTAssertFalse(entries[0].complete)
        XCTAssertTrue(entries[1].complete)
        XCTAssertEqual(entries[1].duration, 42)
        XCTAssertEqual(entries[1].gateway, "192.168.2.1")
        try session("latest", started: "2026-10-27T12:00:00Z", complete: true)
        XCTAssertEqual(try SessionLibrary.scan(root).first?.directory.lastPathComponent, "latest")
    }
    func testMissingFolderThrowsAndEmptyFolderHasNoRecordings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try SessionLibrary.scan(root))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(try SessionLibrary.scan(root).isEmpty)
    }
}
