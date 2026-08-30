#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// One of the things Workshop needs before it is fully set up.
struct WorkshopSetupFacet: Identifiable {
    /// Stable ForEach identity. Distinct from `anchor`: two facets may share a
    /// scroll target (SteamCMD and Steam sign-in both live in the connection
    /// section), and duplicate ids in a ForEach are undefined behavior.
    let key: String
    let anchor: SettingsSearchAnchor
    /// Short enough to sit in a four-column legend at settings width.
    let title: LocalizedStringKey
    let state: WorkshopStepState
    /// Kept out of the "N ready" tally. Counting an optional step as missing
    /// made a fully working setup read as incomplete forever.
    var isOptional = false

    var id: String { key }
}

/// The page-top status bar: one segmented track plus a legend naming each
/// segment.
/// Replaces the green seals that used to hang off each row's title — three checkmarks
/// scattered down a scrolling page made the reader assemble the summary themselves, and a
/// page that's entirely green seals reads as decoration, not status. Clicking a legend entry scrolls to the section it stands for.
struct WorkshopSetupOverview: View {
    let facets: [WorkshopSetupFacet]
    let onSelect: (SettingsSearchAnchor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
                Text("Workshop setup")
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
                RoundedRectangle(cornerRadius: DesignTokens.StatusBar.corner, style: .continuous)
                    .fill(segmentTint(facet))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: DesignTokens.StatusBar.height)
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
                            .fill(segmentTint(facet))
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)

                        Text(facet.title)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.secondary)
                            .marqueeOnHover(truncationMode: .tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The segments differ by colour alone; the state has to be
                // readable without seeing the colour, hover included.
                .help(Text(facet.state.statusText))
                .accessibilityLabel(Text(facet.title))
                .accessibilityValue(Text(facet.state.statusText))
                .accessibilityHint(Text("Scroll to this section"))
            }
        }
    }

    /// `.notStarted` gets a filled-but-quiet segment rather than `WorkshopStepState`'s
    /// text tint: an empty-looking track segment reads as a rendering glitch.
    private func segmentTint(_ facet: WorkshopSetupFacet) -> Color {
        facet.state == .notStarted ? Color.secondary.opacity(0.22) : facet.state.tint
    }

    private var summary: String {
        let required = facets.filter { !$0.isOptional }
        let ready = required.filter { $0.state == .ready }.count
        let base: String
        if ready == required.count {
            base = String(
                localized: "All set",
                bundle: .appLanguage, comment: "Workshop setup status bar summary when every required setup step is done."
            )
        } else {
            base = String(
                localized: "\(ready) of \(required.count) ready",
                bundle: .appLanguage, comment: "Workshop setup status bar summary; first number is how many steps are done, second is the total."
            )
        }
        // Named rather than counted: the reader's question about an optional
        // step is "do I need this", which a fraction cannot answer.
        guard facets.contains(where: { $0.isOptional && $0.state != .ready }) else { return base }
        return String(
            localized: "\(base) · API key optional",
            bundle: .appLanguage, comment: "Workshop setup status bar summary suffix; %@ is the required-steps summary."
        )
    }
}
#endif
