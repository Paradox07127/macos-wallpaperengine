#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct WorkshopSetupFacet: Identifiable {
    /// Multiple facets can share a scroll anchor.
    let key: String
    let anchor: SettingsSearchAnchor
    let title: LocalizedStringKey
    let state: WorkshopStepState
    /// nil = the state's own status text describes the step.
    var statusNote: LocalizedStringKey?
    /// Optional steps are excluded from the readiness total.
    var isOptional = false

    var id: String {
        key
    }
}

struct WorkshopSetupOverview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let facets: [WorkshopSetupFacet]
    let onSelect: (SettingsSearchAnchor) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
                    Text("Workshop setup")
                        .font(DesignTokens.Typography.sectionTitle)

                    Spacer(minLength: 0)

                    Text(verbatim: summary)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .lastTextBaseline, spacing: DesignTokens.Spacing.md) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        track
                        requiredLegend
                    }
                    ForEach(facets.filter(\.isOptional)) { facet in
                        legendItem(facet)
                            .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .accessibilityElement(children: .contain)
    }

    private static let segmentGap: CGFloat = 2

    private var track: some View {
        HStack(spacing: Self.segmentGap) {
            ForEach(facets.filter { !$0.isOptional }) { facet in
                RoundedRectangle(cornerRadius: DesignTokens.StatusBar.corner, style: .continuous)
                    .fill(segmentTint(facet))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: DesignTokens.StatusBar.height)
        .animation(DesignTokens.motion(reduceMotion, .easeInOut(duration: 0.2)), value: facets.map(\.state))
        .accessibilityHidden(true)
    }

    private var requiredLegend: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.segmentGap) {
            ForEach(facets.filter { !$0.isOptional }) { facet in
                legendItem(facet)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func legendItem(_ facet: WorkshopSetupFacet) -> some View {
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

                if facet.isOptional {
                    Text("Optional")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(facet.statusNote ?? facet.state.statusText))
        .accessibilityLabel(Text(facet.title))
        .accessibilityValue(Text(facet.statusNote ?? facet.state.statusText))
        .accessibilityHint(Text("Scroll to this section"))
    }

    /// Unstarted steps remain visible in the track.
    private func segmentTint(_ facet: WorkshopSetupFacet) -> Color {
        facet.state == .notStarted ? Color.secondary.opacity(0.22) : facet.state.tint
    }

    private var summary: String {
        let required = facets.filter { !$0.isOptional }
        let ready = required.filter { $0.state == .ready }.count
        if ready == required.count {
            return String(
                localized: "All set",
                bundle: .appLanguage, comment: "Workshop setup status bar summary when every required setup step is done."
            )
        }
        return String(
            localized: "\(ready) of \(required.count) ready",
            bundle: .appLanguage, comment: "Workshop setup status bar summary; first number is how many steps are done, second is the total."
        )
    }
}
#endif
