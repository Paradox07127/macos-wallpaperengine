import Foundation
import Testing

/// SCREENS S8a's card skin, read off the source: border, resting shadow, info band and the
/// in-library check have no measurable geometry of their own in an offscreen frame.
@Suite("Edit Desk browse card skin — source contract")
struct BrowseCardEditDeskSkinTests {
    private static let path = "LiveWallpaper/Views/Workshop/BrowseCard.swift"

    @Test("The Edit Desk card wears the .08 border and carries its shadow at rest")
    func editDeskChrome() throws {
        let source = try RepositoryRoot.source(Self.path)
        #expect(source.contains("editDeskBorder"))
        #expect(
            source.contains("strokeBorder(DesignTokens.EditDesk.Colors.strokeRegular"),
            "the Edit Desk card border is not the .08 stroke SCREENS S8 asks for"
        )
        #expect(source.contains(".workshopCard"), "the card has no resting drop shadow")
        #expect(source.contains(".workshopCardRing"), "the card has no 1px ring")
        #expect(source.contains(".hoverCard"), "hover no longer lifts the card")
    }

    @Test("The info band is SCREENS S8's 24/10/10 padding, .85 gradient and 12pt title")
    func infoBand() throws {
        let source = try RepositoryRoot.source(Self.path)
        #expect(source.contains("Typography.workshopCardTitle"), "the band still uses the 11pt library card title")
        #expect(source.contains("gradientWorkshopCardBottom"), "the band still fades to the .5 library gradient")
        #expect(source.contains("workshopCardBandTop"))
        #expect(source.contains("workshopCardBandInset"))
    }

    @Test("The in-library check is the solid green disc with a dark glyph")
    func presenceCheck() throws {
        let source = try RepositoryRoot.source(Self.path)
        #expect(source.contains("inLibraryBadgeFill"))
        #expect(source.contains("appearance: .solid("))
    }

    @Test("The legacy card keeps its own skin")
    func legacyBranchUnchanged() throws {
        let source = try RepositoryRoot.source(Self.path)
        #expect(source.contains("ThumbnailTitleBand(title: item.title, isHovering: isHovered)"))
        #expect(
            source.contains("ThumbnailPresenceCheck(tint: Self.inLibraryGreen)"),
            "the legacy title band's check changed appearance"
        )
        #expect(source.contains("private static let inLibraryGreen = DesignTokens.Colors.badgeActive"))
    }
}
