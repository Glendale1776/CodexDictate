import AppKit
import Carbon
import Foundation

@MainActor
protocol GlobalHotKeyServicing: AnyObject {
    var onPressed: (() -> Void)? { get set }
    var onSubmitPressed: (() -> Void)? { get set }
    func register(_ shortcut: HotKeyShortcut) throws
    func setOptionSubmitEnabled(_ enabled: Bool) throws
    func unregister()
}

enum HotKeyRegistrationError: LocalizedError, Equatable {
    case invalidShortcut
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidShortcut: "Choose Control + Option, or a key shortcut with Option, Control, or Command"
        case .registrationFailed: "The shortcut could not be registered; another application may be using it"
        }
    }
}

@MainActor
final class GlobalHotKeyService: GlobalHotKeyServicing {
    var onPressed: (() -> Void)?
    var onSubmitPressed: (() -> Void)?

    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    nonisolated(unsafe) private var primaryHotKey: EventHotKeyRef?
    nonisolated(unsafe) private var globalModifierMonitor: Any?
    nonisolated(unsafe) private var localModifierMonitor: Any?
    private var modifierShortcut: HotKeyShortcut?
    private var modifierEdgeTracker = ModifierChordEdgeTracker()
    private var optionSubmitTracker = OptionSubmitGestureTracker()
    private let primaryHotKeyID = EventHotKeyID(signature: 0x43445844, id: 1) // CDXD

    init() {
        installHandler()
    }

    deinit {
        if let primaryHotKey { UnregisterEventHotKey(primaryHotKey) }
        if let globalModifierMonitor { NSEvent.removeMonitor(globalModifierMonitor) }
        if let localModifierMonitor { NSEvent.removeMonitor(localModifierMonitor) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func register(_ shortcut: HotKeyShortcut) throws {
        guard shortcut.isValid else { throw HotKeyRegistrationError.invalidShortcut }
        unregisterPrimary()
        if shortcut.isModifierOnly {
            try registerModifierChord(shortcut)
            return
        }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            primaryHotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            throw HotKeyRegistrationError.registrationFailed(status)
        }
        primaryHotKey = reference
    }

    func unregister() {
        optionSubmitTracker.setEnabled(false)
        unregisterPrimary()
    }

    func setOptionSubmitEnabled(_ enabled: Bool) throws {
        if enabled { try ensureModifierMonitors() }
        // Enabling is initiated by the Control+Option start chord. Always block that
        // chord's queued release events, even if the physical keys are already up by
        // the time recording initialization reaches this point.
        optionSubmitTracker.setEnabled(enabled, currentModifiers: enabled ? 1 : 0)
        if enabled {
            Task { @MainActor [weak self] in
                try? await Task<Never, Never>.sleep(nanoseconds: 50_000_000)
                guard let self, Self.currentCarbonModifiers() == 0 else { return }
                self.optionSubmitTracker.synchronizeNeutralState()
            }
        }
        if !enabled, modifierShortcut == nil { removeModifierMonitors() }
    }

    private func unregisterPrimary() {
        if let primaryHotKey {
            UnregisterEventHotKey(primaryHotKey)
            self.primaryHotKey = nil
        }
        modifierShortcut = nil
        modifierEdgeTracker.reset()
        if !optionSubmitTracker.isEnabled { removeModifierMonitors() }
    }

    private func registerModifierChord(_ shortcut: HotKeyShortcut) throws {
        modifierShortcut = shortcut
        do {
            try ensureModifierMonitors()
        } catch {
            modifierShortcut = nil
            throw error
        }
    }

    private func ensureModifierMonitors() throws {
        guard globalModifierMonitor == nil, localModifierMonitor == nil else { return }
        globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            let rawFlags = event.modifierFlags.rawValue
            Task { @MainActor [weak self] in
                self?.modifierFlagsChanged(NSEvent.ModifierFlags(rawValue: rawFlags))
            }
        }
        localModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            let rawFlags = event.modifierFlags.rawValue
            Task { @MainActor [weak self] in
                self?.modifierFlagsChanged(NSEvent.ModifierFlags(rawValue: rawFlags))
            }
            return event
        }
        guard globalModifierMonitor != nil, localModifierMonitor != nil else {
            removeModifierMonitors()
            throw HotKeyRegistrationError.registrationFailed(OSStatus(paramErr))
        }
    }

    private func removeModifierMonitors() {
        if let globalModifierMonitor {
            NSEvent.removeMonitor(globalModifierMonitor)
            self.globalModifierMonitor = nil
        }
        if let localModifierMonitor {
            NSEvent.removeMonitor(localModifierMonitor)
            self.localModifierMonitor = nil
        }
    }

    private func modifierFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        let currentModifiers = Self.carbonModifiers(from: flags)
        if let shortcut = modifierShortcut {
            if modifierEdgeTracker.update(
                currentModifiers: currentModifiers,
                requiredModifiers: shortcut.modifiers
            ) {
                onPressed?()
            }
        }
        if optionSubmitTracker.update(currentModifiers: currentModifiers) {
            onSubmitPressed?()
        }
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= 4096 }
        if flags.contains(.option) { modifiers |= 2048 }
        if flags.contains(.shift) { modifiers |= 512 }
        if flags.contains(.command) { modifiers |= 256 }
        return modifiers
    }

    private static func currentCarbonModifiers() -> UInt32 {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        var modifiers: UInt32 = 0
        if flags.contains(.maskControl) { modifiers |= 4096 }
        if flags.contains(.maskAlternate) { modifiers |= 2048 }
        if flags.contains(.maskShift) { modifiers |= 512 }
        if flags.contains(.maskCommand) { modifiers |= 256 }
        return modifiers
    }

    private func installHandler() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            Self.callback,
            types.count,
            &types,
            pointer,
            &eventHandler
        )
    }

    private nonisolated static let callback: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        let service = Unmanaged<GlobalHotKeyService>.fromOpaque(userData).takeUnretainedValue()
        var hotKeyID = EventHotKeyID()
        guard GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        ) == noErr else { return OSStatus(eventNotHandledErr) }

        let eventKind = GetEventKind(event)
        Task { @MainActor in
            if hotKeyID.id == service.primaryHotKeyID.id {
                if eventKind == UInt32(kEventHotKeyPressed) {
                    service.onPressed?()
                }
            }
        }
        return noErr
    }
}
