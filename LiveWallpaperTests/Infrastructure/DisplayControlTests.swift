import CoreGraphics
@testable import LiveWallpaper
import Testing

struct DisplayControlTests {
    private static let looksLike1512 = DisplayModeKey(width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964, refreshRate: 120)
    private static let looksLike1800 = DisplayModeKey(width: 1800, height: 1169, pixelWidth: 3600, pixelHeight: 2338, refreshRate: 120)
    private static let native60 = DisplayModeKey(width: 3024, height: 1964, pixelWidth: 3024, pixelHeight: 1964, refreshRate: 60)

    @Test func matchFindsModeByPropertiesAfterRenumbering() {
        let before: [(id: Int32, key: DisplayModeKey)] = [(1, Self.native60), (2, Self.looksLike1512), (3, Self.looksLike1800)]
        let after: [(id: Int32, key: DisplayModeKey)] = [(17, Self.looksLike1800), (42, Self.native60), (9, Self.looksLike1512)]

        let original = DisplayModes.firstMode(matching: Self.looksLike1512, in: before) { $0.key }
        let renumbered = DisplayModes.firstMode(matching: Self.looksLike1512, in: after) { $0.key }

        #expect(original?.id == 2)
        #expect(renumbered?.id == 9)
    }

    @Test func matchReturnsNilWhenNoModeHasTheProperties() {
        let sameSizeOtherRate = DisplayModeKey(width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964, refreshRate: 60)
        let lowResolution = DisplayModeKey(width: 1512, height: 982, pixelWidth: 1512, pixelHeight: 982, refreshRate: 120)

        let match = DisplayModes.firstMode(matching: Self.looksLike1512, in: [sameSizeOtherRate, lowResolution, Self.native60]) { $0 }

        #expect(match == nil)
    }

    @Test func optionsCollapseDuplicatesAndKeepFlags() {
        let options = DisplayModes.options(
            from: [
                (Self.native60, false),
                (Self.looksLike1512, false),
                (Self.native60, true),
                (Self.looksLike1512, false),
                (Self.looksLike1800, false),
            ],
            current: Self.looksLike1512
        )

        #expect(options.map(\.key) == [Self.native60, Self.looksLike1512, Self.looksLike1800])
        #expect(options.map(\.isNative) == [true, false, false])
        #expect(options.map(\.isCurrent) == [false, true, false])
        #expect(options.map(\.isHiDPI) == [false, true, true])
    }

    #if !MAS_BUILD
    @Test func disablingTheOnlyOnlineDisplayIsRefused() {
        #expect(throws: DisplayControlError.wouldLeaveNoOnlineDisplay) {
            try DisplayPower.requireAnotherOnlineDisplay(disabling: 1, online: [1])
        }
    }

    @Test func disablingOneOfTwoOnlineDisplaysIsAllowed() throws {
        try DisplayPower.requireAnotherOnlineDisplay(disabling: 1, online: [1, 4])
    }
    #endif
}
