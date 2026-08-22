import SwiftUI

/// Which badges the library and Workshop grids draw on their thumbnails.
///
/// Kept in `UserDefaults` rather than `GlobalSettings` to match the app's other
/// card-display preference (`loomscreen.workshop.blurMatureThumbnails.v1`):
/// these change what one Mac's grid looks like, not how a wallpaper runs.
public enum CardBadgeSettings {
    public static let showsRating = "loomscreen.cards.badge.rating.v1"
    public static let showsType = "loomscreen.cards.badge.type.v1"
    public static let showsResolution = "loomscreen.cards.badge.resolution.v1"
    public static let showsInLibrary = "loomscreen.cards.badge.inLibrary.v1"
    public static let showsUpdate = "loomscreen.cards.badge.update.v1"
    public static let showsInUse = "loomscreen.cards.badge.inUse.v1"
    public static let typeStyle = "loomscreen.cards.badge.typeStyle.v1"
}

/// The card-chrome defaults resolved once for a whole grid.
///
/// These used to be `@AppStorage` on the card itself. Each one installs a KVO
/// observation on the defaults suite when its view is installed, so a 50-tile
/// Workshop page registered — and, as tiles recycled under the scroller,
/// repeatedly re-registered — hundreds of them. Reading them once per pane and
/// handing the result down through the environment costs each card nothing.
public struct GalleryCardPreferences: Equatable, Sendable {
    public var showsRating: Bool
    public var showsType: Bool
    public var showsResolution: Bool
    public var showsInLibrary: Bool
    public var showsUpdate: Bool
    public var showsInUse: Bool
    public var typeStyle: CardTypeBadgeStyle
    public var blursMatureThumbnails: Bool

    public init(
        showsRating: Bool = true,
        showsType: Bool = true,
        showsResolution: Bool = true,
        showsInLibrary: Bool = true,
        showsUpdate: Bool = true,
        showsInUse: Bool = true,
        typeStyle: CardTypeBadgeStyle = .icon,
        blursMatureThumbnails: Bool = true
    ) {
        self.showsRating = showsRating
        self.showsType = showsType
        self.showsResolution = showsResolution
        self.showsInLibrary = showsInLibrary
        self.showsUpdate = showsUpdate
        self.showsInUse = showsInUse
        self.typeStyle = typeStyle
        self.blursMatureThumbnails = blursMatureThumbnails
    }
}

private struct GalleryCardPreferencesKey: EnvironmentKey {
    /// Matches every `@AppStorage` default these replaced, so a card rendered
    /// outside a pane that publishes them still looks shipped-correct.
    static let defaultValue = GalleryCardPreferences()
}

public extension EnvironmentValues {
    var galleryCardPreferences: GalleryCardPreferences {
        get { self[GalleryCardPreferencesKey.self] }
        set { self[GalleryCardPreferencesKey.self] = newValue }
    }
}

/// How the type badge renders. `icon` is the default because a worded pill plus
/// the rating pill takes most of a thumbnail's top edge at grid widths.
public enum CardTypeBadgeStyle: String, CaseIterable, Identifiable, Sendable {
    case icon
    case text
    case iconAndText

    public var id: String { rawValue }

    public var showsIcon: Bool { self != .text }
    public var showsText: Bool { self != .icon }
}

/// Type badge floating on a thumbnail, honoring the user's icon/text choice.
///
/// The badge is `accessibilityHidden` — it is a glyph on artwork, and the cards
/// combine their children into one element. **The hosting card must restate the
/// type in its own accessibility label**, or the `.icon` style leaves VoiceOver
/// with no way to reach it. Sighted users get the word from `help`.
public struct ThumbnailTypeBadge: View {
    private let systemImage: String
    private let title: String
    private let style: CardTypeBadgeStyle

    public init(systemImage: String, title: String, style: CardTypeBadgeStyle) {
        self.systemImage = systemImage
        self.title = title
        self.style = style
    }

    /// The same pill as every other thumbnail badge; only the icon/text switch
    /// and the caps tracking are its own. `.icon` takes the glyph-only
    /// initializer rather than passing an empty string, which would still
    /// reserve a text slot.
    @ViewBuilder
    public var body: some View {
        if style.showsText {
            ThumbnailBadge(
                verbatim: title.uppercased(with: .current),
                systemImage: style.showsIcon ? systemImage : nil,
                tracking: 0.5
            )
            .help(Text(verbatim: title))
        } else {
            ThumbnailBadge(systemImage: systemImage)
                .help(Text(verbatim: title))
        }
    }
}
