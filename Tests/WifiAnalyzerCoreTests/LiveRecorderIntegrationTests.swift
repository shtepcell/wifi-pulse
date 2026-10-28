import XCTest
@testable import WifiAnalyzerCore

final class LiveRecorderIntegrationTests: XCTestCase {
    /// Opt in: uses the host Wi-Fi and sends ICMP to its local router.
    @MainActor func testLiveRecorderCapturesLagWithoutWritingUnmarkedSession() async throws {
        guard ProcessInfo.processInfo.environment["WIFI_PULSE_LIVE_TEST"] == "1" else { throw XCTSkip("Set WIFI_PULSE_LIVE_TEST=1 for local-router integration") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) }
        }
        var options = Options(); options.output = root.path; options.duration = 2
        let recorder = try Recorder(options: options, live: true)
        var capture = LiveCapture()
        var episode: LiveEpisode?
        var sends = 0
        let stopped = expectation(description: "live stopped")
        var failure: Error?
        recorder.onEvent = { event in
            if event["kind"] as? String == "send" { sends += 1 }
            do {
                if event["kind"] as? String == "stopping" {
                    episode = capture.finish(at: event["t"] as! Double, reason: "Integration stop")
                } else { _ = try capture.consume(event) }
            } catch { failure = error }
        }
        try recorder.start(interactive: false) { result in
            if case .failure(let error) = result { failure = error }
            stopped.fulfill()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(recorder.markLag("Integration lag"))
        await fulfillment(of: [stopped], timeout: 10)
        if let failure { throw failure }
        XCTAssertGreaterThan(sends, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let saved = expectation(description: "episode saved")
        let store = EpisodeStore()
        XCTAssertTrue(store.reserve())
        store.submitReserved(try XCTUnwrap(episode), metadata: recorder.metadata, root: root) { result in
            do {
                let analysis = try SessionAnalysis.load(directory: result.get().deletingLastPathComponent())
                XCTAssertEqual(analysis.markers.count, 1)
                XCTAssertGreaterThan(analysis.probes.count, 5)
                XCTAssertTrue(analysis.duration < 5)
            } catch { failure = error }
            saved.fulfill()
        }
        await fulfillment(of: [saved], timeout: 10)
        if let failure { throw failure }
    }
}
