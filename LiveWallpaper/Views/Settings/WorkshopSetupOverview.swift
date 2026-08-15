#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// One of the three things Workshop needs before it is fully set up.
struct WorkshopSetupFacet: Identifiable {
    let anchor: SettingsSearchAnchor
    /// Short enough to sit in a three-column legend at settings width.
    let title: LocalizedStringKey
    let state: WorkshopStepState

    var id: String { anchor.rawValue }
}

/// The page-top status bar: one segmented track plus a legend naming each
/// segment.
///
/// This replaces the green seals that used to hang off each row's title. Three
/// checkmarks scattered down a scrolling page made the reader assemble the
/// summary themselves, and a page that is entirely green seals reads as
/// decoration rather than status. Clicking a legend entry scrolls to the
/// section it stands for.
struct WorkshopSetupOverview: View {
    let facets: [WorkshopSetupFacet]
    let onSelect: (SettingsSearchAnchor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
                Text("Workshop setup", bundle: .main)
                    .font(DesignTokens.Typography.bodyEmphasized)

                Spacer(minLength: 0)

                Text(verbatim: summary)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            track
            legend
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                .fill(DesignTokens.Colors.surfaceRaised.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                .stroke(DesignTokens.Colors.separator.opacity(0.55), lineWidth: 0.5)
        )
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .accessibilityElement(children: .contain)
    }

    private var track: some View {
        HStack(spacing: 2) {
            ForEach(facets) { facet in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(segmentTint(facet.state))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 6)
        .animation(.easeInOut(duration: 0.2), value: facets.map(\.state))
        .accessibilityHidden(true)
    }

    private var legend: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
            ForEach(facets) { facet in
                Button {
                    onSelect(facet.anchor)
                } label: {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Circle()
                            .fill(segmentTint(facet.state))
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)

                        Text(facet.title, bundle: .main)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The segments differ by colour alone; the state has to be
                // readable without seeing the colour, hover included.
                .help(Text(facet.state.statusText, bundle: .main))
                .accessibilityLabel(Text(facet.title, bundle: .main))
                .accessibilityValue(Text(facet.state.statusText, bundle: .main))
                .accessibilityHint(Text("Scroll to this section", bundle: .main))
            }
        }
    }

    /// `.notStarted` gets a filled-but-quiet segment rather than `WorkshopStepState`'s
    /// text tint: an empty-looking track segment reads as a rendering glitch.
    private func segmentTint(_ state: WorkshopStepState) -> Color {
        state == .notStarted ? Color.secondary.opacity(0.22) : state.tint
    }

    private var summary: String {
        let ready = facets.filter { $0.state == .ready }.count
        if ready == facets.count {
            return String(
                localized: "All set",
                comment: "Workshop setup status bar summary when all three setup steps are done."
            )
        }
        return String(
            localized: "\(ready) of \(facets.count) ready",
            comment: "Workshop setup status bar summary; first number is how many steps are done, second is the total."
        )
    }
}
#endif
