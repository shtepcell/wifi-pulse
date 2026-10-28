import XCTest
@testable import WifiAnalyzerCore

final class EpisodeStoreTests: XCTestCase {
    private func episode() throws -> LiveEpisode {
        var capture = LiveCapture()
        try capture.consume(["schemaVersion": 1, "kind": "send", "id": 42, "t": 900.0])
        try capture.consume(["schemaVersion": 1, "kind": "reply", "id": 42, "sent": 900.0, "latencyMS": 2.0, "t": 900.002])
        try capture.consume(["schemaVersion": 1, "kind": "marker", "message": "Lag", "t": 901.0])
        return try XCTUnwrap(capture.advance(to: 931))
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private let metadata: [String: Any] = ["schemaVersion": 1, "startedUTC": "2026-10-28T12:00:00Z", "gateway": "192.168.1.1", "interface": "en0"]

    func testSavedEpisodeLoadsInNativeAndHTMLReportsWithWindowClock() throws {
        let folder = try root()
        let store = EpisodeStore()
        let report = try store.save(episode(), metadata: metadata, root: folder)
        let analysis = try SessionAnalysis.load(directory: report.deletingLastPathComponent())
        XCTAssertEqual(analysis.probes.count, 1)
        XCTAssertEqual(analysis.probes.first?.time, 899)
        XCTAssertEqual(analysis.markers.first?.time, 900)
        XCTAssertEqual(analysis.startedUTC, "2026-10-28T12:00:01.000Z")
        XCTAssertTrue(analysis.warnings.isEmpty)
        XCTAssertTrue(try String(contentsOf: report).contains("192.168.1.1"))
    }
    func testCountAgeAndByteRetentionOnlyRemoveManagedEpisodes() throws {
        let folder = try root()
        let ordinary = folder.appendingPathComponent("session-old")
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: ordinary.appendingPathComponent("events.jsonl"))
        let store = EpisodeStore(maxCount: 2, maxBytes: 20_000_000, maxAge: 10)
        let first = try store.save(episode(), metadata: metadata, root: folder, now: Date(timeIntervalSince1970: 100))
        _ = try store.save(episode(), metadata: metadata, root: folder, now: Date(timeIntervalSince1970: 101))
        _ = try store.save(episode(), metadata: metadata, root: folder, now: Date(timeIntervalSince1970: 102))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try SessionLibrary.scan(folder).count, 2)
        try store.cleanup(root: folder, now: Date(timeIntervalSince1970: 113))
        XCTAssertTrue(try SessionLibrary.scan(folder).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ordinary.appendingPathComponent("events.jsonl").path))
        let tiny = EpisodeStore(maxBytes: 10)
        XCTAssertThrowsError(try tiny.save(episode(), metadata: metadata, root: folder))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["session-old"])
    }
    func testByteBudgetIncludesHTMLAndCanEvictWithinCountLimit() throws {
        let folder = try root()
        let store = EpisodeStore()
        let first = try store.save(episode(), metadata: metadata, root: folder)
        let files = try FileManager.default.contentsOfDirectory(at: first.deletingLastPathComponent(), includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        let limited = EpisodeStore(maxBytes: bytes + 100)
        _ = try limited.save(episode(), metadata: metadata, root: folder)
        XCTAssertEqual(try SessionLibrary.scan(folder).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }
    func testSymlinkAndForeignContentsAreNeverDeleted() throws {
        let folder = try root(), outside = try root()
        let store = EpisodeStore(maxAge: 1)
        let report = try store.save(episode(), metadata: metadata, root: folder, now: Date(timeIntervalSince1970: 10))
        let managed = report.deletingLastPathComponent()
        try FileManager.default.removeItem(at: report)
        let secret = outside.appendingPathComponent("keep.html")
        try Data("keep".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: report, withDestinationURL: secret)
        XCTAssertThrowsError(try store.cleanup(root: folder, now: Date(timeIntervalSince1970: 100)))
        XCTAssertThrowsError(try store.save(episode(), metadata: metadata, root: folder))
        XCTAssertEqual(try String(contentsOf: secret), "keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: managed.path))
        let alias = folder.appendingPathComponent("live-00000000-0000-0000-0000-000000000000")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        XCTAssertThrowsError(try store.cleanup(root: folder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alias.path))
    }
    func testQueueAdmissionHasHardLimitAndReleasesAfterCompletion() throws {
        let store = EpisodeStore(maxPending: 1)
        XCTAssertTrue(store.reserve())
        XCTAssertFalse(store.reserve())
        store.release()
        XCTAssertTrue(store.reserve())
        store.release()
    }
    func testInterruptedStagingFolderIsRemovedWithoutTouchingOrdinaryFolders() throws {
        let folder = try root()
        let store = EpisodeStore()
        let report = try store.save(episode(), metadata: metadata, root: folder)
        let final = report.deletingLastPathComponent()
        let staging = folder.appendingPathComponent(".live-tmp-" + String(final.lastPathComponent.dropFirst(5)))
        try FileManager.default.moveItem(at: final, to: staging)
        try store.cleanup(root: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }
    func testAsyncSaveReturnsReservationAndRemovesFailedStagingOutput() throws {
        let folder = try root()
        let store = EpisodeStore(maxBytes: 10, maxPending: 1)
        let completed = expectation(description: "save completed")
        XCTAssertTrue(store.reserve())
        store.submitReserved(try episode(), metadata: metadata, root: folder) { result in
            if case .success = result { XCTFail("Oversized save must fail") }
            XCTAssertTrue(store.reserve())
            store.release()
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    func testInvalidStagingOwnerBlocksFurtherGrowthWithoutDeletingUnknownData() throws {
        let folder = try root()
        let staging = folder.appendingPathComponent(".live-tmp-00000000-0000-0000-0000-000000000000")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("incomplete".utf8).write(to: staging.appendingPathComponent(".live-owner.json"))
        let store = EpisodeStore()
        XCTAssertThrowsError(try store.save(episode(), metadata: metadata, root: folder))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
    }

    func testTruncatedFollowUpIsVisibleInBothReportFormats() throws {
        let folder = try root()
        var capture = LiveCapture()
        try capture.consume(["schemaVersion": 1, "kind": "marker", "t": 10.0])
        let clip = try XCTUnwrap(capture.finish(at: 11, reason: "Mac went to sleep"))
        let report = try EpisodeStore().save(clip, metadata: metadata, root: folder)
        let analysis = try SessionAnalysis.load(directory: report.deletingLastPathComponent())
        XCTAssertTrue(analysis.warnings.contains { $0.contains("post-event capture truncated") })
        let html = try String(contentsOf: report)
        XCTAssertTrue(html.contains("\"warnings\":[\"Mac went to sleep; post-event capture truncated\"]"))
    }

}
