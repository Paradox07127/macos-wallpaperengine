#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// Validates the 32-hex shape, probes Valve's `GetSupportedAPIList`, and stores the key in the Workshop container-file slot (this Mac only, no iCloud sync).
///
/// Kept for the surfaces that are genuinely modal — onboarding and the Browse
/// pane's "you need a key to do this" prompt. Settings enters the same key
/// inline through `WorkshopAPIKeySection`; both drive `SteamWebAPIKeyEntryModel`.
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
            innerContent
            footer
        }
        .frame(width: SteamSheetWidth.form)
        .task { await model.loadStoredKey() }
    }

    private var innerContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            header
            safetyCard
            entryCard
        }
        .padding(DesignTokens.Spacing.xl)
    }

    private var footer: some View {
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

    private var header: some View {
        SteamSheetHeader(
            icon: "key",
            title: "Set your Steam Web API key",
            info: "Loomscreen uses your own Steam account's Web API key to read Workshop metadata — free, but it needs Mobile Steam Guard and a non-limited Steam account. Calls go directly to Valve over HTTPS; the key is stored only on this Mac (no iCloud sync) and is never proxied through Loomscreen."
        )
    }

    /// Anti-phishing notice with the two external actions it talks about:
    /// the official generate page (primary) and the revoke page.
    private var safetyCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SteamWebAPIKeySafetyNotice()

            HStack(spacing: DesignTokens.Spacing.sm) {
                Button {
                    NSWorkspace.shared.open(SteamWebAPIKeyLinks.apiKey)
                } label: {
                    Label("Revoke on Steam", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer(minLength: 0)

                Button {
                    NSWorkspace.shared.open(SteamWebAPIKeyLinks.apiKey)
                } label: {
                    Label("Get a key", systemImage: "key.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Colors.Status.warning.opacity(0.06), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.md))
    }

    /// TOU consent, its reference links, and the gated key entry as one logical group.
    private var entryCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SteamWebAPIKeyTermsToggle(model: model)

            HStack(spacing: DesignTokens.Spacing.sm) {
                Button {
                    NSWorkspace.shared.open(SteamWebAPIKeyLinks.terms)
                } label: {
                    Label("Steam Web API TOU", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    NSWorkspace.shared.open(SteamWebAPIKeyLinks.limitedAccounts)
                } label: {
                    Label("About Limited Accounts", systemImage: "questionmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            SteamWebAPIKeyField(model: model, onSubmit: save)
            SteamWebAPIKeyValidationHint(model: model)
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .fill(DesignTokens.Colors.surfaceRaised.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .stroke(DesignTokens.Colors.separator.opacity(0.55), lineWidth: DesignTokens.Card.strokeWidth)
        )
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

// MARK: - Shared entry controls

/// Anti-phishing line. Same words wherever a key is pasted.
struct SteamWebAPIKeySafetyNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(DesignTokens.Colors.Status.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Official source only")
                    .font(DesignTokens.Typography.caption.weight(.bold))
                Text("Generate your key only at steamcommunity.com/dev/apikey. Never paste a key from a third-party site or installer.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SteamWebAPIKeyTermsToggle: View {
    @Bindable var model: SteamWebAPIKeyEntryModel

    var body: some View {
        Toggle(isOn: $model.hasReadTOU) {
            Text("I have read the Steam Web API Terms of Use.")
                .font(DesignTokens.Typography.body)
        }
        .toggleStyle(.checkbox)
    }
}

/// The masked field plus its reveal button. Disabled until the TOU box is ticked.
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
            .disabled(!model.hasReadTOU)
            .onChange(of: model.apiKey) { _, _ in model.keyChanged() }
            .onSubmit(onSubmit)

            Button {
                model.isShowingKey.toggle()
            } label: {
                Image(systemName: model.isShowingKey ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!model.hasReadTOU)
            .help(model.isShowingKey ? Text("Hide key") : Text("Show key"))
            .accessibilityLabel(model.isShowingKey ? Text("Hide key") : Text("Show key"))
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm)
                .strokeBorder(Color.primary.opacity(model.hasReadTOU ? 0.15 : 0.05), lineWidth: 0.5)
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
            Text("Paste your 32-character hexadecimal API key.")
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
