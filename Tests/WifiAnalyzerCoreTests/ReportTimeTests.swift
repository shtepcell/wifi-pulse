import XCTest
@testable import WifiAnalyzerCore

final class ReportTimeTests: XCTestCase {
    func testClockLabelsUseStartOffsetAndLocalTimezone() {
        let clock = ReportTimeFormatter(startedUTC: "2026-10-28T20:43:08.250Z", timeZone: TimeZone(identifier: "Europe/Warsaw")!)
        XCTAssertTrue(clock.available)
        XCTAssertEqual(clock.string(60.5, clockTime: true, precise: true), "21:44:08.7")
        XCTAssertEqual(clock.string(60.5, clockTime: false), "01:00")
    }
    func testMidnightAndMissingStart() {
        let clock = ReportTimeFormatter(startedUTC: "2026-10-28T22:59:59Z", timeZone: TimeZone(identifier: "Europe/Warsaw")!)
        XCTAssertEqual(clock.string(2, clockTime: true), "00:00:01")
        for start in ["", "invalid"] {
            let fallback = ReportTimeFormatter(startedUTC: start)
            XCTAssertFalse(fallback.available)
            XCTAssertEqual(fallback.string(61.2, clockTime: true), "01:01")
        }
    }
}
