import XCTest
@testable import WifiAnalyzerCore

final class SessionAnalysisTests: XCTestCase {
    func testNativeAnalysisKeepsLateRepliesPendingProbesAndMetricGaps() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try SessionWriter(directory: directory, metadata: ["schemaVersion": 1, "gateway": "192.168.2.1", "interface": "en0", "synthetic": true])
        try writer.append("send", at: 0, fields: ["id": 0])
        try writer.append("timeout", at: 1, fields: ["id": 0, "sent": 0])
        try writer.append("reply", at: 1.5, fields: ["id": 0, "sent": 0, "latencyMS": 1500, "late": true])
        try writer.append("send", at: 2, fields: ["id": 1])
        try writer.append("timeout", at: 3, fields: ["id": 1, "sent": 2])
        try writer.append("metrics", at: 3, fields: ["values": ["rssiDBm": -60, "rxBytesPerSecond": 125000, "awdlUp": false]])
        try writer.append("metrics", at: 4, fields: ["values": [:]])
        try writer.append("marker", at: 4, fields: ["message": "Lag"])
        try writer.append("send", at: 4.9, fields: ["id": 2])
        try writer.append("end", at: 5)
        try writer.close()
        let report = try SessionAnalysis.load(directory: directory)
        let stats = report.statistics(in: 0...5)
        XCTAssertEqual(stats.sent, 3)
        XCTAssertEqual(stats.missing, 1)
        XCTAssertEqual(stats.pending, 1)
        XCTAssertEqual(stats.late, 1)
        XCTAssertEqual(stats.median, 1500)
        XCTAssertEqual(report.statistics(in: 2...5).sent, 2)
        XCTAssertNil(report.statistics(in: 2...5).median)
        XCTAssertEqual(report.series[.download]?.first?.value, 1)
        XCTAssertNil(report.series[.signal]?.last?.value)
        XCTAssertEqual(report.markers.first?.time, 4)
        XCTAssertTrue(report.synthetic)
        XCTAssertTrue(report.warnings.isEmpty)
    }
    func testPlotEnvelopePreservesShortPeakAndSeparatesMissingSegments() {
        let points = [RecentSample(time: 0, value: 2, timedOut: false), RecentSample(time: 0.001, value: 900, timedOut: false), RecentSample(time: 0.002, value: 3, timedOut: false), RecentSample(time: 1, value: nil, timedOut: false), RecentSample(time: 2, value: 4, timedOut: false)]
        let columns = SessionAnalysis.envelope(points, in: 0...10, columns: 10)
        XCTAssertEqual(columns.first?.maximum, 900)
        XCTAssertEqual(columns.first?.minimum, 2)
        XCTAssertNotEqual(columns.first?.segment, columns.last?.segment)
        let sparse = [RecentSample(time: 0, value: 2, timedOut: false), RecentSample(time: 10, value: 4, timedOut: false)]
        let separated = SessionAnalysis.envelope(sparse, in: 0...100, columns: 1)
        XCTAssertEqual(separated.count, 2, "A long sampling gap must remain a break even within one pixel")
        XCTAssertNotEqual(separated.first?.segment, separated.last?.segment)
    }
}
