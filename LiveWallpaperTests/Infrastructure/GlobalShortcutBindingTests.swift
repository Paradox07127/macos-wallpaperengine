import Carbon.HIToolbox
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("GlobalShortcutBinding: rendering & defaults")
struct GlobalShortcutBindingTests {
    @Test("Default bindings cover every action")
    func defaultBindingsCoverEveryAction() {
        for action in GlobalShortcutAction.allCases {
            let binding = GlobalShortcutAction.defaultBinding(for: action)
            #expect(binding != nil, "Action \(action.rawValue) ships without a default binding")
            #expect(binding?.modifiers.contains(.shift) == true || binding?.modifiers.contains(.control) == true,
                    "Default binding for \(action.rawValue) should include a modifier to avoid stealing a plain key")
        }
    }

    @Test("Shipped default bindings never collide with each other")
    func defaultBindingsDoNotCollide() {
        var seen: [GlobalShortcutBinding: GlobalShortcutAction] = [:]
        for action in GlobalShortcutAction.allCases {
            guard let binding = GlobalShortcutAction.defaultBinding(for: action) else { continue }
            if let owner = seen[binding] {
                Issue.record("\(action.rawValue) ships the same default binding as \(owner.rawValue)")
            }
            seen[binding] = action
        }
    }

    @Test("Display string includes modifier symbols and key name")
    func displayStringFormatsCorrectly() {
        let binding = GlobalShortcutBinding(keyCode: 49, modifiers: [.control, .shift])
        let rendered = binding.displayString
        #expect(rendered.contains("⌃"))
        #expect(rendered.contains("⇧"))
        #expect(rendered.contains("Space"))
    }

    @Test("Arrow key codes resolve to arrow glyphs")
    func arrowKeyCodesResolveToArrowGlyphs() {
        #expect(GlobalShortcutBinding.keyName(for: 124) == "→")
        #expect(GlobalShortcutBinding.keyName(for: 123) == "←")
        #expect(GlobalShortcutBinding.keyName(for: 125) == "↓")
        #expect(GlobalShortcutBinding.keyName(for: 126) == "↑")
    }

    @Test("Letter key codes resolve to uppercase letter")
    func letterKeyCodesResolveToUppercaseLetter() {
        #expect(GlobalShortcutBinding.keyName(for: 46) == "M")
        #expect(GlobalShortcutBinding.keyName(for: 0) == "A")
        #expect(GlobalShortcutBinding.keyName(for: 31) == "O")
    }

    @MainActor
    @Test("Character keys are named by the active keyboard layout, with the US map as fallback")
    func characterKeysFollowKeyboardLayout() {
        let azerty: (UInt32) -> String? = { [12: "a", 0: "q"][$0] }
        #expect(ShortcutKeyLabel.keyText(for: 12, layoutCharacter: azerty) == "A")
        #expect(GlobalShortcutBinding(keyCode: 12, modifiers: [.command]).displayString(layoutCharacter: azerty) == "⌘A")
        #expect(ShortcutKeyLabel.keyText(for: 12, layoutCharacter: { _ in nil }) == "Q")
        #expect(ShortcutKeyLabel.keyText(for: 49, layoutCharacter: { _ in "x" }) == "Space")
    }

    @Test("Restoring a default that another action now uses is refused and names that action")
    func resetRefusesDefaultTakenByAnotherAction() throws {
        let playbackDefault = try #require(GlobalShortcutAction.defaultBinding(for: .togglePlayback))
        var table = ShortcutBindingTable(overrides: [:])
        #expect(table.assign(nil, to: .togglePlayback) == .applied)
        #expect(table.assign(playbackDefault, to: .openSettings) == .applied)
        let beforeReset = table

        #expect(table.resetToDefault(.togglePlayback) == .duplicate(playbackDefault, usedBy: .openSettings))
        #expect(table == beforeReset, "a refused reset must leave both bindings as they were")
        #expect(table.binding(for: .togglePlayback) == nil)
    }

    @Test("Restoring a default nobody else uses brings it back")
    func resetRestoresFreeDefault() {
        var table = ShortcutBindingTable(overrides: [GlobalShortcutAction.toggleMute.rawAction: GlobalShortcutBinding?.none])
        #expect(table.resetToDefault(.toggleMute) == .applied)
        #expect(table.binding(for: .toggleMute) == GlobalShortcutAction.defaultBinding(for: .toggleMute))
    }

    @MainActor
    @Test("A hot key the system refuses reads back as failed for that action")
    func refusedRegistrationReadsBackAsFailed() {
        let screens = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: []),
            featureCatalog: FeatureCatalog(capabilities: .pro), originReconciler: PreservingOriginReconciler()
        ))
        let status = GlobalShortcutRegistrationStatus()
        let refused = OSStatus(eventHotKeyExistsErr)
        let manager = GlobalShortcutManager(
            screenManager: screens,
            onOpenSettings: {},
            registrationStatus: status,
            registerHotKey: { _, _, _ in (refused, nil) }
        )

        manager.register([.toggleMute: GlobalShortcutBinding(keyCode: 46, modifiers: [.control, .shift])])

        #expect(status.states == [.toggleMute: .failed(refused)])
    }
}

@Suite("GlobalShortcutManager: Carbon wiring")
struct GlobalShortcutCarbonWiringTests {
    @Test("Carbon signature IDs round-trip every action")
    func carbonSignatureIDsRoundTrip() {
        for action in GlobalShortcutAction.allCases {
            let id = action.signatureID
            #expect(id > 0)
            #expect(GlobalShortcutAction.action(forSignatureID: id) == action)
        }
        #expect(GlobalShortcutAction.action(forSignatureID: 0) == nil)
        #expect(GlobalShortcutAction.action(forSignatureID: GlobalShortcutAction.allCases.count + 1) == nil)
    }
}
