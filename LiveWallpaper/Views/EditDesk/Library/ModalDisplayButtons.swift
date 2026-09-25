import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// The detail modal's bottom row, centred: a caption, a button per display (the first prominent,
/// three at most, the rest under Other Displays), All Displays, then any buttons the caller adds.
@MainActor
struct ModalDisplayButtons: View {
    /// Pressing a display applies the wallpaper there, or downloads it first and applies it once it lands.
    enum Mode: Equatable { case apply, download }

    /// A display waiting for its download is pressed already; only another display can take the apply.
    static func isEnabled(_ target: ModalDisplayTarget, canApply: Bool, mode: Mode) -> Bool {
        canApply && !(mode == .download && target.isPreparing)
    }

    let targets: [ModalDisplayTarget]
    /// False greys every display button: a type this Mac cannot run, or a download that cannot start.
    let canApply: Bool
    var mode: Mode = .apply
    let applyTo: @MainActor (CGDirectDisplayID) -> Void
    /// nil hides All Displays; one display hides it too.
    var applyToAll: (@MainActor () -> Void)?
    /// After the displays, such as Save only.
    var extras: [ModalExtraButton] = []

    var body: some View {
        let split = ModalGeometry.applyButtons(targets: targets)
        HStack(spacing: DesignTokens.Spacing.sm) {
            caption
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
            if !extras.isEmpty {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    ForEach(extras) { extra in
                        Button(action: extra.action) { Text(verbatim: extra.title).lineLimit(1) }
                            .adaptiveGlassButton(.regular, size: .large)
                            .disabled(!extra.isEnabled)
                    }
                }
                .padding(.leading, DesignTokens.Spacing.md)
            }
        }
    }

    private var caption: Text {
        switch mode {
        case .apply:
            Text("Apply to")
        case .download:
            Text("Download and apply to", comment: "Workshop modal caption before the display buttons: pressing one downloads the wallpaper and applies it there.")
        }
    }

    private func applyButton(_ target: ModalDisplayTarget) -> some View {
        Button { applyTo(target.id) } label: {
            Label { Text(verbatim: target.name) } icon: { targetIcon(target) }
                .lineLimit(1).truncationMode(.middle)
        }
        .disabled(!Self.isEnabled(target, canApply: canApply, mode: mode))
        .help(applyHelp(target))
        .accessibilityLabel(applyLabel(target))
        .accessibilityValue(targetValue(target))
    }

    /// A fourth display and on: a pull-down beside the buttons rather than a longer row.
    private func overflowMenu(_ rest: [ModalDisplayTarget]) -> some View {
        Menu {
            ForEach(rest) { target in
                Button(target.name) { applyTo(target.id) }
                    .disabled(!Self.isEnabled(target, canApply: canApply, mode: mode))
            }
        } label: {
            Text("Other Displays", comment: "Wallpaper modal pull-down listing the displays past the first three buttons.")
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(!canApply)
    }

    private func applyLabel(_ target: ModalDisplayTarget) -> Text {
        switch mode {
        case .apply: Text("Apply to \(target.name)")
        case .download: Text("Download and apply to \(target.name)", comment: "Workshop modal display button read out by VoiceOver. Placeholder is the display name.")
        }
    }

    /// ⌘1…⌘9 are the only display shortcuts; a tenth display's button names none.
    private func applyHelp(_ target: ModalDisplayTarget) -> Text {
        if mode == .download, target.isPreparing {
            return Text("Will apply to \(target.name) when done")
        }
        guard target.shortcutIndex <= 9 else { return applyLabel(target) }
        switch mode {
        case .apply:
            return Text(
                "Apply to \(target.name) (⌘\(target.shortcutIndex))",
                comment: "Wallpaper modal apply button tooltip. Placeholders are a display name and its ⌘ shortcut number."
            )
        case .download:
            return Text(
                "Download and apply to \(target.name) (⌘\(target.shortcutIndex))",
                comment: "Workshop modal display button tooltip. Placeholders are a display name and its ⌘ shortcut number."
            )
        }
    }

    @ViewBuilder
    private func targetIcon(_ target: ModalDisplayTarget) -> some View {
        if target.isPreparing {
            ProgressView().controlSize(.small)
        } else if target.isApplied {
            Image(systemName: "checkmark")
        } else {
            Image(systemName: mode == .download ? "arrow.down.circle" : "display")
        }
    }

    private func targetValue(_ target: ModalDisplayTarget) -> Text {
        if target.isPreparing, mode == .download {
            Text("Will apply to \(target.name) when done")
        } else if target.isPreparing {
            Text("Preparing wallpaper…")
        } else if target.isApplied {
            Text("Applied")
        } else {
            Text("")
        }
    }
}

/// A button after the display buttons, such as Save only or Cancel download.
struct ModalExtraButton: Identifiable {
    let title: String
    var isEnabled = true
    let action: @MainActor () -> Void

    var id: String {
        title
    }
}
