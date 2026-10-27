import XCTest
@testable import WifiAnalyzerCore
final class LiveSnapshotTests: XCTestCase {
    func testLateReplyRemovesLossAndUpdatesFreshness() {
        var snapshot = LiveSnapshot()
        snapshot.consume(["kind": "send", "id": 0, "t": 0.0])
        snapshot.consume(["kind": "timeout", "id": 0, "t": 1.0])
        XCTAssertEqual(snapshot.sent, 1)
        XCTAssertEqual(snapshot.missing, 1)
        snapshot.consume(["kind": "reply", "id": 0, "t": 1.2, "latencyMS": 1200.0])
        XCTAssertEqual(snapshot.missing, 0)
        XCTAssertEqual(snapshot.latestLatencyMS, 1200)
        XCTAssertEqual(snapshot.lastReplyAt, 1.2)
        snapshot.consume(["kind": "marker", "t": 1.3])
        XCTAssertEqual(snapshot.markers, 1)
    }
    func testMissingMetricsClearPriorValuesInsteadOfShowingStaleSignal() {
        var snapshot = LiveSnapshot()
        snapshot.consume(["kind": "metrics", "t": 0.0, "values": ["rssiDBm": -65, "awdlUp": false, "channel": 44, "linkMbps": 500.0]])
        XCTAssertEqual(snapshot.rssiDBm, -65)
        XCTAssertEqual(snapshot.awdlUp, false)
        snapshot.consume(["kind": "metrics", "t": 1.0, "values": ["rssiDBm": NSNull(), "issues": ["Unavailable"]]])
        XCTAssertNil(snapshot.rssiDBm)
        XCTAssertNil(snapshot.awdlUp)
        XCTAssertNil(snapshot.linkMbps)
        XCTAssertEqual(snapshot.lastMetricsAt, 1)
        XCTAssertEqual(snapshot.issues, ["Unavailable"])
    }
}
