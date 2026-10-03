@testable import LiveWallpaper
import Testing

@MainActor
@Suite("Shortcut key label")
struct ShortcutKeyLabelTests {
    @Test("The keypad Enter shows its own glyph, so it never reads as Return")
    func keypadEnterIsNotReturn() {
        #expect(ShortcutKeyLabel.keySymbol(for: 36) == "return")
        #expect(ShortcutKeyLabel.keySymbol(for: 76) == nil, "keypad Enter draws the Return symbol")
        #expect(ShortcutKeyLabel.keyText(for: 76) == "\u{2324}")
    }
}
