import LiveWallpaperCore
import SwiftUI

/// SCREENS.md S4's bottom-bar left column: title, the `·`-joined meta line, and whatever the
/// installed-item extras add under it.
struct ModalMetaLine: View {
    let title: String
    let metaParts: [String]
    let installed: InstalledItemExtras?

    /// The wiring omits parts it has no value for by leaving them empty, so joining blind would
    /// print bare separators. `nonisolated` because `View` conformance isolates the type to the
    /// main actor, and the closure inside would then trap on any other thread.
    nonisolated static func joined(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(DesignTokens.EditDesk.Typography.libraryModalTitle)
                .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
                .lineLimit(1)
            Text(verbatim: Self.joined(metaParts))
                .font(DesignTokens.EditDesk.Typography.metaMono)
                .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
                .lineLimit(1)
            if let installed {
                installedRow(installed)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func installedRow(_ installed: InstalledItemExtras) -> some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
            if installed.isWindowsOnly {
                ModalBadge(color: DesignTokens.EditDesk.Colors.warning) { Text("Windows Only") }
            }
            if !installed.inUseOnDisplayNames.isEmpty {
                Text("In use on \(installed.inUseOnDisplayNames.formatted(.list(type: .and)))")
                    .font(DesignTokens.EditDesk.Typography.badgeMono)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
            }
            updateStatus(installed.updateState)
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func updateStatus(_ state: InstalledItemExtras.UpdateState) -> some View {
        switch state {
        case .available:
            ModalBadge(color: DesignTokens.EditDesk.Colors.link) { Text("Needs Update") }
        case let .checking(progress):
            HStack(spacing: 6) {
                if let progress {
                    ModalProgressBar(fraction: progress)
                }
                Text("Checking for updates")
                    .font(DesignTokens.EditDesk.Typography.badgeMono)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
            }
        case let .failed(message):
            Text(verbatim: message)
                .font(DesignTokens.EditDesk.Typography.badgeMono)
                .foregroundStyle(DesignTokens.EditDesk.Colors.danger)
        case .unknown, .upToDate:
            EmptyView()
        }
    }
}

/// The status chips under the meta line; the fill is constant and only the ink carries the state.
private struct ModalBadge<Label: View>: View {
    let color: Color
    @ViewBuilder let label: () -> Label

    var body: some View {
        label()
            .font(DesignTokens.EditDesk.Typography.badgeMono)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.chip, style: .continuous)
                    .fill(DesignTokens.EditDesk.Colors.fillTertiaryButton)
            )
    }
}

private struct ModalProgressBar: View {
    let fraction: Double

    private static let width: CGFloat = 60
    private static let height: CGFloat = 3

    var body: some View {
        Capsule()
            .fill(DesignTokens.EditDesk.Colors.fillSecondaryButton)
            .frame(width: Self.width, height: Self.height)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(DesignTokens.EditDesk.Colors.link)
                    .frame(width: Self.width * min(max(fraction, 0), 1), height: Self.height)
            }
    }
}

/// SCREENS.md S4: the tag strip over the preview's bottom-left. Tags are Workshop glyphs
/// (`4K`, `anime`) and never translated.
struct ModalTagChips: View {
    let tags: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(verbatim: tag)
                    .font(DesignTokens.EditDesk.Typography.chip)
                    .foregroundStyle(DesignTokens.Colors.overlayForeground)
                    .padding(.horizontal, DesignTokens.EditDesk.Spacing.s8)
                    .frame(height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.chip, style: .continuous)
                            .fill(DesignTokens.EditDesk.Colors.tagChipFill)
                    )
            }
        }
    }
}

/// SCREENS.md S4's bottom-centred keyboard legend.
struct ModalShortcutHint: View {
    var body: some View {
        Text("ESC Close · ← → Adjacent wallpapers · Space Play/Pause")
            .font(DesignTokens.EditDesk.Typography.badgeMono)
            .foregroundStyle(DesignTokens.EditDesk.Colors.textTertiary)
    }
}
