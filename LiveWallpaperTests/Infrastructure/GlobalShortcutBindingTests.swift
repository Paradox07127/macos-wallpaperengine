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
