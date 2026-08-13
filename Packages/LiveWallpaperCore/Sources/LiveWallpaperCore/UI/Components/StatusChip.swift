import SwiftUI

/// Small tinted status/tag capsule — the one recipe for footer badges, status
/// pills, and tag chips that are NOT floating over a thumbnail (those use
/// `ThumbnailBadge`). Same glass family and `.badge` type as `TypeBadge`, so
/// every chip-sized label in the app reads as one system.
///
/// Before this existed the recipe was written out longhand four ways
/// (fonts 11pt/12pt, Capsule/RoundedRect, glass/flat, stroke/none).
public struct StatusChip: View {
    private let title: Text
    private let tint: Color
    private let systemImage: String?
    private let interactive: Bool

    public init(
        _ title: LocalizedStringKey,
        tint: Color = .accentColor,
        systemImage: String? = nil,
        interactive: Bool = false
    ) {
        self.title = Text(title, bundle: .main)
        self.tint = tint
        self.systemImage = systemImage
        self.interactive = interactive
    }

    /// Verbatim variant for already-resolved runtime strings (statuses,
    /// author-supplied tags) that must not re-enter the localization catalog.
    public init(
        verbatim: String,
        tint: Color = .accentColor,
        systemImage: String? = nil,
        interactive: Bool = false
    ) {
        self.title = Text(verbatim: verbatim)
        self.tint = tint
        self.systemImage = systemImage
        self.interactive = interactive
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            title
                .font(DesignTokens.Typography.badge)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .adaptiveGlassSurface(.capsule, tint: tint, interactive: interactive)
        .fixedSize()
    }
}
