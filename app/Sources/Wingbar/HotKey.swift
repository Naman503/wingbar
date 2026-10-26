import AppKit
import Carbon.HIToolbox
import WingbarCore

/// One global shortcut via Carbon's RegisterEventHotKey, which needs no
/// permission (unlike watching all key presses).
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var action: (() -> Void)?

    func set(_ choice: HotkeyChoice, action: @escaping () -> Void) {
        unregister()
        guard let (key, modifiers) = Self.combo(choice) else { return }
        Self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.action?() } }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x5747_4252), id: 1) // "WGBR"
        RegisterEventHotKey(UInt32(key), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
    }

    private static func combo(_ choice: HotkeyChoice) -> (Int, Int)? {
        switch choice {
        case .none: nil
        case .optionCommandB: (kVK_ANSI_B, optionKey | cmdKey)
        case .controlOptionSpace: (kVK_Space, controlKey | optionKey)
        case .controlOptionCommandM: (kVK_ANSI_M, controlKey | optionKey | cmdKey)
        }
    }
}
