#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// Shares key validation and editing with Settings; the login keychain entry does not sync to iCloud.
struct SteamWebAPIKeyEntrySheet: View {
    let services: WorkshopServices
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: SteamWebAPIKeyEntryModel

    init(services: WorkshopServices, onSaved: @escaping () -> Void) {
        self.services = services
        self.onSaved = onSaved
        _model = State(initialValue: SteamWebAPIKeyEntryModel(services: services))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                SteamSheetHeader(
                    icon: "key",
                    title: "Steam Web API key",
                    info: "Optional. Adds ratings, authors, and faster search. Stored only on this Mac; requests go directly to Steam."
                )
                SteamWebAPIKeyEditor(model: model, showsSaveButton: false, onSubmit: save)
            }
            .padding(DesignTokens.Spacing.xl)

            SheetFooterBar(
                primaryTitle: "Save",
                primaryAction: { save() },
                primaryDisabled: !model.canSave,
                cancelTitle: "Cancel",
                cancelAction: { dismiss() }
            )
        }
        .frame(width: SteamSheetWidth.form)
    }

    private func save() {
        Task {
            if await model.save() {
                onSaved()
                dismiss()
            }
        }
    }
}

// MARK: - Shared editor

/// Shared key field, source guidance and validation status.
struct SteamWebAPIKeyEditor: View {
    @Bindable var model: SteamWebAPIKeyEntryModel
    /// Off inside a sheet, whose footer bar carries the primary action instead.
    var showsSaveButton = true
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Generate your key only at steamcommunity.com/dev/apikey. Never paste a key from a third-party site or installer.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DesignTokens.Spacing.sm) {
                SteamWebAPIKeyField(model: model, onSubmit: onSubmit)
                if showsSaveButton {
                    Button("Save") { onSubmit() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canSave)
                        .fixedSize()
                }
            }

            SteamWebAPIKeyValidationHint(model: model)

            HStack(spacing: DesignTokens.Spacing.md) {
                link("Get a key", SteamWebAPIKeyLinks.apiKey)
                link("Steam Web API Terms of Use", SteamWebAPIKeyLinks.terms)
                link("About Limited Accounts", SteamWebAPIKeyLinks.limitedAccounts)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func link(_ title: LocalizedStringKey, _ url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Text(title)
        }
        .buttonStyle(.link)
        .fixedSize()
    }
}

/// The masked field plus its reveal button.
/// An ordinary bordered field, not a `.plain` one dressed in a hand-drawn background: inside a
/// `Form` the plain style inherits the row's trailing alignment, pushing the text to the right
/// edge and leaving the placeholder sitting under it instead of clearing on the first keystroke.
struct SteamWebAPIKeyField: View {
    @Bindable var model: SteamWebAPIKeyEntryModel
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Group {
                if model.isShowingKey {
                    TextField("Paste your 32-character key", text: $model.apiKey)
                        .textSelection(.enabled)
                } else {
                    SecureField("Paste your 32-character key", text: $model.apiKey)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(DesignTokens.Typography.code)
            .multilineTextAlignment(.leading)
            .onChange(of: model.apiKey) { _, _ in model.keyChanged() }
            .onSubmit(onSubmit)

            Button {
                model.isShowingKey.toggle()
            } label: {
                Image(systemName: model.isShowingKey ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(model.isShowingKey ? Text("Hide key") : Text("Show key"))
            .accessibilityLabel(model.isShowingKey ? Text("Hide key") : Text("Show key"))
        }
    }
}

struct SteamWebAPIKeyValidationHint: View {
    let model: SteamWebAPIKeyEntryModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            hint
            if let savingError = model.savingError {
                Text(verbatim: savingError)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Colors.Status.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var hint: some View {
        switch model.validation {
        case .empty:
            Text("The key is stored in this Mac's keychain and never synced.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .wrongShape:
            label(text: Text("Key must be 32 hexadecimal characters."), tint: DesignTokens.Colors.Status.danger, system: "xmark.circle.fill")
        case .validating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking with Steam…").font(.caption).foregroundStyle(.secondary)
            }
        case .valid:
            label(text: Text("Key validated."), tint: DesignTokens.Colors.Status.active, system: "checkmark.circle.fill")
        case .error(let message):
            label(text: Text(verbatim: message), tint: DesignTokens.Colors.Status.danger, system: "exclamationmark.triangle.fill")
        }
    }

    private func label(text: Text, tint: Color, system: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: system).foregroundStyle(tint).imageScale(.small)
            text.font(.caption).foregroundStyle(tint)
        }
    }
}
#endif
