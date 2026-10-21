import Carbon
import Foundation

/// A global ⌥⌘K hot key. Carbon is the one API that registers an exclusive
/// system-wide shortcut without an event tap and without stealing the key from
/// a text field the reader is using elsewhere.
final class HotKeyManager: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onPress: (() -> Void)?

    func install() {
        guard hotKeyRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>
                    .fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.onPress?()
                }
                return noErr
            },
            1, &eventType, userData, &handlerRef)
        let identifier = EventHotKeyID(
            signature: OSType(0x4B4E444C), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_K), UInt32(cmdKey | optionKey), identifier,
            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }
}
