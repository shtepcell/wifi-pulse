import XCTest
@testable import WifiAnalyzerCore

final class LiveCaptureTests: XCTestCase {
    private func event(_ kind: String, _ t: Double, _ fields: [String: Any] = [:]) -> [String: Any] {
        fields.merging(["schemaVersion": 1, "kind": kind, "t": t, "wallUTC": "2026-10-28T12:00:00Z"]) { _, rhs in rhs }
    }
    func testHistoryEvictsOldEventsAndEnforcesByteAndCountCaps() throws {
        var capture = LiveCapture(maxEvents: 100, maxBytes: 10_000)
        for second in 0..<10_000 { try capture.consume(event("metrics", Double(second))) }
        XCTAssertLessThanOrEqual(capture.historyCount, 100)
        XCTAssertLessThanOrEqual(capture.historyBytes, 10_000)
        XCTAssertTrue(try capture.historyEvents().allSatisfy { ($0["t"] as! Double) >= 9099 })
        var window = LiveCapture()
        for second in 0...1000 { try window.consume(event("metrics", Double(second))) }
        XCTAssertEqual(try window.historyEvents().first?["t"] as? Double, 100)
        XCTAssertNil(window.finish(at: 1000, reason: "Stop"))
    }
    func testMarkerFreezesPrehistoryAndMergesUntilThirtySecondsAfterLastMarker() throws {
        var capture = LiveCapture()
        try capture.consume(event("send", 10, ["id": 4]))
        try capture.consume(event("reply", 10.01, ["id": 4, "sent": 10, "latencyMS": 10]))
        try capture.consume(event("marker", 910, ["message": "first"]))
        try capture.consume(event("marker", 920, ["message": "second"]))
        XCTAssertNil(capture.advance(to: 949))
        let episode = try XCTUnwrap(capture.advance(to: 950))
        let events = try episode.events()
        XCTAssertEqual(episode.start, 10)
        XCTAssertEqual(episode.end, 950)
        XCTAssertEqual(events.filter { $0["kind"] as? String == "marker" }.count, 2)
        XCTAssertEqual(events.first { $0["kind"] as? String == "send" }?["t"] as? Double, 0)
        XCTAssertEqual(events.first { $0["kind"] as? String == "reply" }?["sent"] as? Double, 0)
        XCTAssertEqual(events.last?["t"] as? Double, 940)
        XCTAssertNil(capture.advance(to: 951))
    }
    func testCutoffIsHardAndStopTruncatesWithoutInventingTimeouts() throws {
        var capture = LiveCapture()
        try capture.consume(event("marker", 900))
        for second in stride(from: 920, through: 940, by: 20) { try capture.consume(event("marker", Double(second))) }
        XCTAssertNil(capture.advance(to: 959))
        XCTAssertEqual(capture.advance(to: 960)?.end, 960)
        try capture.consume(event("send", 961, ["id": 7]))
        try capture.consume(event("marker", 962))
        let episode = try XCTUnwrap(capture.finish(at: 963, reason: "Paused"))
        let events = try episode.events()
        XCTAssertEqual(events.last?["message"] as? String, "Paused; post-event capture truncated")
        XCTAssertFalse(events.contains { $0["kind"] as? String == "timeout" })
    }
    func testOrphanRepliesAreRemovedAndOversizedEventRejected() throws {
        var capture = LiveCapture(maxEvents: 100, maxBytes: 2048)
        try capture.consume(event("send", 0, ["id": 0]))
        try capture.consume(event("reply", 901, ["id": 0, "sent": 0, "latencyMS": 901000]))
        try capture.consume(event("marker", 902))
        let episode = try XCTUnwrap(capture.finish(at: 903, reason: "Stop"))
        XCTAssertFalse(try episode.events().contains { $0["kind"] as? String == "reply" })
        XCTAssertThrowsError(try capture.consume(event("diagnostic", 904, ["message": String(repeating: "x", count: 4096)])))
        XCTAssertLessThanOrEqual(capture.historyBytes, 2048)
    }
    func testActiveEpisodeAlsoHasHardEventAndByteLimits() throws {
        var capture = LiveCapture(maxEvents: 10, maxBytes: 4096)
        try capture.consume(event("marker", 0))
        for i in 1...20 { try capture.consume(event("metrics", Double(i))) }
        let episode = try XCTUnwrap(capture.finish(at: 21, reason: "Stop"))
        XCTAssertLessThanOrEqual(episode.eventCount, 10)
        XCTAssertLessThanOrEqual(episode.byteCount, 4096)
        XCTAssertTrue(try episode.events().contains { $0["kind"] as? String == "marker" })
        XCTAssertTrue(episode.limited)
    }
    func testSparseHistoryIsNotMistakenForMemoryTruncation() throws {
        var capture = LiveCapture()
        try capture.consume(event("metrics", 500))
        try capture.consume(event("marker", 900))
        XCTAssertFalse(try XCTUnwrap(capture.advance(to: 930)).limited)
    }
    func testMemoryEvictionIsReportedWhenCaptureStartsAfterRingCompaction() throws {
        var capture = LiveCapture(maxEvents: 10, maxBytes: 4096)
        for i in 0...1200 { try capture.consume(event("metrics", Double(i))) }
        try capture.consume(event("marker", 1201))
        XCTAssertTrue(try XCTUnwrap(capture.advance(to: 1231)).limited)
    }

}
