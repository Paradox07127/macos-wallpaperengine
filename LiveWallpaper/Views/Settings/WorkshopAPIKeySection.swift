#if !LITE_BUILD

import LiveWallpaperCore
import SwiftUI

/// Edits keys inline using the shared `SteamWebAPIKeyEditor`.
struct WorkshopAPIKeySection: View {
    let services: WorkshopServices

    @State private var model: SteamWebAPIKeyEntryModel
    @State private var isEditing = false

    init(services: WorkshopServices) {
        self.services = services
        _model = State(initialValue: SteamWebAPIKeyEntryModel(services: services))
    }

    var body: some View {
        Section {
            SettingRow(
                icon: "key",
                iconColor: .orange,
                title: "Steam Web API key",
                subtitle: subtitle,
                info: "Optional. Adds ratings, authors, and faster search. Stored only on this Mac; requests go directly to Steam."
            ) {
                summaryControl
                    .fixedSize()
            }
            // Keep modifiers on the row so Form recognizes the Section.
            .animation(.easeInOut(duration: 0.18), value: isEditing)
            // Open the editor when no key is stored; collapse after saving.
            .onChange(of: services.hasWebAPIKey, initial: true) { _, hasKey in
                isEditing = !hasKey
            }

            if isEditing {
                editor
            }
        } header: {
            SettingsSearchSectionHeader("Steam Web API key (optional)", anchor: .workshopSetup)
        }
    }

    /// Only access and validation errors need a visible explanation.
    private var subtitle: LocalizedStringKey? {
        if services.apiKeyAccessDenied {
            return "Key access denied. Allow access in macOS or enter the key again."
        }

        if services.apiKeyRejected {
            return "Steam rejected the key. Enter a new key."
        }
        return nil
    }

    @ViewBuilder
    private var summaryControl: some View {
        if isEditing {
            if services.hasWebAPIKey {
                Button("Cancel") { isEditing = false }
            }
        } else if services.hasWebAPIKey {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Replace") { isEditing = true }
                Button("Forget", role: .destructive) {
                    Task { await model.forget() }
                }
                .tint(DesignTokens.Colors.Status.danger)
                .help(Text(verbatim: WorkshopAPIKeyOwnershipInfo.forgetTooltip))
            }
        } else {
            Button("Set key") { isEditing = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var editor: some View {
        SteamWebAPIKeyEditor(model: model, onSubmit: save)
            .padding(.vertical, DesignTokens.Spacing.xxs)
    }

    private func save() {
        Task {
            if await model.save() {
                isEditing = false
            }
        }
    }
}
#endif
