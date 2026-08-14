import Foundation
import Testing
@testable import LiveWallpaperCore

@Suite("Scene preset layering")
struct ScenePresetLayeringTests {
    private let preset = ScenePreset.workshop(
        workshopID: "3509243656",
        name: "Sunset",
        baseWorkshopID: "3448877775",
        values: ["skycolor": .string("1 0.4 0.2"), "windspeed": .number(0.35)]
    )

    private func descriptor(
        increment: [String: WallpaperEngineProjectPropertyValue],
        withPreset: Bool = true
    ) -> SceneDescriptor {
        SceneDescriptor(
            workshopID: "3448877775",
            cacheRelativePath: "wpe-cache/3448877775",
            entryFile: "scene.pkg",
            capabilityTier: .imageOnly,
            propertyOverrides: increment,
            presetID: withPreset ? preset.id : nil,
            presetSnapshot: withPreset ? preset.values : [:]
        )
    }

    @Test("User increment wins over the preset it sits on")
    func incrementOverridesPreset() {
        let layered = descriptor(increment: ["windspeed": .number(0.9)])
            .layeredPropertyValues()

        #expect(layered["windspeed"] == .number(0.9))
        // Untouched preset keys survive; this is the whole point of layering.
        #expect(layered["skycolor"] == .string("1 0.4 0.2"))
    }

    @Test("No preset means the increment is the whole layer")
    func incrementAloneWithoutPreset() {
        let layered = descriptor(increment: ["windspeed": .number(0.9)], withPreset: false)
            .layeredPropertyValues()

        #expect(layered == ["windspeed": .number(0.9)])
    }

    @Test("Dropping the increment resets to the preset, not to scene defaults")
    func emptyIncrementYieldsPresetValues() {
        #expect(descriptor(increment: [:]).layeredPropertyValues() == preset.values)
    }

    @Test("Divergence report ignores increment entries equal to the preset")
    func divergenceIgnoresRedundantIncrement() {
        let diverging = ScenePreset.incrementDivergingFromPreset(
            preset: preset,
            increment: [
                "windspeed": .number(0.35),
                "skycolor": .string("0 0 1")
            ]
        )

        #expect(diverging == ["skycolor": .string("0 0 1")])
    }
}

@Suite("Scene preset persistence")
struct ScenePresetPersistenceTests {
    @Test("Workshop and local presets round-trip with their source")
    func sourceRoundTrips() throws {
        let workshop = ScenePreset.workshop(
            workshopID: "3509243656",
            name: "Sunset",
            baseWorkshopID: "3448877775",
            values: ["a": .bool(true)]
        )
        let local = ScenePreset.local(
            name: "My tweak",
            baseWorkshopID: "3448877775",
            values: ["a": .number(2)],
            id: "local-fixed"
        )

        for preset in [workshop, local] {
            let data = try JSONEncoder().encode(preset)
            let decoded = try JSONDecoder().decode(ScenePreset.self, from: data)
            #expect(decoded == preset)
        }

        #expect(workshop.source == .workshop(workshopID: "3509243656"))
        #expect(local.source == .local)
        // Workshop presets key on their own workshop id so re-downloading
        // updates in place rather than piling up duplicates.
        #expect(workshop.id == "3509243656")
    }

    @Test("A preset stored before the rename flag existed still decodes")
    func decodesRecordWithoutRenameFlag() throws {
        // `hasUserAssignedName` arrived after presets were already on disk, and
        // `GlobalSettings` decodes the library entry-by-entry — a throw here
        // would not surface as an error, it would drop every stored preset.
        let json = """
        { "id": "3471679253", "name": "Sunset", "baseWorkshopID": "3448877775",
          "values": {"a": 1}, "source": {"kind": "workshop", "workshopID": "3471679253"},
          "createdAt": 0 }
        """
        let decoded = try JSONDecoder().decode(ScenePreset.self, from: Data(json.utf8))

        #expect(decoded.name == "Sunset")
        #expect(decoded.hasUserAssignedName == false)
    }

    @Test("Renaming records itself, and survives encoding")
    func renameFlagRoundTrips() throws {
        let renamed = ScenePreset.workshop(
            workshopID: "3471679253", name: "Steam Title",
            baseWorkshopID: "3448877775", values: [:]
        ).renamed(to: "My Look")

        #expect(renamed.hasUserAssignedName)
        #expect(renamed.name == "My Look")

        let decoded = try JSONDecoder().decode(
            ScenePreset.self, from: JSONEncoder().encode(renamed)
        )
        #expect(decoded.hasUserAssignedName)
        // Control: a preset nobody renamed must not come back claiming otherwise.
        let untouched = ScenePreset.local(name: "N", baseWorkshopID: "b", values: [:], id: "i")
        #expect(untouched.hasUserAssignedName == false)
    }

    @Test("Preset library survives a GlobalSettings round-trip")
    func libraryRoundTripsThroughGlobalSettings() throws {
        var settings = GlobalSettings()
        settings.scenePresets = [
            "3509243656": .workshop(
                workshopID: "3509243656",
                name: "Sunset",
                baseWorkshopID: "3448877775",
                values: ["skycolor": .string("1 0.4 0.2")]
            )
        ]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)

        #expect(decoded.scenePresets.count == 1)
        #expect(decoded.scenePresets["3509243656"]?.name == "Sunset")
        #expect(decoded.scenePresets["3509243656"]?.baseWorkshopID == "3448877775")
    }

    @Test("One unreadable preset does not drop the rest of the library")
    func libraryDecodeIsLossy() throws {
        let json = """
        { "scenePresets": {
            "good": { "id": "good", "name": "Good", "baseWorkshopID": "3448877775",
                      "values": {"a": 1}, "source": {"kind": "local"},
                      "createdAt": 0 },
            "bad":  { "id": "bad" }
        } }
        """

        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: Data(json.utf8))

        #expect(decoded.scenePresets.count == 1)
        #expect(decoded.scenePresets["good"]?.name == "Good")
        #expect(decoded.scenePresets["bad"] == nil)
    }

    @Test("Configs written before presets existed still decode")
    func descriptorWithoutPresetIDDecodes() throws {
        let json = """
        { "workshopID": "3448877775", "cacheRelativePath": "wpe-cache/3448877775",
          "entryFile": "scene.pkg", "capabilityTier": "imageOnly",
          "dependencyWorkshopIDs": [], "preflightFeatureFlags": [],
          "propertyOverrides": {"windspeed": 0.9} }
        """

        let decoded = try JSONDecoder().decode(SceneDescriptor.self, from: Data(json.utf8))

        #expect(decoded.presetID == nil)
        #expect(decoded.propertyOverrides == ["windspeed": .number(0.9)])
        // No preset pointer → the stored increment is the entire layer, which is
        // exactly the pre-migration behaviour.
        #expect(decoded.layeredPropertyValues() == ["windspeed": .number(0.9)])
    }
}

@Suite("Scene descriptor preset pointer")
struct SceneDescriptorPresetTests {
    private let descriptor = SceneDescriptor(
        workshopID: "3448877775",
        cacheRelativePath: "wpe-cache/3448877775",
        entryFile: "scene.pkg",
        capabilityTier: .imageOnly,
        propertyOverrides: ["windspeed": .number(0.9)]
    )

    @Test("Picking a preset clears an increment authored against the old one")
    func applyingPresetClearsIncrement() {
        let preset = ScenePreset.local(
            name: "Calm",
            baseWorkshopID: "3448877775",
            values: ["windspeed": .number(0.1)],
            id: "calm"
        )

        let applied = descriptor.applyingPreset(preset)

        #expect(applied.presetID == "calm")
        #expect(applied.propertyOverrides.isEmpty)
        #expect(applied.layeredPropertyValues() == ["windspeed": .number(0.1)])
    }

    @Test("Clearing the preset also drops the increment that depended on it")
    func applyingNilPresetClearsBothLayers() {
        let cleared = descriptor.applyingPreset(nil)

        #expect(cleared.presetID == nil)
        #expect(cleared.propertyOverrides.isEmpty)
    }

    @Test("Preset pointer survives an overrides edit and a descriptor round-trip")
    func presetIDSurvivesOverrideEditsAndCoding() throws {
        let edited = descriptor
            .withPresetLayer(id: "calm", snapshot: ["windspeed": .number(0.1)])
            .withPropertyOverrides(["windspeed": .number(0.5)])

        #expect(edited.presetID == "calm")

        let decoded = try JSONDecoder().decode(
            SceneDescriptor.self,
            from: JSONEncoder().encode(edited)
        )
        #expect(decoded.presetID == "calm")
        #expect(decoded.propertyOverrides == ["windspeed": .number(0.5)])
    }

    @Test("Preset identity is not part of same-scene matching")
    func isSameSceneIgnoresPreset() {
        #expect(descriptor.isSameScene(as: descriptor.withPresetLayer(id: "calm", snapshot: ["windspeed": .number(0.1)])))
    }
}

@Suite("Scene preset identity guards")
struct ScenePresetIdentityTests {
    private let descriptor = SceneDescriptor(
        workshopID: "3448877775",
        cacheRelativePath: "wpe-cache/3448877775",
        entryFile: "scene.pkg",
        capabilityTier: .imageOnly,
        propertyOverrides: ["windspeed": .number(0.9)],
        presetID: "calm"
    )

    private let calm = ScenePreset.local(
        name: "Calm", baseWorkshopID: "3448877775",
        values: ["windspeed": .number(0.1), "rain": .bool(false)], id: "calm"
    )

    @Test("Control: the matching preset really does layer")
    func matchingPresetLayers() {
        let values = descriptor.refreshingPresetSnapshot(in: ["calm": calm])
            .layeredPropertyValues()
        #expect(values["rain"] == .bool(false))
        #expect(values["windspeed"] == .number(0.9))
    }

    @Test("A deleted preset falls back to the increment, never to stale values")
    func danglingPresetIDResolvesToNil() {
        #expect(descriptor.resolvedPreset(in: [:]) == nil)
        #expect(descriptor.refreshingPresetSnapshot(in: [:])
            .layeredPropertyValues() == ["windspeed": .number(0.9)])
    }

    @Test("A preset id reused by another wallpaper's preset is refused")
    func wrongBaseWorkshopIDIsRefused() {
        let impostor = ScenePreset.local(
            name: "Other scene", baseWorkshopID: "9999999999",
            values: ["unrelated": .bool(true)], id: "calm"
        )
        #expect(descriptor.resolvedPreset(in: ["calm": impostor]) == nil)
        #expect(descriptor.refreshingPresetSnapshot(in: ["calm": impostor])
            .layeredPropertyValues()["unrelated"] == nil)
    }

    @Test("A library key disagreeing with the preset's own id is refused")
    func keyIDMismatchIsRefused() {
        let mislabelled = ScenePreset.local(
            name: "Mislabelled", baseWorkshopID: "3448877775",
            values: ["rain": .bool(true)], id: "not-calm"
        )
        #expect(descriptor.resolvedPreset(in: ["calm": mislabelled]) == nil)
    }

    @Test("Re-applying the preset already in place keeps the user's edits")
    func reapplyingSamePresetIsNotAReset() {
        let unchanged = descriptor.applyingPreset(calm)
        #expect(unchanged.propertyOverrides == ["windspeed": .number(0.9)])
        #expect(unchanged.presetID == "calm")
    }

    @Test("A preset belonging to a different wallpaper cannot be applied")
    func applyingForeignPresetIsRefused() {
        let foreign = ScenePreset.local(
            name: "Foreign", baseWorkshopID: "1111111111", values: [:], id: "foreign"
        )
        #expect(descriptor.applyingPreset(foreign).presetID == "calm")
    }

    @Test("Switching to a different preset for the same scene still clears edits")
    func switchingPresetClearsIncrement() {
        let storm = ScenePreset.local(
            name: "Storm", baseWorkshopID: "3448877775",
            values: ["rain": .bool(true)], id: "storm"
        )
        let switched = descriptor.applyingPreset(storm)
        #expect(switched.presetID == "storm")
        #expect(switched.propertyOverrides.isEmpty)
    }
}

@Suite("Scene preset clearing")
struct ScenePresetClearingTests {
    private func configuration() -> ScreenConfiguration {
        let styled = SceneDescriptor(
            workshopID: "3448877775",
            cacheRelativePath: "wpe-cache/3448877775",
            entryFile: "scene.pkg",
            capabilityTier: .imageOnly,
            propertyOverrides: ["windspeed": .number(0.9)],
            presetID: "calm"
        )
        var config = ScreenConfiguration(screenID: 1, wallpaper: .scene(styled))
        config.setSceneWallpaper(styled, origin: nil)
        return config
    }

    private var bare: SceneDescriptor {
        SceneDescriptor(
            workshopID: "3448877775",
            cacheRelativePath: "wpe-cache/3448877775",
            entryFile: "scene.pkg",
            capabilityTier: .imageOnly
        )
    }

    @Test("Control: a plain re-pick still restores the last look")
    func repickRestoresBothLayers() {
        var config = configuration()
        config.setSceneWallpaper(bare, origin: nil)

        guard case .scene(let descriptor) = config.activeWallpaper else {
            Issue.record("expected a scene wallpaper")
            return
        }
        #expect(descriptor.presetID == "calm")
        #expect(descriptor.propertyOverrides == ["windspeed": .number(0.9)])
    }
}


@Suite("Scene preset snapshot travels with the descriptor")
struct ScenePresetSnapshotTests {
    private let calm = ScenePreset.local(
        name: "Calm", baseWorkshopID: "3448877775",
        values: ["windspeed": .number(0.1), "rain": .bool(false)], id: "calm"
    )

    private var descriptor: SceneDescriptor {
        SceneDescriptor(
            workshopID: "3448877775",
            cacheRelativePath: "wpe-cache/3448877775",
            entryFile: "scene.pkg",
            capabilityTier: .imageOnly
        )
    }

    @Test("Applying a preset carries its values, not just its id")
    func applyingPresetCarriesValues() {
        let applied = descriptor.applyingPreset(calm)
        #expect(applied.presetID == "calm")
        #expect(applied.presetSnapshot == calm.values)
        // The render path has no route to the preset library, so a pointer
        // without values would render as bare scene defaults.
        #expect(applied.layeredPropertyValues() == calm.values)
    }

    @Test("An edit on top of an applied preset keeps both layers")
    func editOnPresetKeepsBothLayers() {
        let edited = descriptor.applyingPreset(calm)
            .withPropertyOverrides(["windspeed": .number(0.9)])
        #expect(edited.layeredPropertyValues()["windspeed"] == .number(0.9))
        #expect(edited.layeredPropertyValues()["rain"] == .bool(false))
    }

    @Test("Clearing the preset drops its values too")
    func clearingDropsSnapshot() {
        let cleared = descriptor.applyingPreset(calm).applyingPreset(nil)
        #expect(cleared.presetSnapshot.isEmpty)
        #expect(cleared.layeredPropertyValues().isEmpty)
    }

    @Test("Refreshing re-syncs an edited preset")
    func refreshPullsNewValues() {
        let stale = descriptor.applyingPreset(calm)
            .withPropertyOverrides(["windspeed": .number(0.9)])
        var updated = calm
        updated.values = ["windspeed": .number(0.1), "rain": .bool(true)]

        let refreshed = stale.refreshingPresetSnapshot(in: ["calm": updated])
        #expect(refreshed.presetSnapshot["rain"] == .bool(true))
        // The user's own edit survives a preset update.
        #expect(refreshed.layeredPropertyValues()["windspeed"] == .number(0.9))
    }

    @Test("Refreshing drops the layer when the preset is gone")
    func refreshDropsDeletedPreset() {
        let orphan = descriptor.applyingPreset(calm).refreshingPresetSnapshot(in: [:])
        #expect(orphan.presetID == nil)
        #expect(orphan.presetSnapshot.isEmpty)
    }

    /// Deleting a preset and choosing "No preset" are different acts, and the
    /// delete confirmation promises the user's own edits survive. The library
    /// delete converges on `refreshingPresetSnapshot` for every other display,
    /// so the display doing the deleting has to land in the same place.
    @Test("Dropping only the preset layer keeps the increment; picking No preset does not")
    func layerDropKeepsIncrementUnlikeNoPreset() {
        let edited = descriptor.applyingPreset(calm)
            .withPropertyOverrides(["windspeed": .number(0.9)])

        let deleted = edited.withPresetLayer(id: nil, snapshot: [:])
        #expect(deleted.presetID == nil)
        #expect(deleted.propertyOverrides == ["windspeed": .number(0.9)])
        // Same end state the other displays reach through the reconcile.
        #expect(deleted == edited.refreshingPresetSnapshot(in: [:]))

        // Control: the picker's "No preset" is a reset, and still is.
        #expect(edited.applyingPreset(nil).propertyOverrides.isEmpty)
    }

    /// "Save current values as a preset" over an existing name reuses that id.
    /// Routing that through `applyingPreset` would hit its same-id branch, which
    /// keeps the increment on purpose — leaving this display pinned to today's
    /// values the next time the preset changes elsewhere.
    @Test("Re-saving over the applied preset spends the increment")
    func overwritingAppliedPresetClearsIncrement() {
        let edited = descriptor.applyingPreset(calm)
            .withPropertyOverrides(["windspeed": .number(0.9)])
        var resaved = calm
        resaved.values = edited.layeredPropertyValues()

        let adopted = edited
            .withPresetLayer(id: resaved.id, snapshot: resaved.values)
            .withPropertyOverrides([:])
        #expect(adopted.propertyOverrides.isEmpty)
        // Nothing visible changed: the preset now carries what the increment did.
        #expect(adopted.layeredPropertyValues() == edited.layeredPropertyValues())
        // A later edit of the preset now reaches this display.
        var laterEdit = resaved
        laterEdit.values["windspeed"] = .number(0.2)
        #expect(
            adopted.refreshingPresetSnapshot(in: [resaved.id: laterEdit])
                .layeredPropertyValues()["windspeed"] == .number(0.2)
        )
        // Control: had the increment survived, it would have won that merge.
        #expect(
            edited.applyingPreset(resaved)
                .refreshingPresetSnapshot(in: [resaved.id: laterEdit])
                .layeredPropertyValues()["windspeed"] == .number(0.9)
        )
    }

    @Test("The snapshot survives persistence, and old configs decode without one")
    func snapshotRoundTrips() throws {
        let applied = descriptor.applyingPreset(calm)
        let decoded = try JSONDecoder().decode(
            SceneDescriptor.self, from: JSONEncoder().encode(applied)
        )
        #expect(decoded.presetSnapshot == calm.values)

        let legacy = """
        { "workshopID": "3448877775", "cacheRelativePath": "wpe-cache/3448877775",
          "entryFile": "scene.pkg", "capabilityTier": "imageOnly",
          "dependencyWorkshopIDs": [], "preflightFeatureFlags": [],
          "propertyOverrides": {"windspeed": 0.9} }
        """
        let old = try JSONDecoder().decode(SceneDescriptor.self, from: Data(legacy.utf8))
        #expect(old.presetSnapshot.isEmpty)
        #expect(old.layeredPropertyValues() == ["windspeed": .number(0.9)])
    }
}
