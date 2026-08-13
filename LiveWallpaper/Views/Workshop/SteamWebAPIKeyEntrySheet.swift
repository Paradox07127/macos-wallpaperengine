#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// Validates the 32-hex shape, probes Valve's `GetSupportedAPIList`, and stores the key in the Workshop container-file slot (this Mac only, no iCloud sync).
struct SteamWebAPIKeyEntrySheet: View {
    let services: WorkshopServices
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var apiKey: String = ""
    @State private var hasReadTOU: Bool = false
    @State private var isShowingKey: Bool = false
    @State private var validation: Validation = .empty
    @State private var validationTask: Task<Void, Never>?
    @State private var validatedAPIKey: String?
    @State private var savingError: String?

    enum Validation: Equatable {
        case empty
        case wrongShape
        case validating
        case valid
        case error(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            innerContent
            footer
        }
        .frame(minWidth: 460, idealWidth: 460, maxWidth: 560)
        .onAppear {
            Task {
                if let stored = try? await services.keychain.loadWebAPIKey() {
                    apiKey = stored
                    hasReadTOU = true
                    triggerValidation()
                }
            }
        }
    }

    private enum SteamLinks {
        static let apiKey = URL(string: "https://steamcommunity.com/dev/apikey")!
        static let terms = URL(string: "https://steamcommunity.com/dev/apiterms")!
        static let limitedAccounts = URL(string: "https://help.steampowered.com/en/faqs/view/71D3-35C2-AD96-AA3A")!
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
            primaryDisabled: validation != .valid,
            primaryHelp: "Save key and close",
            cancelTitle: "Cancel",
            cancelAction: { dismiss() },
            cancelHelp: "Discard changes"
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
            Text("Set your Steam Web API key")
                .font(.headline)
            InfoTooltipButton(text: "Loomscreen uses your own Steam account's Web API key to read Workshop metadata — free, but it needs Mobile Steam Guard and a non-limited Steam account. Calls go directly to Valve over HTTPS; the key is stored only on this Mac (no iCloud sync) and is never proxied through Loomscreen.")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Anti-phishing notice with the two external actions it talks about:
    /// the official generate page (primary) and the revoke page.
    private var safetyCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(DesignTokens.Colors.Status.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Official source only")
                        .font(DesignTokens.Typography.caption.weight(.bold))
                    Text("Generate your key only at steamcommunity.com/dev/apikey. Never paste a key from a third-party site or installer.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                Button {
                    NSWorkspace.shared.open(SteamLinks.apiKey)
                } label: {
                    Label("Revoke on Steam", systemImage: "arrow.uturn.backward")
                }
                .adaptiveGlassButton(.regular, size: .small)

                Spacer(minLength: 0)

                Button {
                    NSWorkspace.shared.open(SteamLinks.apiKey)
                } label: {
                    Label("Get a key", systemImage: "key.fill")
                }
                .adaptiveGlassButton(.regular, size: .small)
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Colors.Status.warning.opacity(0.06), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.md))
    }

    /// TOU consent, its reference links, and the gated key entry as one logical group.
    private var entryCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Toggle(isOn: $hasReadTOU) {
                Text("I have read the Steam Web API Terms of Use.")
                    .font(DesignTokens.Typography.body)
            }
            .toggleStyle(.checkbox)

            HStack(spacing: DesignTokens.Spacing.sm) {
                Button {
                    NSWorkspace.shared.open(SteamLinks.terms)
                } label: {
                    Label("Steam Web API TOU", systemImage: "doc.text")
                }
                .adaptiveGlassButton(.regular, size: .small)

                Button {
                    NSWorkspace.shared.open(SteamLinks.limitedAccounts)
                } label: {
                    Label("About Limited Accounts", systemImage: "questionmark.circle")
                }
                .adaptiveGlassButton(.regular, size: .small)
            }

            keyField
            validationHint
            if let savingError {
                Text(savingError)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Colors.Status.danger)
            }
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

    private var keyField: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Group {
                if isShowingKey {
                    TextField("Paste your 32-character key", text: $apiKey)
                        .textFieldStyle(.plain)
                        .font(DesignTokens.Typography.code)
                        .textSelection(.enabled)
                } else {
                    SecureField("Paste your 32-character key", text: $apiKey)
                        .textFieldStyle(.plain)
                        .font(DesignTokens.Typography.code)
                }
            }
            .disabled(!hasReadTOU)
            .onChange(of: apiKey) { _, _ in triggerValidation() }
            .onSubmit(save)

            Button {
                isShowingKey.toggle()
            } label: {
                Image(systemName: isShowingKey ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!hasReadTOU)
            .help(isShowingKey ? Text("Hide key") : Text("Show key"))
            .accessibilityLabel(isShowingKey ? Text("Hide key") : Text("Show key"))
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm)
                .strokeBorder(Color.primary.opacity(hasReadTOU ? 0.15 : 0.05), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var validationHint: some View {
        switch validation {
        case .empty:
            Text("Paste your 32-character hexadecimal API key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .wrongShape:
            label(text: "Key must be 32 hexadecimal characters.", tint: DesignTokens.Colors.Status.danger, system: "xmark.circle.fill")
        case .validating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking with Steam…").font(.caption).foregroundStyle(.secondary)
            }
        case .valid:
            label(text: "Key validated.", tint: DesignTokens.Colors.Status.active, system: "checkmark.circle.fill")
        case .error(let message):
            label(text: message, tint: DesignTokens.Colors.Status.danger, system: "exclamationmark.triangle.fill")
        }
    }

    private func label(text: String, tint: Color, system: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: system).foregroundStyle(tint).imageScale(.small)
            Text(text).font(.caption).foregroundStyle(tint)
        }
    }

    // MARK: - Validation + save

    private func triggerValidation() {
        savingError = nil
        validatedAPIKey = nil
        validationTask?.cancel()
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validation = .empty
            return
        }
        guard isHex32(trimmed) else {
            validation = .wrongShape
            return
        }
        validation = .validating
        let service = services.queryService
        validationTask = Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                let ok = try await service.validateAPIKey(trimmed)
                if Task.isCancelled { return }
                guard apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
                if ok {
                    validation = .valid
                    validatedAPIKey = trimmed
                } else {
                    validation = .error("Steam rejected the key.")
                }
            } catch is CancellationError {
                return
            } catch let error as WorkshopQueryError {
                if Task.isCancelled { return }
                guard apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
                validation = .error(Self.message(for: error))
            } catch {
                if Task.isCancelled { return }
                guard apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
                validation = .error("Validation failed: \(error.localizedDescription)")
            }
        }
    }

    private func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validation == .valid, validatedAPIKey == trimmed else {
            triggerValidation()
            return
        }
        Task {
            do {
                try await services.keychain.setWebAPIKey(trimmed)
                await services.refreshAPIKeyStatus()
                onSaved()
                dismiss()
            } catch {
                savingError = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }

    private func isHex32(_ key: String) -> Bool {
        key.count == 32 && key.allSatisfy(\.isHexDigit)
    }

    private static func message(for error: WorkshopQueryError) -> String {
        switch error {
        case .unauthorized:
            return String(localized: "Steam rejected the key.", comment: "Steam Web API key validation error.")
        case .keyDisabled:
            return String(
                localized: "Your Steam API key was disabled by Valve.",
                comment: "Steam Web API key validation error."
            )
        case .rateLimited:
            return String(
                localized: "Steam is rate-limiting right now. Retry in a moment.",
                comment: "Steam Web API key validation error."
            )
        case .networkUnreachable:
            return String(
                localized: "Couldn't reach Steam. Check your connection.",
                comment: "Steam Web API key validation error."
            )
        case .timeout:
            return String(localized: "Steam took too long to respond.", comment: "Steam Web API key validation error.")
        default:
            return String(localized: "Validation failed.", comment: "Steam Web API key validation error.")
        }
    }
}
#endif
