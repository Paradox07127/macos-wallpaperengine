#if !LITE_BUILD
import LiveWallpaperCore
import Observation
import SwiftUI

struct WPESceneCustomSettingsCard: View {
    private typealias ValueLogic = PropertyValueLogic

    var screen: Screen
    var schema: WallpaperEngineProjectPropertySchema
    @Binding var descriptor: SceneDescriptor
    var attemptID: UUID?

    @Environment(ScreenManager.self) private var screenManager
    @AppStorage("Inspector.WPESceneCustomSettingsExpanded") private var isExpanded = true
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
            // A commit coalesced for the previous display would write that display's increment onto this one.
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
        .onDisappear {
            if attemptID != nil {
                commitTask?.cancel(); commitTask = nil
            } else {
                flushPendingCommit()
            }
        }
    }

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
    }

    // MARK: - Presets

    private var activePreset: ScenePreset? {
        descriptor.resolvedPreset(in: presetLibrary)
    }

    @State private var availablePresets: [ScenePreset] = []
    /// Keys the user moved away from the applied preset.
    @State private var divergingKeys: Set<String> = []

    private var changedKeys: Set<String> {
        if activePreset == nil {
            Set(editor.overrides.keys)
        } else {
            divergingKeys
        }
    }

    /// Diverging keys when a preset is applied; otherwise the increment over the
    /// scene's own defaults — only visible settings, so a hidden row can't inflate it.
    private var changedSettingCount: Int {
        guard let presentation = editor.presentation else {
            return 0
        }
        return changedKeys.count { presentation.visibleKeys.contains($0) }
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

    /// Drops any coalesced slider commit first (computed against the layer being replaced),
    /// and is awaited so callers can know when the write has landed.
    private func commitDescriptor(_ next: SceneDescriptor) async {
        commitTask?.cancel()
        commitTask = nil
        guard descriptor != next else { return }
        descriptor = next
        synchronizeEditor(force: true)
        if let attemptID {
            screenManager.updateAttemptDescriptor(next, attemptID: attemptID, for: screen)
        } else {
            await screenManager.updateSceneDescriptor(next, for: screen)
        }
    }

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
        // Inside `thenPersist`: announced first, the observer's reconcile would write the
        // snapshot back over the increment this is discarding.
        await SettingsManager.shared.registerScenePreset(preset) {
            // Not `applyingPreset`: its same-id branch keeps the increment, which here would pin
            // this display to today's values.
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

    /// Layer only — the increment stays; `applyingPreset(nil)` is the picker's "No preset",
    /// and that one does clear the increment.
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

    /// `screenID` is part of the identity because two displays can play the same scene:
    /// without it a commit would write one display's edits onto the other.
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
        let isChanged = changedKeys.contains(property.key)
        let rowIconColor = isChanged ? DesignTokens.Colors.Status.warning : .accentColor
        // The tint is the visual cue; the badge is what VoiceOver reads.
        let changedBadge: SettingRowTitleBadge? = isChanged
            ? SettingRowTitleBadge(
                systemImage: "pencil.circle.fill",
                tint: DesignTokens.Colors.Status.warning,
                accessibilityLabel: Text("Changed from preset")
            )
            : nil

        switch property.type {
        case .bool:
            SettingRow(
                icon: WPEPropertyRowIcon.symbol(for: property.type),
                iconColor: rowIconColor,
                verbatimTitle: property.displayText,
                titleBadge: changedBadge
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
                iconColor: rowIconColor,
                verbatimTitle: property.displayText,
                titleBadge: changedBadge
            ) {
                HStack(spacing: DesignTokens.Inspector.sliderValueSpacing) {
                    QuantizedSlider(
                        value: numberBinding(for: property),
                        in: ValueLogic.sliderRange(for: property),
                        step: ValueLogic.sliderStep(for: property),
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
                iconColor: rowIconColor,
                verbatimTitle: property.displayText,
                titleBadge: changedBadge
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
                iconColor: rowIconColor,
                verbatimTitle: property.displayText,
                titleBadge: changedBadge
            ) {
                ColorPicker("", selection: colorBinding(for: property), supportsOpacity: false)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(property.displayText)
            }
        case .textinput:
            SettingRow(
                icon: WPEPropertyRowIcon.symbol(for: property.type),
                iconColor: rowIconColor,
                verbatimTitle: property.displayText,
                titleBadge: changedBadge
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
        // The layer underneath is the preset where it supplies the key, not the schema default —
        // dropping on "matches default" would restore the preset value and leave the control stuck.
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

    /// Awaited: `updateSceneDescriptor` arbitrates by the generation taken when it *starts*,
    /// so an un-awaited flush would overwrite a later preset commit.
    private func commitEditorState() async {
        let next = descriptor.withPropertyOverrides(editor.overrides)
        guard descriptor != next else { return }
        descriptor = next
        if let attemptID {
            screenManager.updateAttemptDescriptor(next, attemptID: attemptID, for: screen)
        } else {
            await screenManager.updateSceneDescriptor(next, for: screen)
        }
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
        /// `SceneDescriptor.layeredPropertyValues()` the renderer reads.
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
