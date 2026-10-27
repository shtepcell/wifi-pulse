import Carbon
import Foundation

/// The hardware microphone key, distinct from standard F5 (key code 96).
/// Main-queue registration only; no keyboard monitor, event tap, or input logging.
final class MicrophoneHotKey {
    static let keyCode: UInt32 = 176
    private static let signature: OSType = 0x57414D49
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    var isEnabled: Bool { reference != nil }

    init(action: @escaping () -> Void) { self.action = action }
    func setEnabled(_ enabled: Bool) throws {
        guard enabled else { clear(); return }
        guard reference == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == MicrophoneHotKey.signature, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<MicrophoneHotKey>.fromOpaque(context).takeUnretainedValue()
            if shortcut.isEnabled { shortcut.action() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { throw MicrophoneKeyError(status: installed) }
        let registered = RegisterEventHotKey(Self.keyCode, 0, EventHotKeyID(signature: Self.signature, id: 1), GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard registered == noErr else { clear(); throw MicrophoneKeyError(status: registered) }
    }
    private func clear() {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
    deinit { clear() }
}
private struct MicrophoneKeyError: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String { "The microphone key is unavailable (error \(status)). Use the Mark Lag button." }
}
