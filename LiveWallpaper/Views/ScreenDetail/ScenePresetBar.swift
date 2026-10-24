#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// One settings row: the menu selects and manages presets, the always-present subtitle reports changes so the height never varies.
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
        SettingRow(icon: "square.stack.3d.up", title: "Preset", subtitle: status) {
            presetMenu
        }
        // Menu items never appear on screen as views, so they can't queue their own names.
        .onChange(of: workshopPresets.map(\.name), initial: true) { _, names in
            WPEPropertyLabelTranslator.wallpaperNames.enqueue(labels: names)
        }
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

    private var presetMenu: some View {
        Menu {
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
                                Text(verbatim: preset.name.translatedWallpaperName)
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

            Section {
                if let activePreset, activePreset.source == .local, changedCount > 0 {
                    // `onSave` reuses the id of a same-named local preset, so this call overwrites rather than adds.
                    Button("Update “\(activePreset.name)”") {
                        onSave(activePreset.name)
                    }
                }

                Button("Save as New Preset") {
                    beginEditing(.saveAsNew)
                }

                if let activePreset {
                    Button("Rename") {
                        beginEditing(.rename(activePreset))
                    }
                    Button("Delete Preset", role: .destructive) {
                        pendingDeletion = activePreset
                    }
                }
            }
        } label: {
            menuLabel
        }
        .lineLimit(1)
        .truncationMode(.tail)
        // Without matching the title's priority the row hands the menu only its minimum width.
        .layoutPriority(1)
        .accessibilityLabel(Text("Preset"))
        .appLanguagePopover(isPresented: isNaming, arrowEdge: .bottom) {
            namingPopover
        }
    }

    private var status: LocalizedStringKey {
        if changedCount > 0 {
            return "\(changedCount) changed"
        }
        return activePreset == nil ? "Scene defaults" : "No changes"
    }

    @ViewBuilder
    private var menuLabel: some View {
        if let activePreset {
            // A local preset's name is the user's own text and is never translated.
            Text(verbatim: activePreset.source == .local ? activePreset.name : activePreset.name.translatedWallpaperName)
        } else {
            Text("No preset")
        }
    }

    /// Bound to `editing` so the popover and the naming state cannot disagree —
    /// dismissing by clicking away has to clear the draft too.
    private var isNaming: Binding<Bool> {
        Binding(
            get: {
                editing != nil
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
        case let .rename(preset):
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
        case let .rename(preset):
            onRename(preset, name)
        }
    }
}
#endif
