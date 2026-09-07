import LiveWallpaperCore
import SwiftUI

/// The parent owns the name draft so it survives popover dismissal.
struct SchemeCapturePopover: View {
    let screen: Screen
    @Binding var nameDraft: String

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            header

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text("Name")
                    .font(DesignTokens.Typography.badge)
                    .foregroundStyle(.secondary)
                TextField(defaultName, text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.Typography.body)
                    .onSubmit(commit)
            }

            Text("Saves this display's wallpaper, overlays, and all settings.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(action: commit) {
                    Label("Save", systemImage: "plus")
                }
                .adaptiveGlassButton(.prominent, size: .small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .settingsPopoverChrome(width: 260)
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "square.stack.3d.up")
                .font(DesignTokens.Typography.bodyEmphasized)
                .foregroundStyle(.tint)
            Text("Save as Scheme")
                .font(DesignTokens.Typography.bodyEmphasized)
            Spacer()
        }
    }

    private func commit() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        screenManager.captureScheme(from: screen, name: trimmed.isEmpty ? defaultName : trimmed)
        nameDraft = ""
        dismiss()
    }

    private var defaultName: String {
        "\(screen.name) · \(Date().formatted(date: .abbreviated, time: .omitted))"
    }
}
