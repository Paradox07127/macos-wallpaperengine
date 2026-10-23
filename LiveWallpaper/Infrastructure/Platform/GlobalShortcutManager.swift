import Foundation
import AppKit
import Carbon.HIToolbox
import LiveWallpaperCore
import Observation

enum GlobalShortcutRegistrationState: Equatable, Sendable {
    case registered
    case failed(OSStatus)
}

/// Outcome of the latest registration pass; an action without an entry was not attempted (unbound or shortcuts off).
@MainActor
@Observable
final class GlobalShortcutRegistrationStatus {
    static let shared = GlobalShortcutRegistrationStatus()

    private(set) var states: [GlobalShortcutAction: GlobalShortcutRegistrationState] = [:]

    func replace(with states: [GlobalShortcutAction: GlobalShortcutRegistrationState]) {
        guard self.states != states else { return }
        self.states = states
    }
}

/// Delivery goes through `GetEventDispatcherTarget()` plus a file-level C trampoline. An inline `@MainActor` closure on `GetApplicationEventTarget()` can return `noErr` and still never fire in an accessory / `LSUIElement` app, especially in Release.
@MainActor
final class GlobalShortcutManager {
    typealias HotKeyRegistrar = @MainActor (_ keyCode: UInt32, _ carbonModifiers: UInt32, _ id: EventHotKeyID)
        -> (status: OSStatus, ref: EventHotKeyRef?)

    private weak var screenManager: ScreenManager?
    private let onOpenSettings: () -> Void
    private let registrationStatus: GlobalShortcutRegistrationStatus
    private let registerHotKey: HotKeyRegistrar
    /// MainActor-only; `nonisolated(unsafe)` so deinit can tear down Carbon refs.
    nonisolated(unsafe) private var registrations: [GlobalShortcutAction: HotKeyRegistration] = [:]
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    nonisolated(unsafe) private var preferenceObserver: NSObjectProtocol?

    init(
        screenManager: ScreenManager,
        onOpenSettings: @escaping () -> Void,
        registrationStatus: GlobalShortcutRegistrationStatus = .shared,
        registerHotKey: @escaping HotKeyRegistrar = GlobalShortcutManager.registerCarbonHotKey
    ) {
        self.screenManager = screenManager
        self.onOpenSettings = onOpenSettings
        self.registrationStatus = registrationStatus
        self.registerHotKey = registerHotKey
    }

    deinit {
        cleanupCarbonState()
    }

    func start() {
        guard installEventHandlerIfNeeded() else { return }
        registerFromPreferences()
        observePreferenceChanges()
    }

    func stop() {
        cleanupCarbonState()
    }

    // MARK: - Registration

    private func registerFromPreferences() {
        let settings = SettingsManager.shared.loadGlobalSettings()
        guard settings.globalShortcutsEnabled else {
            unregisterAll()
            registrationStatus.replace(with: [:])
            // Keep the event handler so re-enable can re-register without reinstall.
            Logger.info("Global shortcuts master switch is off", category: .startup)
            return
        }

        let overrides = settings.globalShortcuts
        var bindings: [GlobalShortcutAction: GlobalShortcutBinding] = [:]
        for action in GlobalShortcutAction.allCases {
            if overrides.keys.contains(action.rawAction) {
                bindings[action] = overrides[action.rawAction] ?? nil
            } else {
                bindings[action] = GlobalShortcutAction.defaultBinding(for: action)
            }
        }
        register(bindings)
        Logger.info(
            "Registered \(registrations.count) global shortcuts",
            category: .startup
        )
    }

    /// Replaces every registration and publishes each action's outcome to `registrationStatus`.
    func register(_ bindings: [GlobalShortcutAction: GlobalShortcutBinding]) {
        unregisterAll()
        var states: [GlobalShortcutAction: GlobalShortcutRegistrationState] = [:]
        for action in GlobalShortcutAction.allCases {
            guard let binding = bindings[action] else { continue }
            states[action] = register(action: action, binding: binding)
        }
        registrationStatus.replace(with: states)
    }

    private func register(action: GlobalShortcutAction, binding: GlobalShortcutBinding) -> GlobalShortcutRegistrationState {
        let hotKeyID = EventHotKeyID(signature: Self.fourCharCode("LWLP"), id: UInt32(action.signatureID))
        let result = registerHotKey(binding.keyCode, carbonModifiers(for: binding.modifiers), hotKeyID)

        guard result.status == noErr, let hotKeyRef = result.ref else {
            Logger.warning(
                "Failed to register hot key for \(action.rawValue): \(Self.describeStatus(result.status))",
                category: .general
            )
            return .failed(result.status)
        }

        registrations[action] = HotKeyRegistration(ref: hotKeyRef, hotKeyID: hotKeyID)
        return .registered
    }

    static func registerCarbonHotKey(
        keyCode: UInt32,
        carbonModifiers: UInt32,
        id: EventHotKeyID
    ) -> (status: OSStatus, ref: EventHotKeyRef?) {
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, carbonModifiers, id, GetEventDispatcherTarget(), 0, &hotKeyRef)
        return (status, hotKeyRef)
    }

    private func unregisterAll() {
        for (_, registration) in registrations {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
    }

    private func observePreferenceChanges() {
        guard preferenceObserver == nil else { return }
        // Observer queue is not guaranteed MainActor; hop instead of assumeIsolated.
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .globalShortcutsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.registerFromPreferences()
            }
        }
    }

    /// Safe from nonisolated deinit: all touched state is `nonisolated(unsafe)`.
    nonisolated private func cleanupCarbonState() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()

        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }

        if let observer = preferenceObserver {
            NotificationCenter.default.removeObserver(observer)
            preferenceObserver = nil
        }
    }

    // MARK: - Event Handler

    private func installEventHandlerIfNeeded() -> Bool {
        guard eventHandler == nil else { return true }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            carbonHotKeyEventHandler,
            1,
            &spec,
            userData,
            &eventHandler
        )

        guard status == noErr else {
            Logger.warning(
                "Failed to install global hot-key event handler: \(Self.describeStatus(status))",
                category: .general
            )
            eventHandler = nil
            return false
        }
        return true
    }

    fileprivate func dispatchHotKey(signatureID: Int) {
        guard let action = GlobalShortcutAction.action(forSignatureID: signatureID) else { return }
        // Drop presses that raced the master switch off before this MainActor hop.
        guard SettingsManager.shared.loadGlobalSettings().globalShortcutsEnabled else { return }
        guard let manager = screenManager else { return }
        Logger.debug("Global shortcut \(action.rawValue)", category: .general)
        switch action {
        case .togglePlayback:
            manager.togglePlayback()
        case .nextWallpaper:
            let target = screenUnderCursor(in: manager) ?? manager.screens.first
            if let target { manager.advancePlaylist(for: target) }
        case .previousWallpaper:
            let target = screenUnderCursor(in: manager) ?? manager.screens.first
            if let target { manager.regressPlaylist(for: target) }
        case .toggleMute:
            toggleGlobalMute(via: manager)
        case .toggleMouseInteraction:
            toggleGlobalMouseInteraction(via: manager)
        case .toggleWallpapers:
            manager.setWallpapersEnabled(!manager.wallpapersGloballyEnabled)
        case .reloadWallpapers:
            manager.reloadAllScreens()
        case .openSettings:
            onOpenSettings()
        }
    }

    /// Mute only video/scene — the wallpaper types that route audio.
    private func toggleGlobalMute(via manager: ScreenManager) {
        let mutedStates: [Bool] = manager.screens.compactMap { screen in
            guard let config = manager.getConfiguration(for: screen) else { return nil }
            switch config.wallpaperType {
            case .video, .scene: return config.muted
            default: return nil
            }
        }
        guard !mutedStates.isEmpty else { return }
        let newMuted = mutedStates.contains(false)
        for screen in manager.screens {
            switch manager.getConfiguration(for: screen)?.wallpaperType {
            case .video, .scene: manager.updateMuted(newMuted, for: screen)
            default: break
            }
        }
    }

    /// Toggle mouse seams on scene / HTML screens only.
    private func toggleGlobalMouseInteraction(via manager: ScreenManager) {
        let states: [Bool] = manager.screens.compactMap { screen in
            guard let config = manager.getConfiguration(for: screen) else { return nil }
            switch config.wallpaperType {
            case .scene:   return config.sceneMouseInteractionEnabled
            case .html:    return config.htmlConfig?.allowMouseInteraction
            default:       return nil
            }
        }
        guard !states.isEmpty else { return }
        let newEnabled = !states.contains(true)
        for screen in manager.screens {
            guard let config = manager.getConfiguration(for: screen) else { continue }
            switch config.wallpaperType {
            case .scene:
                manager.updateSceneMouseInteraction(newEnabled, for: screen)
            case .html:
                if var html = config.htmlConfig {
                    html.allowMouseInteraction = newEnabled
                    manager.updateHTMLConfig(html, for: screen)
                }
            default:
                break
            }
        }
    }

    private func screenUnderCursor(in manager: ScreenManager) -> Screen? {
        let mouseLocation = NSEvent.mouseLocation
        guard let nsScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else {
            return nil
        }
        return manager.screens.first { $0.id == screenIDFromNSScreen(nsScreen) }
    }

    private func screenIDFromNSScreen(_ screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }

    // MARK: - Modifier Translation

    private func carbonModifiers(for set: GlobalShortcutBinding.ModifierSet) -> UInt32 {
        var mask: UInt32 = 0
        if set.contains(.command) { mask |= UInt32(cmdKey) }
        if set.contains(.option)  { mask |= UInt32(optionKey) }
        if set.contains(.control) { mask |= UInt32(controlKey) }
        if set.contains(.shift)   { mask |= UInt32(shiftKey) }
        return mask
    }

    private static func describeStatus(_ status: OSStatus) -> String {
        switch status {
        case noErr:
            "noErr"
        case OSStatus(eventHotKeyExistsErr):
            "eventHotKeyExistsErr(\(status))"
        case OSStatus(eventInternalErr):
            "eventInternalErr(\(status))"
        default:
            "status=\(status)"
        }
    }

    private static func fourCharCode(_ string: String) -> FourCharCode {
        let bytes = string.utf8
        var result: FourCharCode = 0
        for byte in bytes.prefix(4) {
            result = (result << 8) | FourCharCode(byte)
        }
        return result
    }
}

private struct HotKeyRegistration {
    let ref: EventHotKeyRef
    let hotKeyID: EventHotKeyID
}

/// File-level C trampoline. Must not be an inline closure inside the
/// `@MainActor` class — Carbon stores a raw `EventHandlerUPP`.
private func carbonHotKeyEventHandler(
    _: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var receivedID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &receivedID
    )
    guard status == noErr else { return status }

    let signatureID = Int(receivedID.id)
    let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        manager.dispatchHotKey(signatureID: signatureID)
    }
    return noErr
}

extension GlobalShortcutAction {
    /// Carbon `EventHotKeyID.id` tag (allCases index + 1; not the string raw value).
    var signatureID: Int {
        Self.allCases.firstIndex(of: self).map { $0 + 1 } ?? 0
    }

    static func action(forSignatureID id: Int) -> GlobalShortcutAction? {
        let index = id - 1
        guard allCases.indices.contains(index) else { return nil }
        return allCases[index]
    }
}
