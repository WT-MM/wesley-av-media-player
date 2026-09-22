import AppKit
import Carbon

@main struct ShortcutTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let first = GlobalRecordingShortcut(action: {})
        let second = GlobalRecordingShortcut(action: {})
        for choice in RecordingShortcutChoice.allCases {
        let initial = first.register(choice: choice)
        // An already-running recorder may own the chord; do not displace it.
        guard initial == noErr else { print("SKIP shortcut already registered (\(initial))"); exit(77) }
        guard second.register(choice: choice) != noErr else { fatalError("conflicting registration succeeded") }
        first.unregister(); first.unregister()
        guard second.register(choice: choice) == noErr else { fatalError("released shortcut could not be registered again") }
        second.unregister()
        print("PASS \(choice.label): registration, conflict detection, idempotent cleanup and re-registration")
        }
    }
}
