import Testing
@testable import LiveWallpaperCore

@Suite("Card badge settings")
struct CardBadgeSettingsTests {

    /// These strings are persisted in UserDefaults. Editing one silently resets
    /// every user's choice for that badge back to the default, with no migration
    /// and no error — so they are pinned here rather than left to a rename.
    @Test("Defaults keys are stable and distinct")
    func defaultsKeysAreStableAndDistinct() {
        let keys = [
            CardBadgeSettings.showsRating,
            CardBadgeSettings.showsType,
            CardBadgeSettings.showsResolution,
            CardBadgeSettings.showsInLibrary,
            CardBadgeSettings.showsUpdate,
            CardBadgeSettings.showsInUse,
            CardBadgeSettings.typeStyle
        ]

        #expect(keys == [
            "loomscreen.cards.badge.rating.v1",
            "loomscreen.cards.badge.type.v1",
            "loomscreen.cards.badge.resolution.v1",
            "loomscreen.cards.badge.inLibrary.v1",
            "loomscreen.cards.badge.update.v1",
            "loomscreen.cards.badge.inUse.v1",
            "loomscreen.cards.badge.typeStyle.v1"
        ])
        #expect(Set(keys).count == keys.count)
    }

    @Test("Each type badge style renders the parts it names", arguments: [
        (CardTypeBadgeStyle.icon, true, false),
        (CardTypeBadgeStyle.text, false, true),
        (CardTypeBadgeStyle.iconAndText, true, true)
    ])
    func typeBadgeStyleRendersItsParts(style: CardTypeBadgeStyle, icon: Bool, text: Bool) {
        #expect(style.showsIcon == icon)
        #expect(style.showsText == text)
    }

    /// The raw values are the persisted representation, same reasoning as the keys.
    @Test("Type badge style raw values are stable")
    func typeBadgeStyleRawValuesAreStable() {
        #expect(CardTypeBadgeStyle.allCases.map(\.rawValue) == ["icon", "text", "iconAndText"])
        #expect(CardTypeBadgeStyle(rawValue: "icon") == .icon)
        #expect(CardTypeBadgeStyle(rawValue: "nonsense") == nil)
    }
}
