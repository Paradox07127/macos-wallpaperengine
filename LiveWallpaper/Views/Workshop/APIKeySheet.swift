#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// Validates the 32-hex shape, probes Valve's `GetSupportedAPIList`, and stores
/// the key in this Mac's login keychain (never synced to iCloud).
///
/// Kept for the surfaces that are genuinely modal — onboarding and the Browse
/// pane's "you need a key to do this" prompt. Settings shows the same
/// `SteamWebAPIKeyEditor` inline; the sheet is only a title and a Done button
/// around it, so the two cannot lay the same field out differently.
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
                    title: "Set your Steam Web API key",
                    subtitle: "Browsing works without one. A key adds ratings, authors and faster search."
                )
                // No inline Save here: the sheet's footer already owns the
                // primary action, and two Save buttons stacked in one dialog
                // is a question about which one is real.
                SteamWebAPIKeyEditor(model: model, showsSaveButton: false, onSubmit: save)
            }
            .padding(DesignTokens.Spacing.xl)

            SheetFooterBar(
                primaryTitle: "Save",
                primaryAction: { save() },
                primaryDisabled: !model.canSave,
                primaryHelp: "Save key and close",
                cancelTitle: "Cancel",
                cancelAction: { dismiss() },
                cancelHelp: "Discard changes"
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

/// The key field and everything that has to sit next to it.
///
/// This was two cards with tinted fills and four bordered buttons, laid out
/// twice. In a settings form the cards read as panels inside panels, and four
/// bordered buttons read as four more chores; the sentences they carried are
/// the part that matters, so they stayed and the chrome went.
struct SteamWebAPIKeyEditor: View {
    @Bindable var model: SteamWebAPIKeyEntryModel
    /// Off inside a sheet, whose footer bar carries the primary action instead.
    var showsSaveButton = true
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            // Kept as plain text rather than a warning panel: it is a standing
            // instruction about where keys come from, not an alert about
            // something that just happened.
            Text("Generate your key only at steamcommunity.com/dev/apikey. Never paste a key from a third-party site or installer.", bundle: .main)
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
            Text(title, bundle: .main)
        }
        .buttonStyle(.link)
        .fixedSize()
    }
}

/// The masked field plus its reveal button.
struct SteamWebAPIKeyField: View {
    @Bindable var model: SteamWebAPIKeyEntryModel
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Group {
                if model.isShowingKey {
                    TextField("Paste your 32-character key", text: $model.apiKey)
                        .textFieldStyle(.plain)
                        .font(DesignTokens.Typography.code)
                        .textSelection(.enabled)
                } else {
                    SecureField("Paste your 32-character key", text: $model.apiKey)
                        .textFieldStyle(.plain)
                        .font(DesignTokens.Typography.code)
                }
            }
            .onChange(of: model.apiKey) { _, _ in model.keyChanged() }
            .onSubmit(onSubmit)

            Button {
                model.isShowingKey.toggle()
            } label: {
                Image(systemName: model.isShowingKey ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(model.isShowingKey ? Text("Hide key") : Text("Show key"))
            .accessibilityLabel(model.isShowingKey ? Text("Hide key") : Text("Show key"))
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
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
