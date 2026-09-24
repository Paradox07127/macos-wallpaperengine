import LiveWallpaperCore
import SwiftUI

struct SchemeCapturePopover: View {
    let screen: Screen
    @Binding var nameDraft: String

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.dismiss) private var dismiss

    @State private var store = SchemeStore.shared
    /// Nil = save a new scheme; otherwise the slot being overwritten.
    @State private var replacingID: UUID?
    @State private var pendingDestructive: PendingDestructive?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            header

            if !store.schemes.isEmpty {
                destinationPicker
            }

            if replacing == nil {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text("Name")
                        .font(DesignTokens.Typography.badge)
                        .foregroundStyle(.secondary)
                    TextField(defaultName, text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(DesignTokens.Typography.body)
                        .onSubmit(commit)
                }
            }

            Text(explanation)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                // In a sheet this is the only way out; ESC reaches it before the window behind.
                Button("Cancel") { dismiss() }
                    .adaptiveGlassButton(.regular, size: .small)
                    .keyboardShortcut(.cancelAction)
                Button(action: commit) {
                    replacing == nil
                        ? Label("Save", systemImage: "plus")
                        : Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                }
                .adaptiveGlassButton(.prominent, size: .small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .settingsPopoverChrome(width: 260)
        .confirmDestructive($pendingDestructive)
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

    /// One display can hold several schemes, so the choice is which slot to
    /// write, not whether this display already "has" one.
    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Save to")
                .font(DesignTokens.Typography.badge)
                .foregroundStyle(.secondary)
            Picker("Save to", selection: $replacingID) {
                Text("New Scheme").tag(UUID?.none)
                Divider()
                ForEach(store.schemes) { scheme in
                    Text(verbatim: scheme.name).tag(UUID?.some(scheme.id))
                }
            }
            .labelsHidden()
            .accessibilityLabel(Text("Save to"))
        }
    }

    private var replacing: ScreenScheme? {
        guard let replacingID else { return nil }
        return store.schemes.first { $0.id == replacingID }
    }

    private var explanation: LocalizedStringKey {
        replacing == nil
            ? "Saves this display's wallpaper, overlays, and all settings."
            : "Overwrites the chosen scheme with this display's wallpaper, overlays, and all settings."
    }

    private func commit() {
        if let replacing {
            pendingDestructive = PendingDestructive(
                .replaceScheme(schemeName: replacing.name, displayName: screen.name)
            ) {
                screenManager.recaptureScheme(replacing, from: screen)
                replacingID = nil
                dismiss()
            }
            return
        }
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        screenManager.captureScheme(from: screen, name: trimmed.isEmpty ? defaultName : trimmed)
        nameDraft = ""
        dismiss()
    }

    private var defaultName: String {
        "\(screen.name) · \(Date().formatted(date: .abbreviated, time: .omitted))"
    }
}
