#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Observation
import os
import Testing

struct WPESliderDetentBudgetTests {
    private typealias ValueLogic = PropertyValueLogic

    private func property(
        min: Double,
        max: Double,
        step: Double?,
        fraction: Bool = true
    ) throws -> WallpaperEngineProjectPropertySchema.Property {
        var slider: [String: Any] = [
            "type": "slider",
            "text": "Probe",
            "value": min,
            "min": min,
            "max": max,
            "fraction": fraction,
        ]
        if let step {
            slider["step"] = step
        }
        let root: [String: Any] = ["general": ["properties": ["probe": slider]]]
        let data = try JSONSerialization.data(withJSONObject: root)
        let schema = try WallpaperEngineProjectPropertySchema.parse(data: data)
        return try #require(schema.properties.first)
    }

    private func detents(_ property: WallpaperEngineProjectPropertySchema.Property) -> Double {
        let range = ValueLogic.sliderRange(for: property)
        // Stops, not intervals: a stepped slider can also rest on both ends.
        return (range.upperBound - range.lowerBound) / ValueLogic.displaySliderStep(for: property) + 1
    }

    @Test("A step coarser than the budget is handed through untouched")
    func coarseStepIsUntouched() throws {
        let probe = try property(min: 0, max: 10, step: 0.5)
        #expect(ValueLogic.displaySliderStep(for: probe) == 0.5)
    }

    @Test("The real 0...300 step 0.001 case is capped to the detent budget")
    func authoredMicroStepIsCapped() throws {
        let probe = try property(min: 0, max: 300, step: 0.001)
        #expect(ValueLogic.sliderStep(for: probe) == 0.001)
        #expect(detents(probe) <= ValueLogic.maximumSliderDetents)
    }

    @Test("The pathological 100000...100000000 step 0.001 case is capped too")
    func hugeRangeMicroStepIsCapped() throws {
        let probe = try property(min: 100_000, max: 100_000_000, step: 0.001)
        #expect(detents(probe) <= ValueLogic.maximumSliderDetents)
    }

    @Test("Every display detent is also an authored-step detent")
    func displayGridNestsInsideAuthoredGrid() throws {
        for (min, max, step) in [
            (0.0, 300.0, 0.001),
            (1.0, 100.0, 0.001),
            (0.1, 10.0, 0.001),
            (100_000.0, 100_000_000.0, 0.001),
        ] {
            let probe = try property(min: min, max: max, step: step)
            let display = ValueLogic.displaySliderStep(for: probe)
            let multiplier = display / ValueLogic.sliderStep(for: probe)
            #expect(abs(multiplier - multiplier.rounded()) < 1e-6)
            #expect(multiplier >= 1)
        }
    }

    @Test("A property with no authored step keeps its implied step")
    func absentStepFallsBackToImpliedStep() throws {
        let integral = try property(min: 0, max: 50, step: nil, fraction: false)
        #expect(ValueLogic.displaySliderStep(for: integral) == 1)

        let fractional = try property(min: 0, max: 5, step: nil)
        #expect(ValueLogic.displaySliderStep(for: fractional) == 0.1)
    }

    @Test("Both settings cards quantize values without enumerating display stops")
    func settingsCardsUseValueQuantization() throws {
        for (name, expected) in [
            ("SceneSettingsCard", "step: ValueLogic.sliderStep(for: property)"),
            ("ProjectSettingsCard", "quantizationStep: ValueLogic.sliderStep(for: property)"),
        ] {
            let source = try RepositoryRoot.source(
                "LiveWallpaper/Views/ScreenDetail/\(name).swift"
            )
            #expect(
                source.contains(expected) && !source.contains("ValueLogic.displaySliderStep"),
                "\(name) must use the authored value grid without discrete display stops"
            )
            #expect(
                source.contains("ValueLogic.normalizedSliderValue"),
                "\(name) must still snap writes to the authored step"
            )
        }
    }

    @MainActor
    @Test func numericEditDoesNotPublishUnchangedRows() throws {
        let editor = try makeEditor()
        editor.toggleSection("main")
        let oldRows = editor.rows
        let rowChanged = OSAllocatedUnfairLock(initialState: false)
        let groupsChanged = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = editor.rows } onChange: { rowChanged.withLock { $0 = true } }
        withObservationTracking { _ = editor.expandedSections } onChange: { groupsChanged.withLock { $0 = true } }
        #expect(editor.setValue(.number(0.123), forKey: "gain"))
        #expect(editor.layeredValues["gain"] == .number(0.123))
        #expect(editor.rows == oldRows)
        #expect(!rowChanged.withLock { $0 })
        #expect(!groupsChanged.withLock { $0 })
    }

    @MainActor
    @Test func conditionalRowsStillUpdateAndPreserveHiddenValues() throws {
        let editor = try makeEditor()
        editor.toggleSection("main")
        editor.setValue(.number(0.123), forKey: "gain")
        editor.setValue(.bool(true), forKey: "show")
        #expect(editor.rows.contains { $0.id == "property:detail" })
        editor.setValue(.number(0.456), forKey: "detail")
        editor.setValue(.bool(false), forKey: "show")
        #expect(!editor.rows.contains { $0.id == "property:detail" })
        #expect(editor.overrides["detail"] == .number(0.456))
        editor.toggleSection("main")
        editor.toggleSection("main")
        editor.setValue(.bool(true), forKey: "show")
        #expect(editor.rows.contains { $0.id == "property:detail" })
        #expect(editor.layeredValues["detail"] == .number(0.456))
        #expect(editor.layeredValues["gain"] == .number(0.123))
    }

    @MainActor
    private func makeEditor() throws -> WPESceneCustomSettingsCard.Editor {
        let json = #"{"general":{"properties":{"main":{"type":"group","text":"Main","order":0},"gain":{"type":"slider","text":"Gain","min":0,"max":300,"step":0.001,"value":0,"order":1},"show":{"type":"bool","text":"Show","value":false,"order":2},"detail":{"type":"slider","text":"Detail","value":0,"min":0,"max":1,"condition":"show.value","order":3}}}}"#
        let schema = try WallpaperEngineProjectPropertySchema.parse(data: Data(json.utf8))
        let editor = WPESceneCustomSettingsCard.Editor()
        editor.load(
            identity: .init(screenID: 1, workshopID: "probe", cacheRelativePath: "probe", entryFile: "scene.json"),
            schema: schema,
            descriptor: SceneDescriptor(workshopID: "probe", cacheRelativePath: "probe", entryFile: "scene.json", capabilityTier: .imageOnly),
            excludedKeys: []
        )
        return editor
    }
}
#endif
