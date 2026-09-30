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

    @Test("Hover draws no GIF badge, the rating leads the top row, and the title scrolls on hover")
    func topRowAndTitle() throws {
        let source = try RepositoryRoot.source(Self.path)
        #expect(!source.contains("showsGIF") && !source.contains("\"GIF\""), "hovering still raises a GIF badge")
        let topRow = try #require(source.range(of: "private struct EditDeskTopRow")).lowerBound
        let statsRow = try #require(source.range(of: "private struct EditDeskStatsRow")).lowerBound
        #expect(source[topRow ..< statsRow].contains("ThumbnailBadge(verbatim: rating)"), "the top row carries no rating badge")
        let band = try #require(source.range(of: "private var editDeskInfoBand")).lowerBound
        let marks = try #require(source.range(of: "private var editDeskMarks")).lowerBound
        let bandSource = source[band ..< marks]
        #expect(!bandSource.contains("rating"), "the rating still ends the title row too")
        #expect(bandSource.contains("MarqueeText(") && bandSource.contains("isActive: isHovered"), "the title no longer scrolls on hover")
    }

    @Test("The subscriber count uses the short subs keys")
    func subscriberCopy() throws {
        let source = try RepositoryRoot.source(Self.path)
        #expect(!source.contains(" subscribers\""), "the card still says subscribers")
        #expect(source.contains("\\(subs) subs\"") && source.contains("compact(subs)) subs\""), "a subscriber branch does not use the subs keys")
    }

    @Test("The in-library check is the solid green disc with a dark glyph")
    func presenceCheck() throws {
        let source = try RepositoryRoot.source(Self.path)
        #expect(source.contains("inLibraryBadgeFill"))
        #expect(source.contains("appearance: .solid("))
    }
}
