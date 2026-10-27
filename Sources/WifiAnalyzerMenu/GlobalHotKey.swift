import Carbon
import Foundation

/// Registers only one explicit chord; no keyboard monitoring or event tap.
final class GlobalHotKey {
    static let display = "⌃⌥⌘L"
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    init(action: @escaping () -> Void) throws {
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == 0x57494649, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue().action()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw HotKeyError(status: status) }
        let keyStatus = RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey | cmdKey), EventHotKeyID(signature: 0x57494649, id: 1), GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        guard keyStatus == noErr else {
            if let handler { RemoveEventHandler(handler); self.handler = nil }
            throw HotKeyError(status: keyStatus)
        }
    }
    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
private struct HotKeyError: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String { "Couldn’t register \(GlobalHotKey.display) (error \(status)). The shortcut may be in use. You can still use Mark Lag." }
}
