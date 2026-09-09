import LiveWallpaperCore
import SwiftUI

/// Observe card preferences once at the window root, using the app-scoped defaults suite.
private struct GalleryCardPreferencesReader: ViewModifier {
    @AppStorage(CardBadgeSettings.showsRating, store: .appScoped()) private var showsRating = true
    @AppStorage(CardBadgeSettings.showsType, store: .appScoped()) private var showsType = true
    @AppStorage(CardBadgeSettings.showsResolution, store: .appScoped()) private var showsResolution = true
    @AppStorage(CardBadgeSettings.showsInLibrary, store: .appScoped()) private var showsInLibrary = true
    @AppStorage(CardBadgeSettings.showsUpdate, store: .appScoped()) private var showsUpdate = true
    @AppStorage(CardBadgeSettings.showsInUse, store: .appScoped()) private var showsInUse = true
    @AppStorage(CardBadgeSettings.typeStyle, store: .appScoped()) private var typeStyle: CardTypeBadgeStyle = .icon
    @AppStorage(MatureContentSettings.blursThumbnails, store: .appScoped()) private var blursMature = true

    func body(content: Content) -> some View {
        content.environment(
            \.galleryCardPreferences,
            GalleryCardPreferences(
                showsRating: showsRating,
                showsType: showsType,
                showsResolution: showsResolution,
                showsInLibrary: showsInLibrary,
                showsUpdate: showsUpdate,
                showsInUse: showsInUse,
                typeStyle: typeStyle,
                blursMatureThumbnails: blursMature
            )
        )
    }
}

extension View {
    func providesGalleryCardPreferences() -> some View {
        modifier(GalleryCardPreferencesReader())
    }
}

/// Defaults keys for the adult-content gate, named so the card and the reader
/// can't drift apart on a string literal.
enum MatureContentSettings {
    static let blursThumbnails = "loomscreen.workshop.blurMatureThumbnails.v1"
    static let confirmed = "loomscreen.workshop.matureContentConfirmed.v1"

    /// Read on activation; this preference needs no per-tile observation.
    @MainActor
    static var isConfirmed: Bool {
        UserDefaults.appScoped().bool(forKey: confirmed)
    }

    @MainActor
    static func confirm() {
        UserDefaults.appScoped().set(true, forKey: confirmed)
    }
}
