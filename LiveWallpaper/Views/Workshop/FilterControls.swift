#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

enum WorkshopFilterLayout {
    /// Wide enough for category names at the shared section-title size.
    static let labelWidth: CGFloat = 120
}

struct WorkshopFiltersToggle: View {
    @Binding var isExpanded: Bool
    let activeFilterCount: Int
    var isDisabled: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The plate holding the drawer animates this declaratively — an imperative
        // `withAnimation` here would run a second, competing curve on the same pass.
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "line.3.horizontal.decrease")
                Text("Filters")
                if activeFilterCount > 0 {
                    Text(verbatim: "\(activeFilterCount)")
                        .font(DesignTokens.Typography.badge)
                        .foregroundStyle(DesignTokens.Colors.onAccentFill)
                        // No vertical padding: any would stand the badge taller than the 13pt label and the button past `controlHeight`.
                        .padding(.horizontal, 5)
                        .background(Color.accentColor, in: Capsule())
                }
                Image(systemName: "chevron.down")
                    .font(DesignTokens.Typography.badge)
                    .foregroundStyle(.secondary)
                    // Rotate rather than swap glyphs: swapping pops, and the
                    // chevron is the only thing that moves when nothing is open.
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(DesignTokens.motion(reduceMotion, .smooth(duration: 0.24)), value: isExpanded)
            }
            .font(DesignTokens.EditDesk.Typography.body)
        }
        .adaptiveGlassButton(.regular, shape: .capsule, size: .large)
        .disabled(isDisabled)
        .help(Text("Filter options"))
        .accessibilityLabel(Text("Filters"))
        .accessibilityValue(activeFilterCount > 0
            ? Text("\(activeFilterCount) active")
            : Text("None active"))
    }
}

struct WorkshopLikedToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        GlassIconButton(isOn ? "heart.fill" : "heart", tint: isOn ? DesignTokens.Colors.like : nil) {
            isOn.toggle()
        }
        .help(Text("Show only wallpapers you liked"))
        .accessibilityLabel(Text("Liked"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Top-aligned so the label stays put when chips wrap onto several lines.
struct WorkshopFilterRow<Content: View>: View {
    private let title: LocalizedStringKey
    private let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Text(title)
                .font(DesignTokens.Typography.sectionTitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: WorkshopFilterLayout.labelWidth, alignment: .leading)
                // Centred on the first line of chips.
                .frame(minHeight: DesignTokens.LibraryFilterBar.controlHeight)
            content
        }
    }
}

enum WorkshopFilterMath {
    /// A category narrows results only when a non-empty proper subset is
    /// selected (selecting all — or none — means "no filter").
    static func isNarrowing<T>(_ selected: Set<T>, total: Int) -> Bool {
        !selected.isEmpty && selected.count < total
    }
}
#endif
