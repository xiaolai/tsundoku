import Carbon
import Foundation
import TsundokuCore

/// One Carbon registration for the configurable shortcut.
///
/// `RegisterEventHotKey` reports success even when another application already
/// owns the combination — the spike measured both apps responding — so a
/// zero status means "registered in this process", not "exclusive". The
/// settings pane says so and offers a manual test.
final class GlobalHotKey: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var registrationStatus: OSStatus = -1
    private(set) var shortcut: CompanionHotKey?
    var onPress: (() -> Void)?

    var isRegistered: Bool {
        registrationStatus == noErr && hotKeyRef != nil
    }

    @discardableResult
    func install(_ shortcut: CompanionHotKey) -> OSStatus {
        uninstall()
        self.shortcut = shortcut
        guard shortcut.isValid else {
            registrationStatus = -1
            return -1
        }
        let handlerStatus = installHandlerIfNeeded()
        guard handlerStatus == noErr else {
            registrationStatus = handlerStatus
            return handlerStatus
        }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(
            signature: OSType(0x5453_4E44), id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode, carbonModifiers(shortcut.modifiers),
            identifier, GetApplicationEventTarget(), 0, &reference)
        hotKeyRef = reference
        registrationStatus = status
        TsundokuDiagnostics.shared.event(
            "hotkey_registration",
            [
                "status": Int(status),
                "shortcut": shortcut.displayName,
                "key_code": Int(shortcut.keyCode),
                "ref": reference != nil,
            ])
        return status
    }

    func uninstall() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        registrationStatus = -1
    }

    private func installHandlerIfNeeded() -> OSStatus {
        guard handlerRef == nil else { return noErr }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var identifier = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil,
                    &identifier)
                guard
                    parameterStatus == noErr,
                    identifier.signature == OSType(0x5453_4E44),
                    identifier.id == 1
                else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<GlobalHotKey>
                    .fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    TsundokuDiagnostics.shared.event("hotkey_pressed")
                    manager.onPress?()
                }
                return noErr
            },
            1, &eventType, userData, &handlerRef)
        if status != noErr { handlerRef = nil }
        return status
    }

    private func carbonModifiers(_ modifiers: CompanionHotKeyModifiers)
        -> UInt32
    {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
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
