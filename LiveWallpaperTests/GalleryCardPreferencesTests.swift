import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

/// The gallery cards used to carry their display defaults as `@AppStorage`, one
/// property wrapper per setting per tile. A 50-tile Workshop page therefore
/// installed ~300 KVO observations on the defaults suite, and re-installed them
/// as tiles recycled under the scroller. They now read one environment value
/// published once per window.
@Suite("Gallery card preferences")
struct GalleryCardPreferencesTests {

    @Test("Falling back to the environment default matches the shipped defaults")
    func defaultsMatchShippedValues() {
        // A card rendered outside the provider gets `defaultValue`. If these
        // drifted from the `@AppStorage` defaults in the reader, badges would
        // silently disappear in whatever surface forgot the modifier.
        let defaults = GalleryCardPreferences()
        #expect(defaults.showsRating)
        #expect(defaults.showsType)
        #expect(defaults.showsResolution)
        #expect(defaults.showsInLibrary)
        #expect(defaults.showsUpdate)
        #expect(defaults.showsInUse)
        #expect(defaults.blursMatureThumbnails)
        #expect(defaults.typeStyle == .icon)
    }

    @Test("The reader publishes every card-badge default")
    func readerCoversEverySetting() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/GalleryCardPreferencesReader.swift")
        let settings = [
            "CardBadgeSettings.showsRating",
            "CardBadgeSettings.showsType",
            "CardBadgeSettings.showsResolution",
            "CardBadgeSettings.showsInLibrary",
            "CardBadgeSettings.showsUpdate",
            "CardBadgeSettings.showsInUse",
            "CardBadgeSettings.typeStyle",
            "MatureContentSettings.blursThumbnails"
        ]
        let missing = settings.filter { !source.contains($0) }
        #expect(missing.isEmpty, Comment(rawValue: "Not published: \(missing.joined(separator: ", "))"))
    }

    @Test("Grid cards hold no defaults observers of their own")
    func gridCardsHoldNoDefaultsObservers() throws {
        // `BrowseCard` takes the preferences as an input rather than reading the
        // environment, because it is an `EquatableView` and an environment read
        // inside a short-circuited `body` goes stale. `HistoryRow` is not, so it
        // reads the environment directly. Either is fine; what must never come
        // back is a per-tile `@AppStorage`, which registers a KVO observation on
        // the defaults suite for every card on screen.
        let cards = [
            "LiveWallpaper/Views/Workshop/BrowseCard.swift",
            "LiveWallpaper/Views/ScreenDetail/HistoryRow.swift"
        ]
        var offenders: [String] = []
        for path in cards {
            let source = try RepositoryRoot.source(path)
            // The open paren is what distinguishes a declaration from the prose
            // in these files' own doc comments.
            if source.contains("@AppStorage(") {
                offenders.append("\(path) declares @AppStorage")
            }
            let readsEnvironment = source.contains("@Environment(\\.galleryCardPreferences)")
            let takesInput = source.contains("let cardPreferences: GalleryCardPreferences")
            if !readsEnvironment, !takesInput {
                offenders.append("\(path) gets its badge preferences from neither the environment nor an input")
            }
        }
        #expect(offenders.isEmpty, Comment(rawValue: offenders.joined(separator: "\n")))

        // …and whoever hands them to an EquatableView must compare them, or the
        // card keeps rendering yesterday's settings.
        let card = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/BrowseCard.swift")
        if card.contains(": View, Equatable") {
            #expect(card.contains("lhs.cardPreferences == rhs.cardPreferences"))
            #expect(card.contains("lhs.reduceMotion == rhs.reduceMotion"))
        }
    }

    /// Apple's guidance is to limit how many glass effects are on screen at once
    /// and to reserve the material for the most important controls rather than
    /// ordinary content metadata. A gallery page carries roughly four badges on
    /// each of ~50 cards, every one of them sampling the content scrolling behind
    /// it, so the shared card chrome switches them to a plain tinted fill.
    /// Detail and inspector surfaces do not use this chrome and keep the glass.
    @Test("Badges that scroll in a gallery do not use real glass")
    func galleryBadgesAreOpaque() throws {
        let chrome = try RepositoryRoot.source(
            "Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/UI/Components/GalleryTileChrome.swift"
        )
        #expect(chrome.contains(".thumbnailBadgeSurface(.opaque)"))

        let glass = try RepositoryRoot.source(
            "Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/UI/Components/AdaptiveGlass.swift"
        )
        // The real material is reachable only when the surface asks for it.
        #expect(glass.contains("#available(macOS 26.0, *), surface == .glass"))
    }

    @Test("The window root publishes the preferences the cards depend on")
    func rootPublishesPreferences() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/ContentView.swift")
        #expect(source.contains(".providesGalleryCardPreferences()"))
    }
}
