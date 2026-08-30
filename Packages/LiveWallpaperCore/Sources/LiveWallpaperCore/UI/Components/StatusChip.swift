import SwiftUI

/// Small tinted status/tag capsule — the one recipe for footer badges, status pills, and tag chips
/// that are NOT floating over a thumbnail (those use `ThumbnailBadge`). Because it never floats, the
/// fill stays flat; it shares the `.badge` type with `TypeBadge`, so every chip-sized label reads as
/// one system. Before this existed the recipe was written out longhand four ways (fonts 11pt/12pt,
/// Capsule/RoundedRect, glass/flat, stroke/none).
public struct StatusChip: View {
    private let title: Text
    private let tint: Color
    private let systemImage: String?

    public init(
        _ title: LocalizedStringKey,
        tint: Color = .accentColor,
        systemImage: String? = nil
    ) {
        self.title = Text(title)
        self.tint = tint
        self.systemImage = systemImage
    }

    /// Pre-built `Text` variant for interpolated/composed labels the other
    /// inits can't express (e.g. "3× Active").
    public init(
        text: Text,
        tint: Color = .accentColor,
        systemImage: String? = nil
    ) {
        self.title = text
        self.tint = tint
        self.systemImage = systemImage
    }

    /// Verbatim variant for already-resolved runtime strings (statuses,
    /// author-supplied tags) that must not re-enter the localization catalog.
    public init(
        verbatim: String,
        tint: Color = .accentColor,
        systemImage: String? = nil
    ) {
        self.title = Text(verbatim: verbatim)
        self.tint = tint
        self.systemImage = systemImage
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
        .background(Capsule().fill(tint.opacity(0.12)))
        .fixedSize()
    }
}
