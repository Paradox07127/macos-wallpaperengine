#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// One fixed-height row: the pill menu selects and manages presets, the icon button saves a new one. Nothing here may change height with state.
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
        HStack(spacing: DesignTokens.Spacing.xs) {
            presetMenu
                .frame(maxWidth: .infinity, alignment: .leading)

            changedDot

            saveButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            Text("Delete this preset?"),
            isPresented: Binding(
                get: {
                    pendingDeletion != nil
                },
                set: { isPresented in
                    if !isPresented {
                        pendingDeletion = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete") {
                if let pendingDeletion {
                    onDelete(pendingDeletion)
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            if let pendingDeletion {
                Text("“\(pendingDeletion.name)” will be removed from every display using it. Your own changes on top of it are kept.")
            }
        }
    }

    @ViewBuilder
    private var presetMenu: some View {
        let menu = Menu {
            Picker(selection: selection) {
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
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)

            Divider()

            Button("Save as New Preset…") {
                beginEditing(.saveAsNew)
            }

            if let activePreset {
                Divider()
                // Only for a local preset with changes: `onSave` reuses the id of a same-named
                // local preset, so this call overwrites rather than adds.
                if activePreset.source == .local, changedCount > 0 {
                    Button("Update “\(activePreset.name)”") {
                        onSave(activePreset.name)
                    }
                }
                Button("Rename") {
                    beginEditing(.rename(activePreset))
                }
                Button("Delete preset", role: .destructive) {
                    pendingDeletion = activePreset
                }
            }
        } label: {
            menuLabel
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .accessibilityLabel(Text("Preset"))
        .accessibilityValue(changedHelp)
        .popover(isPresented: naming(matching: .isRename), arrowEdge: .bottom) {
            namingPopover
        }

        // One view path: a branch per state would re-identify the menu and drop an open naming popover.
        menu.help(changedHelp)
    }

    private var changedHelp: Text {
        guard changedCount > 0 else {
            return Text(verbatim: "")
        }
        if activePreset == nil {
            return Text("\(changedCount) changed from the scene's defaults")
        }
        return Text("\(changedCount) changed since this preset")
    }

    /// A macOS `Menu` flattens its label to one image and one text: anything else
    /// (a background, a dot, a second glyph) is dropped silently. The native
    /// pull-down button supplies the border and the chevron; the dot lives outside.
    private var menuLabel: some View {
        Label {
            if let activePreset {
                Text(verbatim: activePreset.name)
            } else {
                Text("No preset")
            }
        } icon: {
            Image(systemName: "square.stack.3d.up")
        }
    }

    /// Width is reserved when unchanged so the row never shifts.
    private var changedDot: some View {
        Circle()
            .fill(DesignTokens.Colors.Status.warning)
            .frame(width: 6, height: 6)
            .opacity(changedCount > 0 ? 1 : 0)
            .accessibilityHidden(true)
    }

    /// Always additive: this saves the current values as a NEW preset and never
    /// overwrites; overwriting the applied one lives in the menu.
    private var saveButton: some View {
        GlassIconButton("square.and.arrow.down", size: .small) {
            beginEditing(.saveAsNew)
        }
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

    private var namingPopover: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            TextField("Preset name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldIsFocused)
                .onSubmit(commit)
                .onExitCommand {
                    cancelEditing()
                }

            if nameCollides {
                Text("A preset with this name already exists")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.Status.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                Spacer(minLength: 0)
                Button("Cancel") {
                    cancelEditing()
                }
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
            DispatchQueue.main.async {
                nameFieldIsFocused = true
            }
        }
    }

    /// `onSave` reuses the id of a same-named local preset, so without this guard
    /// typing an existing name silently replaces it.
    private var nameCollides: Bool {
        let name = trimmedName
        guard !name.isEmpty else {
            return false
        }
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
            get: {
                activePreset?.id
            },
            set: { id in
                onSelect(presets.first { $0.id == id })
            }
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
        guard !name.isEmpty, !nameCollides, let editing else {
            return
        }
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
