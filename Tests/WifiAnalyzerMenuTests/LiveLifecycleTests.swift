import XCTest
@testable import WifiAnalyzerMenu
final class LiveLifecycleTests: XCTestCase {
    func testPauseAndQuitInvalidatePendingStartupAndWakeDoesNotOverridePause() {
        var state = LiveLifecycle()
        let original = state.generation
        XCTAssertTrue(state.shouldRun)
        state.pause()
        XCTAssertFalse(state.shouldRun)
        XCTAssertNotEqual(original, state.generation)
        state.sleep(); state.wake()
        XCTAssertFalse(state.shouldRun)
        state.resume()
        XCTAssertTrue(state.shouldRun)
        state.quit(); state.wake(); state.resume()
        XCTAssertFalse(state.shouldRun)
    }
    func testSleepInvalidatesOldNetworkInitializationAndWakeResumesLive() {
        var state = LiveLifecycle()
        let original = state.generation
        state.sleep()
        XCTAssertFalse(state.shouldRun)
        state.wake()
        XCTAssertTrue(state.shouldRun)
        XCTAssertNotEqual(state.generation, original)
    }
}
