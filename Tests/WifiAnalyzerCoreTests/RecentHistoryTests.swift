import XCTest
@testable import WifiAnalyzerCore
final class RecentHistoryTests: XCTestCase {
    func testDefaultFiveMinuteWindowKeepsNarrowLatencyPeakAndExpiresOldData() {
        var history = RecentHistory()
        for id in 0..<12000 {
            let time = Double(id) * 0.05
            history.consume(["kind": "reply", "id": id, "t": time + 0.001, "sent": time, "latencyMS": id == 9001 ? 350.0 : 3.0])
        }
        history.advance(to: 600)
        let points = history.samples(for: .latency)
        XCTAssertEqual(points.count, 6000)
        XCTAssertEqual(points.first?.time, 300)
        XCTAssertEqual(points.compactMap(\.value).max(), 350)
        history.advance(to: 910)
        XCTAssertTrue(history.samples(for: .latency).isEmpty)
    }
    func testTimeoutAndLateReplyUseOneProbeAtItsSendTime() {
        var history = RecentHistory(window: 60)
        history.consume(["kind": "timeout", "id": 9, "t": 2.0, "sent": 1.0])
        XCTAssertEqual(history.samples(for: .latency).count, 1)
        XCTAssertNil(history.samples(for: .latency).first?.value)
        XCTAssertEqual(history.samples(for: .latency).first?.timedOut, true)
        history.consume(["kind": "reply", "id": 9, "t": 2.5, "sent": 1.0, "latencyMS": 1500.0, "late": true])
        let points = history.samples(for: .latency)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.time, 1)
        XCTAssertEqual(points.first?.value, 1500)
        XCTAssertEqual(points.first?.timedOut, true)
    }
    func testUnavailableMetricsLeaveGapsRatherThanReusingPreviousValue() {
        var history = RecentHistory(window: 60)
        history.consume(["kind": "metrics", "t": 0.0, "values": ["rssiDBm": -60, "noiseDBm": -90, "rxBytesPerSecond": 125000.0, "awdlUp": false]])
        history.consume(["kind": "metrics", "t": 1.0, "values": ["rssiDBm": NSNull()]])
        let signal = history.samples(for: .signal)
        XCTAssertEqual(signal.count, 2)
        XCTAssertEqual(signal.first?.value, -60)
        XCTAssertNil(signal.last?.value)
        XCTAssertEqual(history.samples(for: .download).first?.value, 1)
        XCTAssertEqual(history.samples(for: .awdl).first?.value, 0)
        XCTAssertNil(history.samples(for: .awdl).last?.value)
    }
    func testOldLateReplyCannotReenterWindowAndClockNeverRewinds() {
        var history = RecentHistory(window: 60)
        history.advance(to: 100)
        history.consume(["kind": "reply", "id": 0, "t": 101.0, "sent": 1.0, "latencyMS": 100000.0])
        history.consume(["kind": "metrics", "t": 20.0, "values": ["rssiDBm": -50]])
        XCTAssertTrue(history.samples(for: .latency).isEmpty)
        XCTAssertTrue(history.samples(for: .signal).isEmpty)
        XCTAssertEqual(history.endTime, 101)
    }
    func testMarkersExpireAndNonfiniteValuesBecomeGaps() {
        var history = RecentHistory(window: 60)
        history.consume(["kind": "marker", "t": 1.0])
        history.consume(["kind": "marker", "t": 55.0])
        history.consume(["kind": "metrics", "t": 60.0, "values": ["linkMbps": Double.infinity]])
        history.advance(to: 70)
        XCTAssertEqual(history.markers, [55])
        XCTAssertEqual(history.samples(for: .link).count, 1)
        XCTAssertNil(history.samples(for: .link).first?.value)
    }
}
