#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Vertical rather than one row: the inspector's minimum width is
/// `DesignTokens.Inspector.minWidth` (268pt, ~235pt usable) and CJK runs 1.5–2×.
struct ScenePresetBar: View {
    /// Already filtered to the descriptor's base wallpaper by the caller.
    let presets: [ScenePreset]
    let activePreset: ScenePreset?
    /// Visible settings the user has moved away from the applied preset (or from
    /// the scene's own defaults when no preset is applied).
    var changedCount: Int = 0
    var onSelect: (ScenePreset?) -> Void
    var onSave: (String) -> Void
    var onRename: (ScenePreset, String) -> Void
    var onDelete: (ScenePreset) -> Void

    @State private var editing: Editing?
    @State private var draftName = ""
    @State private var pendingDeletion: ScenePreset?
    @FocusState private var nameFieldIsFocused: Bool

    private enum Editing: Equatable {
        case saveAsNew
        case rename(ScenePreset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Label("Preset", systemImage: "square.stack.3d.up")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: DesignTokens.Spacing.xs)

                saveButton
                actionsMenu
            }

            presetPicker

            if changedCount > 0 {
                changedNote
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
            Button("Delete") {
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

    private var presetPicker: some View {
        Picker("", selection: selection) {
            Text("No preset").tag(String?.none)

            if !localPresets.isEmpty {
                Section {
                    ForEach(localPresets) { preset in
                        Text(verbatim: preset.name).tag(String?.some(preset.id))
                    }
                } header: {
                    Text("Saved by you")
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
                    Text("From the Workshop")
                }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(Text("Preset"))
    }

    /// Always additive: `+` saves the current values as a NEW preset and never
    /// overwrites; overwriting the applied one lives in the menu.
    private var saveButton: some View {
        GlassIconButton("plus", size: .small) { beginEditing(.saveAsNew) }
            .help(Text("Save the scene's current values as a new preset"))
            .accessibilityLabel(Text("Save as new preset"))
            .popover(isPresented: naming(matching: .isSaveAsNew), arrowEdge: .bottom) {
                namingPopover
            }
    }

    private enum NamingAnchor {
        case isSaveAsNew
        case isRename
    }

    /// Bound to `editing` so the popover and the naming state cannot disagree —
    /// dismissing by clicking away has to clear the draft too.
    private func naming(matching anchor: NamingAnchor) -> Binding<Bool> {
        Binding(
            get: {
                switch (editing, anchor) {
                case (.saveAsNew, .isSaveAsNew): true
                case (.rename, .isRename): true
                default: false
                }
            },
            set: { isPresented in
                if !isPresented {
                    cancelEditing()
                }
            }
        )
    }

    private var changedNote: some View {
        Label {
            if activePreset == nil {
                Text("\(changedCount) changed from the scene's defaults")
            } else {
                Text("\(changedCount) changed since this preset")
            }
        } icon: {
            Image(systemName: "pencil.circle.fill")
                .foregroundStyle(DesignTokens.Colors.Status.warning)
        }
        .font(DesignTokens.Typography.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actionsMenu: some View {
        Menu {
            // Only for a local preset with changes: `onSave` reuses the id of a same-named
            // local preset, so this call overwrites rather than adds.
            if let activePreset, activePreset.source == .local, changedCount > 0 {
                Button("Update “\(activePreset.name)”") { onSave(activePreset.name) }
                Divider()
            }

            Button("Save as New Preset…") { beginEditing(.saveAsNew) }

            if let activePreset {
                Divider()
                Button("Rename") { beginEditing(.rename(activePreset)) }
                Button("Delete preset", role: .destructive) { pendingDeletion = activePreset }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Preset actions"))
        .popover(isPresented: naming(matching: .isRename), arrowEdge: .bottom) {
            namingPopover
        }
    }

    private var namingPopover: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            TextField("Preset name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldIsFocused)
                .onSubmit(commit)
                .onExitCommand { cancelEditing() }

            if nameCollides {
                Text("A preset with this name already exists")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.Status.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                Spacer(minLength: 0)
                Button("Cancel") { cancelEditing() }
                Button(isRenaming ? "Rename" : "Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || nameCollides)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .frame(width: 260)
        // A TextField in a macOS popover often misses first responder on the
        // frame the popover opens on; the yield puts it after that pass.
        .onAppear {
            DispatchQueue.main.async { nameFieldIsFocused = true }
        }
    }

    /// `onSave` reuses the id of a same-named local preset, so without this guard
    /// typing an existing name silently replaces it.
    private var nameCollides: Bool {
        let name = trimmedName
        guard !name.isEmpty else { return false }
        return localPresets.contains { preset in
            preset.id != renamingPresetID
                && preset.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// Renaming a preset to the case-variant of its own name is not a collision.
    private var renamingPresetID: String? {
        if case let .rename(preset) = editing {
            return preset.id
        }
        return nil
    }

    private var isRenaming: Bool {
        if case .rename = editing {
            return true
        }
        return false
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
        // `nameCollides` gates here too, not just the Save button: Return reaches this
        // past the disabled button and would silently replace the preset.
        guard !name.isEmpty, !nameCollides, let editing else { return }
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
