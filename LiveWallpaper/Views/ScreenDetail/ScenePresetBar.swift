#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Preset selection and management for the scene settings card.
///
/// A preset is not one more setting — it is a saved state of every setting below
/// it. It used to render as a single row that looked like a peer of those
/// settings: a label, a right-aligned "None saved" where a value belongs, and an
/// ellipsis that was the *only* way to do anything. On a scene with no presets —
/// which is every scene until the user makes one — that row offered a dead label
/// and a hidden menu.
///
/// Now it is a small block: a heading line carrying the label, a `+` that always
/// saves the current values as a NEW preset, and the menu holding the rare and
/// destructive ones; then a full-width picker; then a status line saying how far
/// the current values have drifted. The drift was previously legible only as a
/// pencil badge on each changed row.
///
/// Naming happens in a popover anchored to whichever control started it. Inline,
/// it grew the block and pushed all 20-35 property rows down the column.
///
/// Still vertical rather than one row: this sits in an inspector whose minimum
/// width is `DesignTokens.Inspector.minWidth` (268pt, ~235pt usable), and CJK
/// copy runs 1.5–2× English.
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

    /// Which naming operation the inline field is serving. Renaming and saving
    /// share one field; only the commit differs.
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
            // Deliberate delete via the menu item above — the confirmation button
            // doesn't take the destructive style (HIG, Alerts).
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

    /// Grouped so a Workshop preset someone downloaded is never mistaken for
    /// one of their own — deleting the two means different things.
    private var presetPicker: some View {
        Picker("", selection: selection) {
            Text("No preset").tag(String?.none)
            // With nothing saved this is the only entry, and the picker reads as
            // "no presets exist" rather than as a dead control.

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
        // Preset names are user-supplied and unbounded; same layout contract as
        // the combo property rows in the settings list.
        .lineLimit(1)
        .truncationMode(.tail)
        // Full width, not squeezed to the right of a label: this is the control
        // the whole block is about.
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(Text("Preset"))
    }

    /// Always visible, and always additive: `+` saves the current values as a
    /// NEW preset, it never overwrites. Overwriting the applied one is a separate
    /// intent and lives in the menu, where it can be gated and named after its
    /// target. Icon-only because the header row also carries a label and a menu,
    /// and a worded button here would be the first thing to truncate in Japanese.
    ///
    /// Naming happens in a popover rather than an inline row: this block sits
    /// above 20-35 property rows, and growing it pushed every one of them down.
    private var saveButton: some View {
        GlassIconButton("plus", size: .small) { beginEditing(.saveAsNew) }
            .help(Text("Save the scene's current values as a new preset"))
            .accessibilityLabel(Text("Save as new preset"))
            .popover(isPresented: naming(matching: .isSaveAsNew), arrowEdge: .bottom) {
                namingPopover
            }
    }

    /// One popover view, two anchors. Rename is started from the ellipsis menu,
    /// so its sheet has to grow from there — anchored to `+` instead, an action
    /// chosen in one control sprouted out of another, and VoiceOver announced it
    /// against "Save as new preset".
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

    /// The card's own reset accessory already offers the action; this says what
    /// there is to reset, which nothing did before — the per-row pencil badges
    /// only showed up next to settings the user had scrolled to.
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
            // The other save intent, and the reason `+` can stay purely additive.
            // Only for a preset the user made — a Workshop one is someone else's
            // snapshot, and saving over its name would silently fork it — and
            // only when there is something to fold in. `onSave` reuses the id of
            // a same-named local preset, so this overwrites rather than adds.
            if let activePreset, activePreset.source == .local, changedCount > 0 {
                Button("Update “\(activePreset.name)”") { onSave(activePreset.name) }
                Divider()
            }

            Button("Save as New Preset…") { beginEditing(.saveAsNew) }

            // Renaming a Workshop preset is allowed — it is a local label on a
            // local copy — but deleting one is worth separating from deleting
            // something the user authored, so both stay behind the divider.
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

    /// The popover has room the inspector column does not: the field gets a
    /// sensible width and the two buttons sit beside each other without the
    /// ~235pt squeeze that forced them onto their own line inline.
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

    /// `onSave` reuses the id of a same-named local preset, which is exactly what
    /// "Update" wants and exactly what `+` must not do: typing an existing name
    /// here would silently replace that preset. Blocking the collision is what
    /// makes "always additive" true rather than merely claimed.
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
        // `nameCollides` also gates here, not just the Save button: Return in the
        // field reached this straight past the disabled button, and `onSave`
        // reuses a same-named preset's id — so it silently replaced it.
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
