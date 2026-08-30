#if !LITE_BUILD

import LiveWallpaperCore
import SwiftUI

/// The Steam Web API key, entered in place.
///
/// Settings used to open the key sheet from here, which meant a modal window
/// on top of a settings window to fill in one field. Once a key is stored the
/// section is a single row; "Replace" expands `SteamWebAPIKeyEditor` — the
/// same view the sheet wraps, so the two cannot lay one field out two ways.
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
                title: "Steam Web API key (optional)",
                subtitle: subtitle,
                info: "The key belongs to your own Steam account, not Loomscreen. Calls go directly to Valve over HTTPS, and the key is stored only on this Mac (no iCloud sync). Get one free at steamcommunity.com/dev/apikey."
            ) {
                summaryControl
                    .fixedSize()
            }
            // Modifiers ride the row rather than the `Section`: a modified
            // Section is no longer a Section to `Form`, and the group loses
            // its header and separators.
            .animation(.easeInOut(duration: 0.18), value: isEditing)
            // The key is only unset for as long as it takes to store one, so
            // opening the fields on that transition is the whole interaction —
            // and closing them when a key lands is what keeps the steady state
            // down to one row.
            .onChange(of: services.hasWebAPIKey, initial: true) { _, hasKey in
                isEditing = !hasKey
            }

            if isEditing {
                editor
            }
        } header: {
            SettingsSearchSectionHeader("Steam Web API key", anchor: .workshopSetup)
        }
    }

    /// The denial line comes first: the key is still stored, so saying
    /// "Stored on this Mac" while every request fails reads as a lie, and
    /// saying "not set" would send the user to Steam for a key they have.
    private var subtitle: LocalizedStringKey {
        if services.apiKeyAccessDenied {
            return "macOS wouldn't unlock the stored key — allow access when it asks, or paste the key again"
        }
        return services.hasWebAPIKey
            ? "Stored on this Mac only — never synced"
            : "Optional — adds ratings, authors and faster search"
    }

    @ViewBuilder
    private var summaryControl: some View {
        if isEditing {
            if services.hasWebAPIKey {
                Button("Cancel") { isEditing = false }
                    .help(Text("Keep the key you already have"))
            }
        } else if services.hasWebAPIKey {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Replace") { isEditing = true }
                    .help(Text("Set a new Steam Web API key"))
                Button("Forget", role: .destructive) {
                    Task { await model.forget() }
                }
                .tint(DesignTokens.Colors.Status.danger)
                .help(Text(verbatim: WorkshopAPIKeyOwnershipInfo.forgetTooltip))
            }
        } else {
            Button("Set key") { isEditing = true }
                .buttonStyle(.borderedProminent)
                .help(Text("Paste your Steam Web API key"))
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
