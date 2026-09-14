#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

/// The slider step is capped at `maximumSliderDetents` because SwiftUI's slider costs ~4x more per layout pass beyond ~1000 detents.
/// Ledger: `.notes/review/2026-08-22-scene-settings-scroll-jank.md`.
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
            "fraction": fraction
        ]
        if let step { slider["step"] = step }
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
            (100_000.0, 100_000_000.0, 0.001)
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

    @Test("Both settings cards hand the capped step to the Slider view")
    func settingsCardsUseTheCappedStep() throws {
        for name in ["SceneSettingsCard", "ProjectSettingsCard"] {
            let source = try RepositoryRoot.source(
                "LiveWallpaper/Views/ScreenDetail/\(name).swift"
            )
            #expect(
                source.contains("step: ValueLogic.displaySliderStep(for: property)"),
                "\(name) must hand the Slider view the detent-capped step"
            )
            #expect(
                source.contains("ValueLogic.normalizedSliderValue"),
                "\(name) must still snap writes to the authored step"
            )
        }
    }
}
#endif
