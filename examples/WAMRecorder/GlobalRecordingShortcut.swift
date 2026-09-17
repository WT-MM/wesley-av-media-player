import AppKit
import Carbon

// Register only this chord with macOS; no keyboard monitoring or polling.
@MainActor
final class GlobalRecordingShortcut {
    static let label = "⌃⌥⌘R"
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var held = false
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }

    func register() -> OSStatus {
        unregister()
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x57414D52, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<GlobalRecordingShortcut>.fromOpaque(context).takeUnretainedValue()
            let kind = GetEventKind(event)
            Task { @MainActor [weak shortcut] in shortcut?.receive(kind) }
            return noErr
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return installed }
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey | cmdKey),
            EventHotKeyID(signature: 0x57414D52, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { unregister() }
        return result
    }
    private func receive(_ kind: UInt32) {
        guard hotKey != nil else { return }
        if kind == UInt32(kEventHotKeyReleased) { held = false; return }
        guard kind == UInt32(kEventHotKeyPressed), !held else { return }
        held = true
        action()
    }
    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        held = false
    }
}
