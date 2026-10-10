import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@Suite("Gallery card preferences")
struct GalleryCardPreferencesTests {

    @Test("Falling back to the environment default matches the shipped defaults")
    func defaultsMatchShippedValues() {
        // A card rendered outside the provider gets `defaultValue`.
        let defaults = GalleryCardPreferences()
        #expect(defaults.showsRating)
        #expect(defaults.showsResolution)
        #expect(defaults.showsInLibrary)
        #expect(defaults.showsUpdate)
        #expect(defaults.showsInUse)
        #expect(defaults.blursMatureThumbnails)
    }

    #if !LITE_BUILD
    @MainActor
    @Test("Same-title Workshop cards announce their authored content type")
    func workshopCardAnnouncesContentType() throws {
        let url = try #require(URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=123"))
        for type in ["Scene", "Video", "Web", "Preset"] {
            let item = WorkshopQueryItem(
                id: 123, rawTitle: "Same Title", shortDescription: "", creatorID: nil,
                previewImageURL: nil, fileSizeBytes: nil, timeUpdated: nil, subscriptionCount: nil,
                rating: nil, tags: [type], visibility: .public, isBanned: false,
                steamCommunityURL: url
            )
            let card = BrowseCard(item: item, cardPreferences: GalleryCardPreferences(), reduceMotion: true)
            #expect(card.accessibilityLabelText == "Same Title, \(WorkshopTagLocalization.displayName(type))")
        }
    }

    @Test("The S8 card's title-row rating and resolution badge obey their switches")
    func editDeskMarksObeySwitches() {
        func marks(_ preferences: GalleryCardPreferences) -> (rating: String?, resolution: String?) {
            BrowseCard.editDeskMarks(rating: 4.5, resolution: "4K", preferences: preferences)
        }
        let rating = "★ " + 4.5.formatted(.number.precision(.fractionLength(1)))
        let shown = marks(GalleryCardPreferences())
        #expect(shown.rating == rating && shown.resolution == "4K", "with every switch on the card draws \(shown)")
        let noRating = marks(GalleryCardPreferences(showsRating: false))
        #expect(noRating.rating == nil, "the rating shows with its switch off")
        #expect(noRating.resolution == "4K", "turning the rating off took the resolution badge with it")
        let noResolution = marks(GalleryCardPreferences(showsResolution: false))
        #expect(noResolution.resolution == nil, "the resolution badge shows with its switch off")
        #expect(noResolution.rating == rating, "turning the resolution off took the rating with it")
    }
    #endif
}
