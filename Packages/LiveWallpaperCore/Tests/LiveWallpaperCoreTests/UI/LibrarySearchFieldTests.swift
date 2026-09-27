import AppKit
@testable import LiveWallpaperCore
import SwiftUI
import Testing

@MainActor
@Suite("Library search field prompt")
struct LibrarySearchFieldTests {
    private static let font = NSFont.preferredFont(forTextStyle: .body)
    private static let spanishLong = "Buscar por nombre o etiqueta"

    private static func width(_ text: String) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    private static func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        return view.subviews.lazy.compactMap(textField).first
    }

    /// The field at `width` with nothing typed, laid out once at 2x: at 1x the magnifier rounds to 14pt and
    /// the text field holds 1pt more than `promptFits` counts.
    private static func hosted(_ prompt: String, shortPrompt: LocalizedStringKey?, width: CGFloat) throws -> NSTextField {
        let host = NSHostingView(rootView: LibrarySearchField(
            text: .constant(""), prompt: LocalizedStringKey(prompt), shortPrompt: shortPrompt
        ).frame(width: width).environment(\.displayScale, 2))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 40)
        host.layoutSubtreeIfNeeded()
        return try #require(textField(in: host), "the field drew no text field")
    }

    @Test("The Spanish long prompt fits neither the floor nor the ceiling; English fits where its width says")
    func promptFitsByMeasuredWidth() {
        let floor = DesignTokens.LibraryFilterBar.searchMinWidth
        let ceiling = DesignTokens.LibraryFilterBar.searchMaxWidth
        print("SEARCHPROMPT widths es long \(Self.width(Self.spanishLong)), en long \(Self.width("Search by name or tag")), en \(Self.width("Search by name"))")
        #expect(!LibrarySearchField.promptFits(Self.spanishLong, width: floor, font: Self.font))
        // 180pt of text plus 46pt of chrome needs 226pt, past the 216pt ceiling.
        #expect(!LibrarySearchField.promptFits(Self.spanishLong, width: ceiling, font: Self.font))
        #expect(LibrarySearchField.promptFits(Self.spanishLong, width: 227, font: Self.font))
        // 136.3pt needs 182.3pt: past the 168pt ideal, inside the ceiling.
        #expect(LibrarySearchField.promptFits("Search by name or tag", width: ceiling, font: Self.font))
        #expect(!LibrarySearchField.promptFits("Search by name or tag", width: DesignTokens.LibraryFilterBar.searchIdealWidth, font: Self.font))
        // 97.1pt needs 143.1pt, so the floor cuts even the shorter English prompt.
        #expect(!LibrarySearchField.promptFits("Search by name", width: floor, font: Self.font))
    }

    @Test("A prompt fits exactly when the drawn text field holds its placeholder, which is drawn in the measured font")
    func promptFitsMatchesTheDrawnField() throws {
        for width in [CGFloat(132), 168, 182, 183, 216] {
            for prompt in [Self.spanishLong, "Search by name or tag", "Search by name"] {
                let field = try Self.hosted(prompt, shortPrompt: nil, width: width)
                #expect(
                    field.font?.fontName == Self.font.fontName && field.font?.pointSize == Self.font.pointSize,
                    Comment(rawValue: "the field draws \(String(describing: field.font))")
                )
                let cell = try #require(field.cell as? NSTextFieldCell)
                let holds = cell.cellSize.width <= field.frame.width
                #expect(
                    LibrarySearchField.promptFits(prompt, width: width, font: Self.font) == holds,
                    Comment(rawValue: "\(prompt) at \(width): placeholder \(cell.cellSize.width) in \(field.frame.width)")
                )
            }
        }
    }

    @Test("With a short prompt the field draws it only when the long one does not fit")
    func shortPromptStandsInWhenTheLongOneDoesNotFit() throws {
        let floor = try Self.hosted(Self.spanishLong, shortPrompt: "Buscar", width: DesignTokens.LibraryFilterBar.searchMinWidth)
        #expect((floor.placeholderString ?? floor.placeholderAttributedString?.string) == "Buscar")
        let ceiling = try Self.hosted("Search by name or tag", shortPrompt: "Search", width: DesignTokens.LibraryFilterBar.searchMaxWidth)
        #expect((ceiling.placeholderString ?? ceiling.placeholderAttributedString?.string) == "Search by name or tag")
    }
}
