import XCTest
import AppKit
@testable import WifiAnalyzerMenu

final class AnalyzerPanelTests: XCTestCase {
    func testUtilityPanelCanJoinCurrentAndForeignFullscreenSpacesWithoutActivation() async {
        await MainActor.run {
            _ = NSApplication.shared
            let panel = AnalyzerPanel()
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "Opening controls must not activate the app and switch its Space")
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications), "The game belongs to another application")
            XCTAssertFalse(panel.collectionBehavior.contains(.fullScreenPrimary))
            XCTAssertEqual(panel.level, .floating)
            XCTAssertFalse(panel.hidesOnDeactivate)
            panel.close()
        }
    }
    func testSettingsCanAcceptKeyboardInputWithoutBecomingMainApplicationWindow() async {
        await MainActor.run {
            _ = NSApplication.shared
            let panel = AnalyzerPanel()
            XCTAssertTrue(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            panel.close()
        }
    }
}
