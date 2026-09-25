import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// The detail modal's bottom row, centred: "Apply to", a button per display (the first prominent,
/// three at most, the rest under Other Displays) and All Displays.
@MainActor
struct ModalDisplayButtons: View {
    let targets: [ModalDisplayTarget]
    /// False for a type this Mac cannot run: every button is off.
    let canApply: Bool
    let applyTo: @MainActor (CGDirectDisplayID) -> Void
    /// nil hides All Displays; one display hides it too.
    var applyToAll: (@MainActor () -> Void)?

    var body: some View {
        let split = ModalGeometry.applyButtons(targets: targets)
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text("Apply to")
                .font(DesignTokens.EditDesk.Typography.chip)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            if let primary = split.primary {
                applyButton(primary).adaptiveGlassButton(.prominent, size: .large)
            }
            ForEach(split.secondary) { target in
                applyButton(target).adaptiveGlassButton(.regular, size: .large)
            }
            if !split.overflow.isEmpty {
                overflowMenu(split.overflow)
            }
            if let applyToAll, targets.count > 1 {
                Button(action: applyToAll) {
                    Label { Text("All Displays") } icon: { Image(systemName: "rectangle.on.rectangle") }
                        .lineLimit(1)
                }
                .adaptiveGlassButton(.regular, size: .large)
                .disabled(!canApply)
            }
        }
    }

    private func applyButton(_ target: ModalDisplayTarget) -> some View {
        Button { applyTo(target.id) } label: {
            Label { Text(verbatim: target.name) } icon: { targetIcon(target) }
                .lineLimit(1).truncationMode(.middle)
        }
        .disabled(!canApply)
        .help(applyHelp(target))
        .accessibilityLabel(Text("Apply to \(target.name)"))
        .accessibilityValue(targetValue(target))
    }

    /// A fourth display and on: a pull-down beside the buttons rather than a longer row.
    private func overflowMenu(_ rest: [ModalDisplayTarget]) -> some View {
        Menu {
            ForEach(rest) { target in
                Button(target.name) { applyTo(target.id) }
            }
        } label: {
            Text("Other Displays", comment: "Wallpaper modal pull-down listing the displays past the first three buttons.")
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(!canApply)
    }

    /// ⌘1…⌘9 are the only display shortcuts; a tenth display's button names none.
    private func applyHelp(_ target: ModalDisplayTarget) -> Text {
        target.shortcutIndex <= 9
            ? Text(
                "Apply to \(target.name) (⌘\(target.shortcutIndex))",
                comment: "Wallpaper modal apply button tooltip. Placeholders are a display name and its ⌘ shortcut number."
            )
            : Text("Apply to \(target.name)")
    }

    @ViewBuilder
    private func targetIcon(_ target: ModalDisplayTarget) -> some View {
        if target.isPreparing {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: target.isApplied ? "checkmark" : "display")
        }
    }

    private func targetValue(_ target: ModalDisplayTarget) -> Text {
        if target.isPreparing {
            Text("Preparing wallpaper…")
        } else if target.isApplied {
            Text("Applied")
        } else {
            Text("")
        }
    }
}
