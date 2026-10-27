import XCTest
@testable import WifiAnalyzerCore
final class PingTests: XCTestCase {
    func testParsesMacRepliesAndIgnoresDiagnostics() {
        XCTAssertEqual(PingParser.reply("64 bytes from 192.168.1.1: icmp_seq=42 ttl=64 time=125.374 ms"), PingReply(sequence: 42, latencyMS: 125.374))
        XCTAssertNotNil(PingParser.reply("64 bytes from 192.168.1.1: icmp_seq=0 ttl=64 time=0.521 ms (DUP!)"))
        XCTAssertNil(PingParser.reply("Request timeout for icmp_seq 5"))
        XCTAssertNil(PingParser.reply("round-trip min/avg/max/stddev = 1/2/3/4 ms"))
    }
    func testOutstandingProbeIsNotPrematurelyLostAndLateReplyIsRetained() {
        var tracker = PingTracker()
        tracker.sent(sequence: 0, at: 0)
        tracker.sent(sequence: 1, at: 0.05)
        XCTAssertTrue(tracker.expire(at: 0.1, timeout: 1).isEmpty)
        XCTAssertEqual(tracker.reply(sequence: 1, latencyMS: 2, at: 0.052)?.id, 1)
        XCTAssertEqual(tracker.expire(at: 1.01, timeout: 1).map(\.id), [0])
        let late = tracker.reply(sequence: 0, latencyMS: 1500, at: 1.5)
        XCTAssertEqual(late?.latencyMS, 1500)
        XCTAssertEqual(late?.timedOut, true)
        XCTAssertNil(tracker.reply(sequence: 0, latencyMS: 1500, at: 1.51))
        XCTAssertTrue(tracker.expire(at: 2, timeout: 1).isEmpty)
    }
    func testSequenceWrapKeepsUniqueProbeIDs() {
        var tracker = PingTracker()
        tracker.sent(sequence: 0, at: 0)
        _ = tracker.reply(sequence: 0, latencyMS: 2, at: 0.002)
        tracker.sent(sequence: 65535, at: 4000)
        tracker.sent(sequence: 0, at: 4000.05)
        XCTAssertEqual(tracker.reply(sequence: 0, latencyMS: 3, at: 4000.053)?.id, 2)
        XCTAssertEqual(tracker.probes.count, 3)
    }
    func testSlowReplyIsLateEvenWhenExpirationTimerHasNotRun() {
        var tracker = PingTracker()
        tracker.sent(sequence: 0, at: 0)
        let reply = tracker.reply(sequence: 0, latencyMS: 1250, at: 1.25)
        XCTAssertEqual(reply?.timedOut, true)
    }

}
