import XCTest
@testable import WifiAnalyzerCore
final class ReportTests: XCTestCase {
    func testReportRegeneratesFromArtifactsAndEscapesUserContent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try SessionIO.writeJSON(["schemaVersion": 1, "gateway": "192.168.2.1", "note": "</script><img src=x onerror=alert(1)>"], to: folder.appendingPathComponent("metadata.json"))
        try Data("{\"schemaVersion\":1,\"kind\":\"marker\",\"t\":2}\n{\"unfinished\"".utf8).write(to: folder.appendingPathComponent("events.jsonl"))
        let report = try Report.generate(directory: folder)
        XCTAssertEqual(report.lastPathComponent, "report.html")
        let html = try String(contentsOf: report)
        XCTAssertTrue(html.contains("192.168.2.1"))
        XCTAssertFalse(html.contains("</script><img"))
        XCTAssertFalse(html.contains("__SESSION_DATA__"))
    }
    func testDemoIsLabeledAndContainsLatencySpikeAndMissingReplies() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try Report.demo(output: folder.path)
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("metadata.json"))) as! [String: Any]
        XCTAssertEqual(metadata["synthetic"] as? Bool, true)
        XCTAssertEqual(metadata["appVersion"] as? String, "0.2.0")
        let events = try SessionIO.readEvents(Data(contentsOf: folder.appendingPathComponent("events.jsonl")))
        XCTAssertTrue(events.contains { $0["kind"] as? String == "timeout" })
        XCTAssertTrue(events.contains { ($0["latencyMS"] as? Double ?? 0) > 100 })
        XCTAssertTrue(events.contains { $0["kind"] as? String == "marker" })
    }
}
