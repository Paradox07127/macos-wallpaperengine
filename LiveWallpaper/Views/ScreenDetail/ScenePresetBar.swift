#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Preset selection and management for the scene settings card.
///
/// Everything lives in one row plus an optional naming line, because this sits
/// in an inspector whose minimum width is `DesignTokens.Inspector.minWidth`
/// (268pt, ~235pt usable) and CJK copy runs 1.5-2× English.
struct ScenePresetBar: View {
    /// Already filtered to the descriptor's base wallpaper by the caller.
    let presets: [ScenePreset]
    let activePreset: ScenePreset?
    var onSelect: (ScenePreset?) -> Void
    var onSave: (String) -> Void
    var onRename: (ScenePreset, String) -> Void
    var onDelete: (ScenePreset) -> Void

    @State private var editing: Editing?
    @State private var draftName = ""
    @State private var pendingDeletion: ScenePreset?
    @FocusState private var nameFieldIsFocused: Bool

    /// Which naming operation the inline field is serving. Renaming and saving
    /// share one field; only the commit differs.
    private enum Editing: Equatable {
        case saveAsNew
        case rename(ScenePreset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Label("Preset", systemImage: "square.stack.3d.up")
                    .font(DesignTokens.Typography.bodyEmphasized)
                    .lineLimit(1)

                Spacer(minLength: DesignTokens.Spacing.sm)

                if presets.isEmpty {
                    Text("None saved", bundle: .main)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    presetPicker
                }

                actionsMenu
            }

            if editing != nil {
                namingField
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            Text("Delete this preset?"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDeletion { onDelete(pendingDeletion) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            if let pendingDeletion {
                Text("“\(pendingDeletion.name)” will be removed from every display using it. Your own changes on top of it are kept.")
            }
        }
    }

    /// Grouped so a Workshop preset someone downloaded is never mistaken for
    /// one of their own — deleting the two means different things.
    private var presetPicker: some View {
        Picker("", selection: selection) {
            Text("No preset").tag(String?.none)
            if !localPresets.isEmpty {
                Section {
                    ForEach(localPresets) { preset in
                        Text(verbatim: preset.name).tag(String?.some(preset.id))
                    }
                } header: {
                    Text("Saved by you", bundle: .main)
                }
            }
            if !workshopPresets.isEmpty {
                Section {
                    ForEach(workshopPresets) { preset in
                        Label {
                            Text(verbatim: preset.name)
                        } icon: {
                            Image(systemName: "arrow.down.circle")
                        }
                        .tag(String?.some(preset.id))
                    }
                } header: {
                    Text("From the Workshop", bundle: .main)
                }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        // Preset names are user-supplied and unbounded; same layout contract as
        // the combo property rows in the settings list.
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(minWidth: 96, alignment: .trailing)
        .layoutPriority(1)
        .accessibilityLabel(Text("Preset"))
    }

    private var actionsMenu: some View {
        Menu {
            Button("Save current values as a preset…") { beginEditing(.saveAsNew) }

            // Renaming a Workshop preset is allowed — it is a local label on a
            // local copy — but deleting one is worth separating from deleting
            // something the user authored, so both stay behind the divider.
            if let activePreset {
                Divider()
                Button("Rename…") { beginEditing(.rename(activePreset)) }
                Button("Delete preset", role: .destructive) { pendingDeletion = activePreset }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Preset actions"))
    }

    /// Its own line rather than sharing the row: at ~235pt a field flanked by
    /// two CJK buttons leaves under 100pt for the name itself.
    private var namingField: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            TextField("Preset name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($nameFieldIsFocused)
                .onSubmit(commit)
                .onExitCommand { cancelEditing() }

            HStack(spacing: DesignTokens.Spacing.xs) {
                Spacer(minLength: 0)
                Button("Cancel") { cancelEditing() }
                    .controlSize(.small)
                Button(editing == .saveAsNew ? "Save" : "Rename", action: commit)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .onAppear { nameFieldIsFocused = true }
    }

    // MARK: - Derived

    private var localPresets: [ScenePreset] {
        presets.filter { $0.source == .local }
    }

    private var workshopPresets: [ScenePreset] {
        presets.filter { $0.source != .local }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { activePreset?.id },
            set: { id in onSelect(presets.first { $0.id == id }) }
        )
    }

    private var trimmedName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Actions

    private func beginEditing(_ mode: Editing) {
        switch mode {
        case .saveAsNew:
            draftName = ""
        case .rename(let preset):
            draftName = preset.name
        }
        editing = mode
    }

    private func cancelEditing() {
        editing = nil
        draftName = ""
    }

    private func commit() {
        let name = trimmedName
        guard !name.isEmpty, let editing else { return }
        self.editing = nil
        draftName = ""
        switch editing {
        case .saveAsNew:
            onSave(name)
        case .rename(let preset):
            onRename(preset, name)
        }
    }
}
#endif
