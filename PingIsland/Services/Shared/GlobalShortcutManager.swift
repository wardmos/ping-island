import AppKit
import Carbon.HIToolbox
import Combine

extension Notification.Name {
    static let pingIslandOpenActiveSessionShortcut = Notification.Name("pingIslandOpenActiveSessionShortcut")
    static let pingIslandOpenSessionListShortcut = Notification.Name("pingIslandOpenSessionListShortcut")
    static let pingIslandPresentNotchDetachmentHint = Notification.Name("pingIslandPresentNotchDetachmentHint")
    static let pingIslandCollapseIslandShortcut = Notification.Name("pingIslandCollapseIslandShortcut")
}

@MainActor
final class GlobalShortcutManager {
    static let shared = GlobalShortcutManager()

    private var hotKeyRefs: [GlobalShortcutAction: EventHotKeyRef] = [:]
    private var registeredActionsByHotKeyID: [UInt32: GlobalShortcutAction] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var cancellables = Set<AnyCancellable>()
    private let signature = GlobalShortcutManager.fourCharCode(from: "PISL")
    private var nextHotKeyID: UInt32 = 100

    /// Reserved hot key id for the ESC-to-collapse shortcut, kept out of the
    /// dynamic range used by `nextHotKeyID` so the two never collide.
    private let escapeHotKeyID: UInt32 = 1
    private var escapeHotKeyRef: EventHotKeyRef?

    private init() {
        installEventHandlerIfNeeded()

        Publishers.CombineLatest(
            AppSettings.shared.$openActiveSessionShortcut,
            AppSettings.shared.$openSessionListShortcut
        )
        .sink { [weak self] _, _ in
            self?.refreshRegistrations()
        }
        .store(in: &cancellables)
    }

    func start() {
        refreshRegistrations()
    }

    private func refreshRegistrations() {
        unregisterAllHotKeys()

        var registeredShortcuts = Set<GlobalShortcut>()

        for action in GlobalShortcutAction.allCases {
            guard let shortcut = AppSettings.shortcut(for: action),
                  registeredShortcuts.insert(shortcut).inserted else {
                continue
            }

            register(shortcut, for: action)
        }
    }

    /// Registers (or unregisters) a borderless ESC hot key. It is only active
    /// while the island is expanded, so the rest of the time ESC keeps working
    /// normally in every other app. Using a Carbon hot key means we capture
    /// just ESC without making the panel key or grabbing any other keystroke,
    /// and without needing Accessibility permission.
    func setEscapeHotKeyEnabled(_ enabled: Bool) {
        guard !SessionMonitor.isRunningUnderXCTest else { return }

        if enabled {
            guard escapeHotKeyRef == nil else { return }

            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: signature, id: escapeHotKeyID)
            let status = RegisterEventHotKey(
                UInt32(kVK_Escape),
                0,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            guard status == noErr, let hotKeyRef else { return }
            escapeHotKeyRef = hotKeyRef
        } else {
            guard let escapeHotKeyRef else { return }
            UnregisterEventHotKey(escapeHotKeyRef)
            self.escapeHotKeyRef = nil
        }
    }

    private func register(_ shortcut: GlobalShortcut, for action: GlobalShortcutAction) {
        var hotKeyRef: EventHotKeyRef?
        let carbonID = nextRegistrationID()
        let hotKeyID = EventHotKeyID(signature: signature, id: carbonID)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else { return }
        hotKeyRefs[action] = hotKeyRef
        registeredActionsByHotKeyID[carbonID] = action
    }

    private func unregisterAllHotKeys() {
        for hotKeyRef in hotKeyRefs.values {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
        registeredActionsByHotKeyID.removeAll()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()
                return manager.handleHotKeyEvent(event)
            },
            1,
            &eventSpec,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandlerRef
        )
    }

    private func handleHotKeyEvent(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else {
            return status
        }

        if hotKeyID.id == escapeHotKeyID {
            NotificationCenter.default.post(name: .pingIslandCollapseIslandShortcut, object: nil)
            return noErr
        }

        guard let action = registeredActionsByHotKeyID[hotKeyID.id] else {
            return OSStatus(eventNotHandledErr)
        }

        switch action {
        case .openActiveSession:
            NotificationCenter.default.post(name: .pingIslandOpenActiveSessionShortcut, object: nil)
        case .openSessionList:
            NotificationCenter.default.post(name: .pingIslandOpenSessionListShortcut, object: nil)
        }

        return noErr
    }

    private func nextRegistrationID() -> UInt32 {
        defer {
            nextHotKeyID = nextHotKeyID == UInt32.max ? 100 : nextHotKeyID + 1
        }
        return nextHotKeyID
    }

    private static func fourCharCode(from string: String) -> OSType {
        string.utf8.prefix(4).reduce(0) { partial, character in
            (partial << 8) + OSType(character)
        }
    }
}
