#if !LITE_BUILD
import LiveWallpaperCore
import Observation
import SwiftUI

struct WPESceneCustomSettingsCard: View {
    var screen: Screen
    var schema: WallpaperEngineProjectPropertySchema
    @Binding var descriptor: SceneDescriptor
    var attemptID: UUID?

    @Environment(ScreenManager.self) private var screenManager
    /// Only the Edit Desk provides one; the old detail page records nothing.
    @Environment(EditDeskUndoStack.self) private var undo: EditDeskUndoStack?
    @AppStorage("Inspector.WPESceneCustomSettingsExpanded") private var isExpanded = true
    @State private var editor = Editor()
    @State private var owner: SceneSettingsOwner?

    var body: some View {
        VStack(spacing: 0) {
            if let owner {
                SceneSettingsCardContent(owner: owner, isExpanded: $isExpanded)
            }
        }
        .onAppear {
            if let owner {
                owner.synchronize(descriptor: descriptor, force: true)
                owner.reloadPresetLibrary()
            } else {
                makeOwner()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scenePresetLibraryDidChange)) { _ in
            owner?.reloadPresetLibrary()
        }
        .onChange(of: sceneIdentity) { _, _ in
            owner?.cancelPendingCommit()
            let nextEditor = Editor()
            nextEditor.expandedSections = editor.expandedSections
            editor = nextEditor
            makeOwner()
        }
        .onChange(of: descriptor) { _, next in
            owner?.synchronize(descriptor: next)
        }
        .onDisappear {
            if attemptID != nil {
                owner?.cancelPendingCommit()
            } else {
                owner?.flushPendingCommit()
            }
        }
    }

    private var sceneIdentity: SceneIdentity {
        SceneIdentity(
            screenID: screen.id, workshopID: descriptor.workshopID,
            cacheRelativePath: descriptor.cacheRelativePath, entryFile: descriptor.entryFile
        )
    }

    private func makeOwner() {
        let binding = $descriptor
        let screen = screen
        var record: SceneSettingsOwner.UndoableChange?
        if let undo {
            record = { action, before, _, flush in undo.recordSceneChange(action, from: before, on: screen, flush: flush) }
        }
        owner = SceneSettingsOwner(
            screen: screen, screenManager: screenManager, descriptor: descriptor,
            schema: schema, attemptID: attemptID, editor: editor,
            onDescriptorChange: { binding.wrappedValue = $0 },
            onUndoableChange: record
        )
    }

    static let excludedSceneSettingKeys: Set<String> = ["schemecolor"]

    static func isSceneSettingCandidate(
        _ property: WallpaperEngineProjectPropertySchema.Property
    ) -> Bool {
        !excludedSceneSettingKeys.contains(property.key)
            && WPEProjectSettingsPresentation.isSceneInteractive(property.type)
            && !property.isPromotionalLink
    }

    /// `screenID` is part of the identity because two displays can play the same scene:
    /// without it a commit would write one display's edits onto the other.
    struct SceneIdentity: Hashable {
        let screenID: CGDirectDisplayID
        let workshopID: String
        let cacheRelativePath: String
        let entryFile: String
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
            overrides = descriptor.propertyOverrides
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

struct SceneSettingsCardContent: View {
    let owner: SceneSettingsOwner
    @Binding var isExpanded: Bool

    var body: some View {
        GroupBox {
            CollapsibleSection(
                title: "Scene Custom Settings",
                systemImage: "slider.horizontal.3",
                isExpanded: $isExpanded,
                trailingAccessory: {
                    resetAccessory(hasIncrement: owner.editor.hasVisibleIncrement)
                },
                content: {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                        presetWell
                        SceneSettingsRows(owner: owner)
                    }
                }
            )
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    var presetWell: some View {
        ScenePresetBar(
            presets: owner.availablePresets,
            activePreset: owner.activePreset,
            changedCount: owner.changedSettingCount,
            onSelect: { owner.applyPreset($0) },
            onSave: { name in Task { @MainActor in await owner.saveAsPreset(name: name) } },
            onRename: { owner.renamePreset($0, to: $1) },
            onDelete: { owner.deletePreset($0) }
        )
    }

    // MARK: - Reset

    @ViewBuilder
    private func resetAccessory(hasIncrement: Bool) -> some View {
        if hasIncrement {
            Button(action: owner.resetOverrides) {
                Image(systemName: "arrow.counterclockwise")
                    .font(DesignTokens.EditDesk.Typography.chip.weight(.medium))
                    .foregroundStyle(DesignTokens.Colors.Status.danger)
            }
            .buttonStyle(.borderless)
            .help(Text(resetTitle))
            .accessibilityLabel(Text(resetTitle))
        }
    }

    private var resetTitle: LocalizedStringKey {
        owner.activePreset == nil ? "Reset project custom settings" : "Reset to preset"
    }
}

struct SceneSettingsRows: View {
    private typealias ValueLogic = PropertyValueLogic
    let owner: SceneSettingsOwner
    var isConsole = false
    private var editor: WPESceneCustomSettingsCard.Editor {
        owner.editor
    }

    var body: some View {
        if let presentation = editor.presentation {
            settingsList(rows: editor.rows, values: presentation.values)
        }
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
    func settingRowView(
        for row: WPEProjectSettingsPresentation.SettingsRow,
        values: [String: WallpaperEngineProjectPropertyValue],
        showsDivider: Bool,
        showsSectionAffiliation: Bool,
        groupTint: Color? = nil
    ) -> some View {
        switch row {
        case .sectionHeader(let section):
            rowContainer(showsDivider: showsDivider, groupTint: groupTint) {
                sectionHeaderRow(section)
            }
        case .property(let property):
            rowContainer(
                showsDivider: showsDivider,
                showsSectionAffiliation: showsSectionAffiliation,
                groupTint: groupTint
            ) {
                propertyView(for: property, values: values)
            }
        }
    }

    private func rowContainer<Content: View>(
        showsDivider: Bool,
        showsSectionAffiliation: Bool = false,
        groupTint: Color? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: showsSectionAffiliation ? 6 : 0) {
            if let groupTint {
                Circle()
                    .fill(groupTint)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
            } else if showsSectionAffiliation {
                Capsule()
                    .fill(Color.blue.opacity(0.72))
                    .frame(width: 3)
                    .padding(.vertical, 8)
                    .accessibilityHidden(true)
            }

            content()
        }
        .frame(maxWidth: .infinity, minHeight: isConsole ? 36 : 44, alignment: .leading)
        .frame(height: isConsole ? 36 : nil)
        .lineLimit(isConsole ? 1 : nil)
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
                    .font(DesignTokens.EditDesk.Typography.cardTitle)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, isConsole ? 0 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func propertyView(
        for property: WallpaperEngineProjectPropertySchema.Property,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> some View {
        let isChanged = owner.changedKeys.contains(property.key)
        let changedColor = isConsole ? DesignTokens.EditDesk.Colors.warning : DesignTokens.Colors.Status.warning
        let rowIconColor = isChanged ? changedColor : .accentColor
        // The tint is the visual cue; the badge is what VoiceOver reads.
        let changedBadge: SettingRowTitleBadge? = isChanged
            ? SettingRowTitleBadge(
                systemImage: isConsole ? "circle.fill" : "pencil.circle.fill",
                tint: changedColor,
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
                if isConsole {
                    CoalescedSlider(
                        value: numberBinding(for: property).wrappedValue,
                        in: ValueLogic.sliderRange(for: property),
                        quantizationStep: ValueLogic.sliderStep(for: property),
                        owner: SliderOwner(scene: owner.sceneIdentity, propertyKey: property.key),
                        accessibilityLabel: Text(verbatim: property.displayText),
                        accessibilityValue: { Text(verbatim: ValueLogic.formattedNumber($0, for: property)) },
                        write: { numberBinding(for: property).wrappedValue = $0 },
                        readout: { value in
                            Text(verbatim: ValueLogic.formattedNumber(value, for: property))
                                .font(DesignTokens.Typography.metric)
                                .foregroundStyle(.secondary)
                                .frame(width: DesignTokens.Inspector.sliderValueWidth, alignment: .trailing)
                        }
                    )
                } else {
                    HStack(spacing: DesignTokens.Inspector.sliderValueSpacing) {
                        QuantizedSlider(
                            value: numberBinding(for: property),
                            in: ValueLogic.sliderRange(for: property),
                            step: ValueLogic.sliderStep(for: property),
                            onEditingChanged: { editing in
                                if !editing {
                                    Task { @MainActor in await owner.commitPendingEditorState() }
                                }
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

    private struct SliderOwner: Hashable {
        let scene: WPESceneCustomSettingsCard.SceneIdentity
        let propertyKey: String
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
            set: { owner.setValue($0, for: property, commit: .immediate) }
        )
    }

    private func boolBinding(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Binding<Bool> {
        Binding(
            get: { valueBinding(for: property).wrappedValue.boolValue ?? false },
            set: { owner.setValue(.bool($0), for: property, commit: .immediate) }
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
                owner.setValue(
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
            set: { owner.setValue(.string($0), for: property, commit: .coalesced) }
        )
    }

    private func colorBinding(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Binding<CGColor> {
        Binding(
            get: { ValueLogic.cgColor(from: valueBinding(for: property).wrappedValue.stringValue) },
            set: {
                owner.setValue(
                    .string(ValueLogic.colorString(from: $0)),
                    for: property,
                    commit: .coalesced
                )
            }
        )
    }

}
#endif
