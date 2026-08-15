#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// The Steam Web API key, entered in place.
///
/// Settings used to open the key sheet from here, which meant a modal window
/// on top of a settings window to fill in one field. Once a key is stored the
/// section is a single row; "Replace" expands the same fields the sheet shows,
/// in the grouped-form idiom the rest of Settings uses.
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
                subtitle: services.hasWebAPIKey
                    ? "Stored on this Mac only — never synced"
                    : "Your own free key — required to browse the Workshop online",
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
            .task(id: isEditing) {
                guard isEditing else { return }
                await model.loadStoredKey()
            }

            if isEditing {
                editor
            }
        } header: {
            SettingsSearchSectionHeader("Steam Web API key", anchor: .workshopSetup)
        }
    }

    @ViewBuilder
    private var summaryControl: some View {
        if isEditing {
            if services.hasWebAPIKey {
                Button("Cancel") { isEditing = false }
                    .adaptiveGlassButton(.regular, size: .small)
                    .help(Text("Keep the key you already have"))
            }
        } else if services.hasWebAPIKey {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Replace") { isEditing = true }
                    .adaptiveGlassButton(.regular, size: .small)
                    .help(Text("Set a new Steam Web API key"))
                Button("Forget", role: .destructive) {
                    Task { await model.forget() }
                }
                .adaptiveGlassButton(.regular, size: .small)
                .tint(DesignTokens.Colors.Status.danger)
                .help(Text(verbatim: WorkshopAPIKeyOwnershipInfo.forgetTooltip))
            }
        } else {
            Button("Set key") { isEditing = true }
                .adaptiveGlassButton(.prominent, size: .small)
                .help(Text("Paste your Steam Web API key"))
        }
    }

    @ViewBuilder
    private var editor: some View {
        SteamWebAPIKeySafetyNotice()

        HStack(spacing: DesignTokens.Spacing.sm) {
            SteamWebAPIKeyTermsToggle(model: model)
            Spacer(minLength: DesignTokens.Spacing.sm)
            // Links, not the sheet's buttons: the two references belong to the
            // sentence next to them, and a row of bordered buttons in a
            // grouped form reads as three more things to do.
            Button {
                NSWorkspace.shared.open(SteamWebAPIKeyLinks.terms)
            } label: {
                Text("Steam Web API TOU", bundle: .main)
            }
            .buttonStyle(.link)
            .fixedSize()

            Button {
                NSWorkspace.shared.open(SteamWebAPIKeyLinks.limitedAccounts)
            } label: {
                Text("About Limited Accounts", bundle: .main)
            }
            .buttonStyle(.link)
            .fixedSize()
        }

        SteamWebAPIKeyField(model: model, onSubmit: save)

        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            SteamWebAPIKeyValidationHint(model: model)

            Button {
                NSWorkspace.shared.open(SteamWebAPIKeyLinks.apiKey)
            } label: {
                Text("Get a key", bundle: .main)
            }
            .buttonStyle(.link)
            .fixedSize()

            Button("Save") { save() }
                .adaptiveGlassButton(.prominent, size: .small)
                .disabled(!model.canSave)
                .fixedSize()
        }
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
