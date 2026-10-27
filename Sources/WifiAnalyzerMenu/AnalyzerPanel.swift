import AppKit

/// A nonactivating utility panel, eligible to join another app's fullscreen Space.
@MainActor final class AnalyzerPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300), styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .transient, .ignoresCycle]
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    static var presentationScreen: NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    }
    var isVisibleOnPresentationScreen: Bool {
        isVisible && screen?.frame == Self.presentationScreen?.frame
    }
    func present(near button: NSStatusBarButton?) {
        // Position on the display where the user clicked, even if the panel was
        // previously shown on a different display. Do not activate NSApplication:
        // that would bring its old Space forward before ordering the panel.
        if let screen = Self.presentationScreen ?? button?.window?.screen {
            setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - frame.width - 12, y: screen.visibleFrame.maxY - 8))
        }
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }
}
