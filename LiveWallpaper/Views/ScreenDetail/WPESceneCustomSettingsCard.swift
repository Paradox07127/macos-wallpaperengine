#if !LITE_BUILD
import LiveWallpaperCore
import Observation
import SwiftUI

/// Edits project properties stored directly on a WPE scene descriptor.
struct WPESceneCustomSettingsCard: View {
    private typealias ValueLogic = WPEProjectPropertyValueLogic

    var screen: Screen
    var schema: WallpaperEngineProjectPropertySchema
    @Binding var descriptor: SceneDescriptor

    @Environment(ScreenManager.self) private var screenManager
    @AppStorage("Inspector.WPESceneCustomSettingsExpanded") private var isExpanded = true
    /// Card-local edit state. Keeping high-frequency slider/text/color changes
    /// out of `ScreenDetailDraftState` prevents the whole inspector (and its
    /// hosted preview) from being invalidated on every gesture sample.
    @State private var editor = Editor()
    @State private var commitTask: Task<Void, Never>?

    var body: some View {
        GroupBox {
            CollapsibleSection(
                title: "Scene Custom Settings",
                systemImage: "slider.horizontal.3",
                isExpanded: $isExpanded,
                trailingAccessory: {
                    resetAccessory(hasOverrides: editor.presentation?.hasVisibleOverrides ?? false)
                }
            ) {
                if let presentation = editor.presentation {
                    settingsList(rows: editor.rows, values: presentation.values)
                }
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
        .onAppear { synchronizeEditor(force: true) }
        .onChange(of: sceneIdentity) { _, _ in synchronizeEditor(force: true) }
        .onChange(of: descriptor.propertyOverrides) { _, overrides in
            guard overrides != editor.overrides, commitTask == nil else { return }
            synchronizeEditor(force: true)
        }
        .onDisappear { flushPendingCommit() }
    }

    // MARK: - Reset

    @ViewBuilder
    private func resetAccessory(hasOverrides: Bool) -> some View {
        if hasOverrides {
            Button(action: resetOverrides) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.Status.danger)
            }
            .buttonStyle(.borderless)
            .help(Text("Reset project custom settings"))
            .accessibilityLabel(Text("Reset project custom settings"))
        }
    }

    // MARK: - Property list

    private func settingsList(
        rows: [WPEProjectSettingsPresentation.Row],
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
        .padding(.top, -10)
    }

    @ViewBuilder
    private func settingRowView(
        for row: WPEProjectSettingsPresentation.Row,
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
            toggleSection(section.id)
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
            workshopID: descriptor.workshopID,
            cacheRelativePath: descriptor.cacheRelativePath,
            entryFile: descriptor.entryFile
        )
    }

    struct SceneIdentity: Equatable {
        let workshopID: String
        let cacheRelativePath: String
        let entryFile: String
    }

    private func synchronizeEditor(force: Bool) {
        if force || editor.identity != sceneIdentity || editor.presentation == nil {
            editor.load(
                identity: sceneIdentity,
                schema: schema,
                overrides: descriptor.propertyOverrides,
                excludedKeys: Self.excludedSceneSettingKeys
            )
        }
    }

    private func toggleSection(_ sectionID: String) {
        editor.toggleSection(sectionID)
    }

    static func isSceneSettingCandidate(
        _ property: WallpaperEngineProjectPropertySchema.Property
    ) -> Bool {
        !excludedSceneSettingKeys.contains(property.key)
            && isInteractive(property.type)
            && !property.isPromotionalLink
    }

    static func isInteractive(_ type: WallpaperEngineProjectPropertySchema.PropertyType) -> Bool {
        WPEProjectSettingsPresentation.isSceneInteractive(type)
    }

    @ViewBuilder
    private func propertyView(
        for property: WallpaperEngineProjectPropertySchema.Property,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> some View {
        switch property.type {
        case .bool:
            WPEProjectSettingRow(title: property.displayText) {
                Toggle("", isOn: boolBinding(for: property))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(property.displayText)
            }
        case .slider:
            WPEProjectSettingRow(title: property.displayText) {
                HStack(spacing: DesignTokens.Inspector.sliderValueSpacing) {
                    Slider(
                        value: numberBinding(for: property),
                        in: ValueLogic.sliderRange(for: property),
                        step: ValueLogic.sliderStep(for: property),
                        onEditingChanged: { editing in
                            if !editing { commitPendingEditorState() }
                        }
                    )
                    .frame(width: DesignTokens.Inspector.sliderWidth)
                    .controlSize(.small)

                    Text(verbatim: ValueLogic.formattedNumber(ValueLogic.value(for: property, in: values).numberValue ?? 0, for: property))
                        .font(DesignTokens.Typography.metric)
                        .foregroundStyle(.secondary)
                        .frame(width: DesignTokens.Inspector.sliderValueWidth, alignment: .trailing)
                }
            }
        case .combo:
            let currentValue = ValueLogic.value(for: property, in: values)
            let optionsCoverCurrent = property.options.contains { $0.value == currentValue }
            WPEProjectSettingRow(title: property.displayText) {
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
                    // Option labels are author-supplied (song titles, preset names)
                    // with no length bound. `.fixedSize()` made the menu demand its
                    // ideal width — the LONGEST label — which pushed the settings
                    // column past the panel. Staying compressible is what keeps the
                    // panel intact; no max width is needed for that.
                    //
                    // But `WPEProjectSettingRow` gives its title `maxWidth: .infinity`
                    // AND `layoutPriority(1)`, so a merely-compressible control loses
                    // every point of the row and collapses to a bare chevron. Matching
                    // that priority makes the two share the row, and `minWidth` keeps
                    // the menu clickable when the title is long.
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 96, alignment: .trailing)
                    .layoutPriority(1)
                    .accessibilityLabel(property.displayText)
                }
            }
        case .color:
            WPEProjectSettingRow(title: property.displayText) {
                ColorPicker("", selection: colorBinding(for: property), supportsOpacity: false)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(property.displayText)
            }
        case .textinput:
            WPEProjectSettingRow(title: property.displayText) {
                TextField("", text: stringBinding(for: property))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 132)
                    .controlSize(.small)
                    .accessibilityLabel(property.displayText)
            }
        case .file, .directory:
            WPEProjectSettingRow(
                icon: property.type == .file ? "doc.badge.plus" : "folder.badge.plus",
                iconColor: .secondary,
                title: property.displayText,
                subtitle: .localized("Not supported on macOS yet")
            ) {
                EmptyView()
            }
            .disabled(true)
            .opacity(0.55)
        case .group:
            WPEProjectTextBlock(text: property.displayText, isHeader: true)
        case .text:
            WPEProjectTextBlock(text: property.displayText, isHeader: false)
        case .unsupported:
            EmptyView()
        }
    }

    // MARK: - Bindings

    private func valueBinding(
        for property: WallpaperEngineProjectPropertySchema.Property
    ) -> Binding<WallpaperEngineProjectPropertyValue> {
        Binding(
            get: {
                editor.overrides[property.key]
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
        let matchesDefault = ValueLogic.matchesDefault(value: value, for: property)
        guard editor.setValue(matchesDefault ? nil : value, forKey: property.key) else { return }
        switch commit {
        case .immediate:
            commitPendingEditorState()
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
            commitEditorState()
        }
    }

    private func commitPendingEditorState() {
        commitTask?.cancel()
        commitTask = nil
        commitEditorState()
    }

    private func resetOverrides() {
        editor.load(
            identity: sceneIdentity,
            schema: schema,
            overrides: [:],
            excludedKeys: Self.excludedSceneSettingKeys
        )
        commitPendingEditorState()
    }

    private func commitEditorState() {
        let next = descriptor.withPropertyOverrides(editor.overrides)
        guard descriptor != next else { return }
        descriptor = next
        Task { @MainActor in await screenManager.updateSceneDescriptor(next, for: screen) }
    }

    private func flushPendingCommit() {
        guard commitTask != nil else { return }
        commitPendingEditorState()
    }

    @MainActor
    @Observable
    final class Editor {
        var overrides: [String: WallpaperEngineProjectPropertyValue] = [:]
        var expandedSections: Set<String> = []
        var presentation: WPEProjectSettingsPresentation?
        var rows: [WPEProjectSettingsPresentation.Row] = []
        @ObservationIgnored var identity: SceneIdentity?
        @ObservationIgnored private var schema: WallpaperEngineProjectPropertySchema?
        @ObservationIgnored private var excludedKeys: Set<String> = []

        func load(
            identity: SceneIdentity,
            schema: WallpaperEngineProjectPropertySchema,
            overrides: [String: WallpaperEngineProjectPropertyValue],
            excludedKeys: Set<String>
        ) {
            self.identity = identity
            self.schema = schema
            self.excludedKeys = excludedKeys
            self.overrides = overrides
            refreshPresentation()
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
            let next = WPEProjectSettingsPresentation(
                schema: schema,
                overrides: overrides,
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
