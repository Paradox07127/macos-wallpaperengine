#if !LITE_BUILD
import LiveWallpaperCore
import Observation
import SwiftUI

/// Edits project properties stored directly on a WPE scene descriptor.
struct WPESceneCustomSettingsCard: View {
    private typealias ValueLogic = PropertyValueLogic

    var screen: Screen
    var schema: WallpaperEngineProjectPropertySchema
    @Binding var descriptor: SceneDescriptor

    @Environment(ScreenManager.self) private var screenManager
    @AppStorage("Inspector.WPESceneCustomSettingsExpanded") private var isExpanded = true
    /// Card-local edit state. Keeping high-frequency slider/text/color changes
    /// out of `DraftState` prevents the whole inspector (and its
    /// hosted preview) from being invalidated on every gesture sample.
    @State private var editor = Editor()
    @State private var commitTask: Task<Void, Never>?
    @State private var presetLibrary: [String: ScenePreset] = [:]

    var body: some View {
        GroupBox {
            CollapsibleSection(
                title: "Scene Custom Settings",
                systemImage: "slider.horizontal.3",
                isExpanded: $isExpanded,
                trailingAccessory: {
                    resetAccessory(hasIncrement: editor.hasVisibleIncrement)
                }
            ) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    presetWell

                    if let presentation = editor.presentation {
                        settingsList(rows: editor.rows, values: presentation.values)
                    }
                }
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
        .onAppear {
            presetLibrary = SettingsManager.shared.loadGlobalSettings().scenePresets
            synchronizeEditor(force: true)
            refreshPresetDerivedState()
        }
        // A Workshop download can register a preset while this card is open;
        // without this the list stays as it was when the inspector appeared.
        .onReceive(NotificationCenter.default.publisher(for: .scenePresetLibraryDidChange)) { _ in
            reloadPresetLibrary()
        }
        .onChange(of: sceneIdentity) { oldIdentity, newIdentity in
            // A coalesced commit scheduled for the previous display would fire
            // after the binding has moved, writing that display's increment onto
            // this one. Dropping the last ≤180ms of edits is the safe direction;
            // letting them land on the wrong display is not.
            if oldIdentity.screenID != newIdentity.screenID {
                commitTask?.cancel()
                commitTask = nil
            }
            synchronizeEditor(force: true)
            refreshPresetDerivedState()
        }
        .onChange(of: descriptor.presetID) { _, _ in
            synchronizeEditor(force: true)
            refreshPresetDerivedState()
        }
        // Same id, different values: a restore can swap the snapshot without
        // touching the pointer, and nothing else re-reads it.
        .onChange(of: descriptor.presetSnapshot) { _, _ in
            synchronizeEditor(force: true)
            refreshPresetDerivedState()
        }
        .onChange(of: descriptor.propertyOverrides) { _, overrides in
            if overrides != editor.overrides, commitTask == nil {
                synchronizeEditor(force: true)
            }
            // After the sync, so the badges describe the increment now shown.
            refreshPresetDerivedState()
        }
        .onDisappear { flushPendingCommit() }
    }

    /// A sunken well inside the card's raised surface. The preset block governs
    /// every setting listed under it rather than sitting among them, and with no
    /// boundary it read as one more row — the settings list even had a negative
    /// top inset pulling the two together.
    private var presetWell: some View {
        ScenePresetBar(
            presets: availablePresets,
            activePreset: activePreset,
            changedCount: changedSettingCount,
            onSelect: { applyPreset($0) },
            onSave: { name in Task { @MainActor in await saveAsPreset(name: name) } },
            onRename: { renamePreset($0, to: $1) },
            onDelete: { deletePreset($0) }
        )
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .fill(DesignTokens.Colors.surfaceSunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .strokeBorder(
                    DesignTokens.Colors.separator.opacity(DesignTokens.Opacity.quietStroke),
                    lineWidth: DesignTokens.Card.strokeWidth
                )
        )
    }

    // MARK: - Presets

    private var activePreset: ScenePreset? {
        descriptor.resolvedPreset(in: presetLibrary)
    }

    /// Cached: sorting with `localizedStandardCompare` per body pass would run
    /// ICU collation on every slider sample.
    @State private var availablePresets: [ScenePreset] = []
    /// Keys the user moved away from the applied preset. Cached for the same
    /// reason — `badge(for:)` runs once per row per body pass.
    @State private var divergingKeys: Set<String> = []

    /// Diverging keys when a preset is applied; otherwise the increment over the
    /// scene's own defaults. Both are "what you changed", counted the same way
    /// the pencil badges mark rows, and restricted to settings actually on screen
    /// so a hidden conditional row can't inflate it.
    private var changedSettingCount: Int {
        guard let presentation = editor.presentation else { return 0 }
        let keys = activePreset == nil ? Set(editor.overrides.keys) : divergingKeys
        return keys.count { presentation.visibleKeys.contains($0) }
    }

    private func refreshPresetDerivedState() {
        availablePresets = presetLibrary.values
            .filter { $0.baseWorkshopID == descriptor.workshopID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let activePreset {
            divergingKeys = Set(
                ScenePreset.incrementDivergingFromPreset(
                    preset: activePreset,
                    increment: editor.overrides
                ).keys
            )
        } else {
            divergingKeys = []
        }
    }

    private func applyPreset(_ preset: ScenePreset?) {
        Task { @MainActor in await commitDescriptor(descriptor.applyingPreset(preset)) }
    }

    /// Pushes a descriptor the preset controls produced. Drops any coalesced slider commit
    /// first (it was computed against the layer being replaced). Awaited rather than fired:
    /// callers needing this on disk before something else observes the change (saving over the applied preset) had no way to know when the write landed.
    private func commitDescriptor(_ next: SceneDescriptor) async {
        commitTask?.cancel()
        commitTask = nil
        guard descriptor != next else { return }
        descriptor = next
        synchronizeEditor(force: true)
        await screenManager.updateSceneDescriptor(next, for: screen)
    }

    /// Snapshots the preset layer *and* the increment, so the new preset alone
    /// reproduces what is on screen and the increment can be dropped.
    /// Reusing the id of a same-named preset for this wallpaper replaces it rather than adding a second entry the picker cannot tell apart.
    private func saveAsPreset(name: String) async {
        await commitPendingEditorState()
        let existing = SettingsManager.shared.existingLocalScenePreset(
            named: name, baseWorkshopID: descriptor.workshopID
        )
        let preset = ScenePreset.local(
            name: name,
            baseWorkshopID: descriptor.workshopID,
            values: descriptor.presetSnapshotForCurrentState(),
            id: existing?.id ?? UUID().uuidString
        )
        // Inside `thenPersist` so the cleared descriptor is on disk before the
        // library change is announced; otherwise the observer's reconcile writes
        // the new snapshot back on top of the increment this is discarding, in a
        // Task that races us.
        await SettingsManager.shared.registerScenePreset(preset) {
            // The saved preset already reproduces what's on screen, so the increment is spent.
            // Not `applyingPreset`: overwriting the currently-applied preset lands in its
            // same-id branch, which keeps the increment on purpose (re-picking isn't a reset)
            // — here that would pin this display to today's values next time the preset is edited elsewhere.
            await commitDescriptor(
                descriptor
                    .withPresetLayer(id: preset.id, snapshot: preset.values)
                    .withPropertyOverrides([:])
            )
        }
        reloadPresetLibrary()
    }

    private func renamePreset(_ preset: ScenePreset, to name: String) {
        SettingsManager.shared.renameScenePreset(id: preset.id, to: name)
        reloadPresetLibrary()
    }

    /// Drops the preset layer from this descriptor first, so the card is not
    /// left pointing at an id the library no longer has.
    /// Layer only — the increment stays, matching the confirmation's promise and what every
    /// other display gets from `refreshingPresetSnapshot`. `applyingPreset(nil)` is the picker's "No preset", and that one does clear the increment.
    private func deletePreset(_ preset: ScenePreset) {
        if descriptor.presetID == preset.id {
            Task { @MainActor in await commitDescriptor(descriptor.withPresetLayer(id: nil, snapshot: [:])) }
        }
        SettingsManager.shared.removeScenePreset(id: preset.id)
        reloadPresetLibrary()
    }

    private func reloadPresetLibrary() {
        presetLibrary = SettingsManager.shared.loadGlobalSettings().scenePresets
        refreshPresetDerivedState()
    }

    private func badge(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> SettingRowTitleBadge? {
        guard divergingKeys.contains(property.key) else { return nil }
        return SettingRowTitleBadge(
            systemImage: "pencil.circle.fill",
            tint: DesignTokens.Colors.Status.warning,
            accessibilityLabel: Text("Changed from preset")
        )
    }

    // MARK: - Reset

    @ViewBuilder
    private func resetAccessory(hasIncrement: Bool) -> some View {
        if hasIncrement {
            Button(action: resetOverrides) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.Status.danger)
            }
            .buttonStyle(.borderless)
            .help(Text(resetTitle))
            .accessibilityLabel(Text(resetTitle))
        }
    }

    private var resetTitle: LocalizedStringKey {
        activePreset == nil ? "Reset project custom settings" : "Reset to preset"
    }

    // MARK: - Property list

    private func settingsList(
        rows: [WPEProjectSettingsPresentation.SettingsRow],
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> some View {
        let showsSectionAffiliation = rows.contains { row in
            if case .sectionHeader = row { return true }
            return false
        }

        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                settingRowView(
                    for: row,
                    values: values,
                    showsDivider: index < rows.count - 1,
                    showsSectionAffiliation: showsSectionAffiliation
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func settingRowView(
        for row: WPEProjectSettingsPresentation.SettingsRow,
        values: [String: WallpaperEngineProjectPropertyValue],
        showsDivider: Bool,
        showsSectionAffiliation: Bool
    ) -> some View {
        switch row {
        case .sectionHeader(let section):
            rowContainer(showsDivider: showsDivider) {
                sectionHeaderRow(section)
            }
        case .property(let property):
            rowContainer(
                showsDivider: showsDivider,
                showsSectionAffiliation: showsSectionAffiliation
            ) {
                propertyView(for: property, values: values)
            }
        }
    }

    private func rowContainer<Content: View>(
        showsDivider: Bool,
        showsSectionAffiliation: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: showsSectionAffiliation ? 6 : 0) {
            if showsSectionAffiliation {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.blue.opacity(0.72))
                    .frame(width: 3)
                    .padding(.vertical, 8)
                    .accessibilityHidden(true)
            }

            content()
        }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .overlay(alignment: .bottom) {
                if showsDivider {
                    Divider()
                }
            }
    }

    private func sectionHeaderRow(_ section: WPEProjectSettingsPresentation.Section) -> some View {
        let isExpanded = editor.expandedSections.contains(section.id)
        return Button {
            editor.toggleSection(section.id)
        } label: {
            HStack(spacing: 8) {
                Text(verbatim: section.title)
                    .font(DesignTokens.Typography.bodyEmphasized)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }

    private static let excludedSceneSettingKeys: Set<String> = ["schemecolor"]

    private var sceneIdentity: SceneIdentity {
        SceneIdentity(
            screenID: screen.id,
            workshopID: descriptor.workshopID,
            cacheRelativePath: descriptor.cacheRelativePath,
            entryFile: descriptor.entryFile
        )
    }

    /// `screenID` is part of the identity because two displays can play the very same scene.
    /// Without it, switching between them left `editor.overrides` holding the first display's
    /// increment while the binding pointed at the second — the next commit wrote one display's edits onto the other.
    struct SceneIdentity: Equatable {
        let screenID: CGDirectDisplayID
        let workshopID: String
        let cacheRelativePath: String
        let entryFile: String
    }

    private func synchronizeEditor(force: Bool) {
        if force || editor.identity != sceneIdentity || editor.presentation == nil {
            editor.load(
                identity: sceneIdentity,
                schema: schema,
                descriptor: descriptor,
                excludedKeys: Self.excludedSceneSettingKeys
            )
        }
    }

    static func isSceneSettingCandidate(
        _ property: WallpaperEngineProjectPropertySchema.Property
    ) -> Bool {
        !excludedSceneSettingKeys.contains(property.key)
            && WPEProjectSettingsPresentation.isSceneInteractive(property.type)
            && !property.isPromotionalLink
    }

    @ViewBuilder
    private func propertyView(
        for property: WallpaperEngineProjectPropertySchema.Property,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> some View {
        switch property.type {
        case .bool:
            SettingRow(
                icon: WPEPropertyRowIcon.symbol(for: property.type),
                verbatimTitle: property.displayText,
                titleBadge: badge(for: property)
            ) {
                Toggle("", isOn: boolBinding(for: property))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(property.displayText)
            }
        case .slider:
            SettingRow(
                icon: WPEPropertyRowIcon.symbol(for: property.type),
                verbatimTitle: property.displayText,
                titleBadge: badge(for: property)
            ) {
                HStack(spacing: DesignTokens.Inspector.sliderValueSpacing) {
                    Slider(
                        value: numberBinding(for: property),
                        in: ValueLogic.sliderRange(for: property),
                        step: ValueLogic.displaySliderStep(for: property),
                        onEditingChanged: { editing in
                            if !editing { Task { @MainActor in await commitPendingEditorState() } }
                        }
                    )
                    .frame(width: DesignTokens.Inspector.sliderWidth)
                    .controlSize(.small)
                    .accessibilityLabel(Text(verbatim: property.displayText))
                    .accessibilityValue(Text(verbatim: ValueLogic.formattedNumber(ValueLogic.value(for: property, in: values).numberValue ?? 0, for: property)))

                    Text(verbatim: ValueLogic.formattedNumber(ValueLogic.value(for: property, in: values).numberValue ?? 0, for: property))
                        .font(DesignTokens.Typography.metric)
                        .foregroundStyle(.secondary)
                        .frame(width: DesignTokens.Inspector.sliderValueWidth, alignment: .trailing)
                }
            }
        case .combo:
            let currentValue = ValueLogic.value(for: property, in: values)
            let optionsCoverCurrent = property.options.contains { $0.value == currentValue }
            SettingRow(
                icon: WPEPropertyRowIcon.symbol(for: property.type),
                verbatimTitle: property.displayText,
                titleBadge: badge(for: property)
            ) {
                if property.options.isEmpty {
                    Text(verbatim: currentValue.stringValue)
                        .font(DesignTokens.Typography.code)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("", selection: valueBinding(for: property)) {
                        if !optionsCoverCurrent {
                            Text(verbatim: "·  \(currentValue.stringValue)")
                                .tag(currentValue)
                        }
                        ForEach(property.options) { option in
                            Text(verbatim: option.displayLabel)
                                .tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    // Same compressible-menu-width rationale as the project settings
                    // card's identical combo row (`WPEProjectCustomSettingsCard`).
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 96, alignment: .trailing)
                    .layoutPriority(1)
                    .accessibilityLabel(property.displayText)
                }
            }
        case .color:
            SettingRow(
                icon: WPEPropertyRowIcon.symbol(for: property.type),
                verbatimTitle: property.displayText,
                titleBadge: badge(for: property)
            ) {
                ColorPicker("", selection: colorBinding(for: property), supportsOpacity: false)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(property.displayText)
            }
        case .textinput:
            SettingRow(
                icon: WPEPropertyRowIcon.symbol(for: property.type),
                verbatimTitle: property.displayText,
                titleBadge: badge(for: property)
            ) {
                TextField("", text: stringBinding(for: property))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 132)
                    .controlSize(.small)
                    .accessibilityLabel(property.displayText)
            }
        // Only the interactive types reach here: the presentation's `isInteractive`
        // filter drops file/directory/text/unsupported and turns `group` into a
        // section boundary before any row is built.
        default:
            EmptyView()
        }
    }

    // MARK: - Bindings

    private func valueBinding(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Binding<WallpaperEngineProjectPropertyValue> {
        Binding(
            get: {
                editor.layeredValues[property.key]
                    ?? property.defaultValue
                    ?? ValueLogic.fallbackValue(for: property)
            },
            set: { setValue($0, for: property, commit: .immediate) }
        )
    }

    private func boolBinding(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Binding<Bool> {
        Binding(
            get: { valueBinding(for: property).wrappedValue.boolValue ?? false },
            set: { setValue(.bool($0), for: property, commit: .immediate) }
        )
    }

    private func numberBinding(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Binding<Double> {
        Binding(
            get: {
                let raw = valueBinding(for: property).wrappedValue.numberValue
                    ?? property.minimum ?? 0
                return ValueLogic.clamp(raw, to: ValueLogic.sliderRange(for: property))
            },
            set: {
                setValue(
                    .number(ValueLogic.normalizedSliderValue($0, for: property)),
                    for: property,
                    commit: .coalesced
                )
            }
        )
    }

    private func stringBinding(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Binding<String> {
        Binding(
            get: { valueBinding(for: property).wrappedValue.stringValue },
            set: { setValue(.string($0), for: property, commit: .coalesced) }
        )
    }

    private func colorBinding(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Binding<CGColor> {
        Binding(
            get: { ValueLogic.cgColor(from: valueBinding(for: property).wrappedValue.stringValue) },
            set: {
                setValue(
                    .string(ValueLogic.colorString(from: $0)),
                    for: property,
                    commit: .coalesced
                )
            }
        )
    }

    private enum CommitPolicy {
        case immediate
        case coalesced
    }

    private func setValue(
        _ value: WallpaperEngineProjectPropertyValue,
        for property: WallpaperEngineProjectPropertySchema.Property,
        commit: CommitPolicy
    ) {
        // An override is dropped only when it matches the layer underneath it.
        // Where a preset supplies the key that layer is the preset, not the
        // schema default — dropping on "matches default" there would silently
        // restore the preset value and leave the control looking stuck.
        let matchesUnderlyingLayer: Bool
        if let presetValue = editor.presetValue(forKey: property.key) {
            matchesUnderlyingLayer = presetValue == value
        } else {
            matchesUnderlyingLayer = ValueLogic.matchesDefault(value: value, for: property)
        }
        guard editor.setValue(matchesUnderlyingLayer ? nil : value, forKey: property.key) else { return }
        switch commit {
        case .immediate:
            Task { @MainActor in await commitPendingEditorState() }
        case .coalesced:
            scheduleCommit()
        }
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            commitTask = nil
            await commitEditorState()
        }
    }

    private func commitPendingEditorState() async {
        commitTask?.cancel()
        commitTask = nil
        await commitEditorState()
    }

    /// Drops the increment only; `withPropertyOverrides` keeps `presetID`, so
    /// with a preset applied this is "reset to preset".
    private func resetOverrides() {
        editor.load(
            identity: sceneIdentity,
            schema: schema,
            descriptor: descriptor.withPropertyOverrides([:]),
            excludedKeys: Self.excludedSceneSettingKeys
        )
        Task { @MainActor in await commitPendingEditorState() }
    }

    /// Awaited like `commitDescriptor`, for the same reason: `updateSceneDescriptor` arbitrates
    /// by the generation taken when it *starts*, so a later-starting call always wins. An
    /// un-awaited flush here started after the preset commit that follows it and overwrote it — the card showed the preset while the stored configuration kept the increment and no `presetID`.
    private func commitEditorState() async {
        let next = descriptor.withPropertyOverrides(editor.overrides)
        guard descriptor != next else { return }
        descriptor = next
        await screenManager.updateSceneDescriptor(next, for: screen)
    }

    private func flushPendingCommit() {
        guard commitTask != nil else { return }
        Task { @MainActor in await commitPendingEditorState() }
    }

    @MainActor
    @Observable
    final class Editor {
        /// The user's increment only. The preset layer lives on `descriptor`
        /// and is merged back in by `layeredValues`.
        var overrides: [String: WallpaperEngineProjectPropertyValue] = [:]
        /// Preset layer + increment, produced by the same
        /// `SceneDescriptor.layeredPropertyValues()` the renderer reads, so a
        /// row can never show a value the wallpaper is not using.
        private(set) var layeredValues: [String: WallpaperEngineProjectPropertyValue] = [:]
        var expandedSections: Set<String> = []
        var presentation: WPEProjectSettingsPresentation?
        var rows: [WPEProjectSettingsPresentation.SettingsRow] = []
        @ObservationIgnored var identity: SceneIdentity?
        @ObservationIgnored private var schema: WallpaperEngineProjectPropertySchema?
        @ObservationIgnored private var descriptor: SceneDescriptor?
        @ObservationIgnored private var excludedKeys: Set<String> = []

        func load(
            identity: SceneIdentity,
            schema: WallpaperEngineProjectPropertySchema,
            descriptor: SceneDescriptor,
            excludedKeys: Set<String>
        ) {
            self.identity = identity
            self.schema = schema
            self.descriptor = descriptor
            self.excludedKeys = excludedKeys
            self.overrides = descriptor.propertyOverrides
            refreshPresentation()
        }

        /// The value a row falls back to once its override is dropped — `nil`
        /// when no preset supplies the key, i.e. the schema default wins.
        func presetValue(forKey key: String) -> WallpaperEngineProjectPropertyValue? {
            descriptor?.presetSnapshot[key]
        }

        /// Reset affordance tracks the increment, not the layered values: a
        /// freshly applied preset is not something to reset.
        var hasVisibleIncrement: Bool {
            guard let presentation else { return false }
            return overrides.keys.contains { presentation.visibleKeys.contains($0) }
        }

        @discardableResult
        func setValue(
            _ value: WallpaperEngineProjectPropertyValue?,
            forKey key: String
        ) -> Bool {
            var next = overrides
            if let value {
                next[key] = value
            } else {
                next.removeValue(forKey: key)
            }
            guard next != overrides else { return false }
            overrides = next
            refreshPresentation()
            return true
        }

        func toggleSection(_ sectionID: String) {
            if expandedSections.contains(sectionID) {
                expandedSections.remove(sectionID)
            } else {
                expandedSections.insert(sectionID)
            }
            refreshRows()
        }

        private func refreshPresentation() {
            guard let schema else { return }
            // Same filter the renderer applies: a preset carries an entry for
            // every manifest row, including decorative ones, and showing values
            // the wallpaper will not use would make this card lie.
            layeredValues = schema.declaredEditableValues(
                descriptor?.withPropertyOverrides(overrides).layeredPropertyValues() ?? overrides
            )
            let next = WPEProjectSettingsPresentation(
                schema: schema,
                overrides: layeredValues,
                excludedKeys: excludedKeys
            )
            presentation = next
            expandedSections = WPEProjectSettingsPresentation.prunedSectionIDs(
                expandedSections,
                for: next.sections
            )
            refreshRows()
        }

        private func refreshRows() {
            guard let presentation else {
                rows = []
                return
            }
            rows = presentation.rows(expandedSectionIDs: expandedSections)
        }
    }

}
#endif
