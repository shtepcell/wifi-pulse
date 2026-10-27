import XCTest
import AppKit
import Carbon
@testable import WifiAnalyzerMenu

final class MicrophoneHotKeyTests: XCTestCase {
    func testMicrophoneKeyIsReservedOnlyDuringRecordingAndReleasedAfterStop() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let shortcut = MicrophoneHotKey(action: {})
            XCTAssertFalse(shortcut.isEnabled)
            try shortcut.setEnabled(true)
            XCTAssertTrue(shortcut.isEnabled)
            var competing: EventHotKeyRef?
            let occupied = RegisterEventHotKey(176, 0, EventHotKeyID(signature: 0x54455354, id: 99), GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &competing)
            if let competing { UnregisterEventHotKey(competing) }
            XCTAssertEqual(occupied, OSStatus(eventHotKeyExistsErr), "A second shortcut must not also take the microphone key")
            try shortcut.setEnabled(false)
            XCTAssertFalse(shortcut.isEnabled)
            var released: EventHotKeyRef?
            let available = RegisterEventHotKey(176, 0, EventHotKeyID(signature: 0x54455354, id: 100), GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &released)
            if let released { UnregisterEventHotKey(released) }
            XCTAssertEqual(available, noErr, "Stopping recording must restore the microphone key")
        }
    }
}
