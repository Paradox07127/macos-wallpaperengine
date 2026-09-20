#if !LITE_BUILD
import LiveWallpaperCore
import Observation
import SwiftUI

/// The host retains one owner per (display, scene) across group/display switches, until detail closes or the scene changes.
/// A scheduled commit retains this owner through delivery to its original screen.
@MainActor
@Observable
final class SceneSettingsOwner {
    private typealias ValueLogic = PropertyValueLogic

    let screen: Screen
    let editor: WPESceneCustomSettingsCard.Editor
    private let expandsSectionsOnLoad: Bool
    var query = ""
    private(set) var descriptor: SceneDescriptor
    private(set) var commitTask: Task<Void, Never>?
    private var schema: WallpaperEngineProjectPropertySchema?
    private var presetLibrary: [String: ScenePreset] = [:]
    private let screenManager: ScreenManager
    /// Non-nil: edits go to this load attempt for its retry, not to the applied wallpaper.
    let attemptID: UUID?
    private let onDescriptorChange: (SceneDescriptor) -> Void

    init(
        screen: Screen,
        screenManager: ScreenManager,
        descriptor: SceneDescriptor,
        schema: WallpaperEngineProjectPropertySchema? = nil,
        attemptID: UUID? = nil,
        editor: WPESceneCustomSettingsCard.Editor? = nil,
        onDescriptorChange: @escaping (SceneDescriptor) -> Void = { _ in }
    ) {
        self.editor = editor ?? WPESceneCustomSettingsCard.Editor()
        expandsSectionsOnLoad = editor == nil
        self.screen = screen
        self.screenManager = screenManager
        self.descriptor = descriptor
        self.schema = schema
        self.attemptID = attemptID
        self.onDescriptorChange = onDescriptorChange
        synchronizeEditor(force: true)
        expandInitialSections()
        reloadPresetLibrary()
    }

    func loadSchema() async {
        guard schema == nil else { return }
        let inspected = attemptID == nil ? nil : screenManager.inspectedWallpaperAttempt(for: screen)?.configuration
        let outcome = await WPESceneProjectSchemaLoader.load(
            descriptor: descriptor,
            wpeOrigin: (inspected ?? screenManager.getConfiguration(for: screen))?.wpeOrigin
        )
        guard !Task.isCancelled else { return }
        schema = outcome.schema
        synchronizeEditor(force: false)
        expandInitialSections()
        refreshPresetDerivedState()
    }

    private func expandInitialSections() {
        guard expandsSectionsOnLoad, let presentation = editor.presentation else { return }
        for section in presentation.sections where !editor.expandedSections.contains(section.id) {
            editor.toggleSection(section.id)
        }
    }

    func synchronize(descriptor next: SceneDescriptor, force: Bool = false) {
        let presetChanged = descriptor.presetID != next.presetID || descriptor.presetSnapshot != next.presetSnapshot
        descriptor = next
        if force || presetChanged || (next.propertyOverrides != editor.overrides && commitTask == nil) {
            synchronizeEditor(force: true)
        }
        refreshPresetDerivedState()
    }

    func cancelPendingCommit() {
        commitTask?.cancel()
        commitTask = nil
    }

    // MARK: - Presets

    var activePreset: ScenePreset? {
        descriptor.resolvedPreset(in: presetLibrary)
    }

    private(set) var availablePresets: [ScenePreset] = []
    /// Keys the user moved away from the applied preset.
    private var divergingKeys: Set<String> = []

    var changedKeys: Set<String> {
        if activePreset == nil {
            Set(editor.overrides.keys)
        } else {
            divergingKeys
        }
    }

    /// Diverging keys when a preset is applied; otherwise the increment over the
    /// scene's own defaults — only visible settings, so a hidden row can't inflate it.
    var changedSettingCount: Int {
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

    func applyPreset(_ preset: ScenePreset?) {
        Task { @MainActor in await commitDescriptor(descriptor.applyingPreset(preset)) }
    }

    /// Drops any coalesced slider commit first (computed against the layer being replaced),
    /// and is awaited so callers can know when the write has landed.
    private func commitDescriptor(_ next: SceneDescriptor) async {
        commitTask?.cancel()
        commitTask = nil
        guard descriptor != next else { return }
        descriptor = next
        onDescriptorChange(next)
        synchronizeEditor(force: true)
        refreshPresetDerivedState()
        if let attemptID {
            screenManager.updateAttemptDescriptor(next, attemptID: attemptID, for: screen)
        } else {
            await screenManager.updateSceneDescriptor(next, for: screen)
        }
    }

    func saveAsPreset(name: String) async {
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
        await SettingsManager.shared.registerScenePreset(preset) { [self] in
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

    func renamePreset(_ preset: ScenePreset, to name: String) {
        SettingsManager.shared.renameScenePreset(id: preset.id, to: name)
        reloadPresetLibrary()
    }

    /// Layer only — the increment stays; `applyingPreset(nil)` is the picker's "No preset",
    /// and that one does clear the increment.
    func deletePreset(_ preset: ScenePreset) {
        if descriptor.presetID == preset.id {
            Task { @MainActor in await commitDescriptor(descriptor.withPresetLayer(id: nil, snapshot: [:])) }
        }
        SettingsManager.shared.removeScenePreset(id: preset.id)
        reloadPresetLibrary()
    }

    func reloadPresetLibrary() {
        presetLibrary = SettingsManager.shared.loadGlobalSettings().scenePresets
        refreshPresetDerivedState()
    }

    var sceneIdentity: WPESceneCustomSettingsCard.SceneIdentity {
        WPESceneCustomSettingsCard.SceneIdentity(
            screenID: screen.id,
            workshopID: descriptor.workshopID,
            cacheRelativePath: descriptor.cacheRelativePath,
            entryFile: descriptor.entryFile
        )
    }

    private func synchronizeEditor(force: Bool) {
        guard let schema else { return }
        if force || editor.identity != sceneIdentity || editor.presentation == nil {
            editor.load(
                identity: sceneIdentity,
                schema: schema,
                descriptor: descriptor,
                excludedKeys: WPESceneCustomSettingsCard.excludedSceneSettingKeys
            )
        }
    }

    enum CommitPolicy {
        case immediate
        case coalesced
    }

    func setValue(
        _ value: WallpaperEngineProjectPropertyValue,
        for property: WallpaperEngineProjectPropertySchema.Property,
        commit: CommitPolicy
    ) {
        // The layer underneath is the preset where it supplies the key, not the schema default —
        // dropping on "matches default" would restore the preset value and leave the control stuck.
        let matchesUnderlyingLayer: Bool = if let presetValue = editor.presetValue(forKey: property.key) {
            presetValue == value
        } else {
            ValueLogic.matchesDefault(value: value, for: property)
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

    func commitPendingEditorState() async {
        commitTask?.cancel()
        commitTask = nil
        await commitEditorState()
    }

    /// Drops the increment only; `withPropertyOverrides` keeps `presetID`, so
    /// with a preset applied this is "reset to preset".
    func resetOverrides() {
        guard let schema else { return }
        editor.load(
            identity: sceneIdentity,
            schema: schema,
            descriptor: descriptor.withPropertyOverrides([:]),
            excludedKeys: WPESceneCustomSettingsCard.excludedSceneSettingKeys
        )
        Task { @MainActor in await commitPendingEditorState() }
    }

    /// Awaited: `updateSceneDescriptor` arbitrates by the generation taken when it *starts*,
    /// so an un-awaited flush would overwrite a later preset commit.
    private func commitEditorState() async {
        let next = descriptor.withPropertyOverrides(editor.overrides)
        guard descriptor != next else { return }
        descriptor = next
        onDescriptorChange(next)
        refreshPresetDerivedState()
        if let attemptID {
            screenManager.updateAttemptDescriptor(next, attemptID: attemptID, for: screen)
        } else {
            await screenManager.updateSceneDescriptor(next, for: screen)
        }
    }

    func flushPendingCommit() {
        guard commitTask != nil else { return }
        Task { @MainActor in await commitPendingEditorState() }
    }
}
#endif
