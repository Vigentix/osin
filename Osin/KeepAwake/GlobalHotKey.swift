import Carbon.HIToolbox
import Foundation

/// The global shortcuts offered for Keep Awake. Off by default; registered with Carbon's
/// `RegisterEventHotKey`, which needs no Accessibility permission.
enum KeepAwakeShortcut: String, CaseIterable, Identifiable {
    case none
    case controlOptionCommandA
    case controlOptionCommandK
    case optionCommandK

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .none: String(localized: "None")
        case .controlOptionCommandA: "⌃⌥⌘A"
        case .controlOptionCommandK: "⌃⌥⌘K"
        case .optionCommandK: "⌥⌘K"
        }
    }

    fileprivate var keyAndModifiers: (key: UInt32, modifiers: UInt32)? {
        switch self {
        case .none: nil
        case .controlOptionCommandA: (UInt32(kVK_ANSI_A), UInt32(controlKey | optionKey | cmdKey))
        case .controlOptionCommandK: (UInt32(kVK_ANSI_K), UInt32(controlKey | optionKey | cmdKey))
        case .optionCommandK: (UInt32(kVK_ANSI_K), UInt32(optionKey | cmdKey))
        }
    }
}

/// One global hot key at a time. Carbon delivers hot key events on the main thread.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    /// Registers `shortcut` (replacing any previous one). Returns false if macOS refused it, for
    /// example because another app already uses the combination.
    @discardableResult
    func register(_ shortcut: KeepAwakeShortcut, action: @escaping () -> Void) -> Bool {
        unregister()
        guard let combo = shortcut.keyAndModifiers else { return true }
        self.action = action
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                MainActor.assumeIsolated { GlobalHotKey.shared.action?() }
                return noErr
            }, 1, &type, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4F53_494E), id: 1) // "OSIN"
        return RegisterEventHotKey(combo.key, combo.modifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr
    }

    func unregister() {
        if let reference {
            UnregisterEventHotKey(reference)
            self.reference = nil
        }
        action = nil
    }
}
