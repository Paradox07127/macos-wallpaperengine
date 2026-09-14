import SwiftUI

public enum CardBadgeSettings {
    public static let showsRating = "loomscreen.cards.badge.rating.v1"
    public static let showsType = "loomscreen.cards.badge.type.v1"
    public static let showsResolution = "loomscreen.cards.badge.resolution.v1"
    public static let showsInLibrary = "loomscreen.cards.badge.inLibrary.v1"
    public static let showsUpdate = "loomscreen.cards.badge.update.v1"
    public static let showsInUse = "loomscreen.cards.badge.inUse.v1"
    public static let typeStyle = "loomscreen.cards.badge.typeStyle.v1"
}

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

public enum CardTypeBadgeStyle: String, CaseIterable, Identifiable, Sendable {
    case icon
    case text
    case iconAndText

    public var id: String { rawValue }

    public var showsIcon: Bool { self != .text }
    public var showsText: Bool { self != .icon }
}

/// The badge is `accessibilityHidden`, so the hosting card MUST restate the type in
/// its own accessibility label or `.icon` leaves VoiceOver nothing to read.
public struct ThumbnailTypeBadge: View {
    private let systemImage: String
    private let title: String
    private let style: CardTypeBadgeStyle

    public init(systemImage: String, title: String, style: CardTypeBadgeStyle) {
        self.systemImage = systemImage
        self.title = title
        self.style = style
    }

    /// `.icon` takes the glyph-only initializer; passing an empty string would still
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
