import AppKit
import Carbon

@main struct ShortcutTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let first = GlobalRecordingShortcut(action: {})
        let second = GlobalRecordingShortcut(action: {})
        let initial = first.register()
        // An already-running recorder may own the chord; do not displace it.
        guard initial == noErr else { print("SKIP shortcut already registered (\(initial))"); exit(77) }
        guard second.register() != noErr else { fatalError("conflicting registration succeeded") }
        first.unregister(); first.unregister()
        guard second.register() == noErr else { fatalError("released shortcut could not be registered again") }
        second.unregister()
        print("PASS global shortcut registration, conflict detection, idempotent cleanup and re-registration")
    }
}
