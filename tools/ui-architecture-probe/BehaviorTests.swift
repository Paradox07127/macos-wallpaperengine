import AppKit
import LiveWallpaperCore
import SwiftUI
import XCTest

final class ProbeBehaviorTests: XCTestCase {
    func testAuthoredGridRemainsReachable() throws {
        let schema = try parsed()
        for p in schema.properties where p.type == .slider {
            let r = PropertyValueLogic.sliderRange(for: p)
            let step = PropertyValueLogic.sliderStep(for: p)
            for i in [0.0, 1, 2, 17] {
                let value = min(r.upperBound, r.lowerBound + i * step)
                XCTAssertEqual(PropertyValueLogic.normalizedSliderValue(value, for: p), value, accuracy: max(step * 1e-6, 1e-7))
            }
        }
    }

    func testSweep1000MatchesCurrent() throws {
        for id in ["3351072238", "3369989878", "3509243656"] {
            for p in try parsed(id).properties where p.type == .slider {
                let a = PropertyValueLogic.sliderStep(for: p), r = PropertyValueLogic.sliderRange(for: p)
                let mirrored = a * max(1, ((r.upperBound - r.lowerBound) / 999 / a).rounded(.up))
                XCTAssertEqual(mirrored, PropertyValueLogic.displaySliderStep(for: p), accuracy: 1e-7)
            }
        }
    }

    @MainActor func testNativeKeyboardUsesAuthoredStep() throws {
        let slider = PrecisionSlider(); slider.minValue = 100; slider.maxValue = 300; slider.authoredStep = 0.001; slider.doubleValue = 123.456
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        slider.keyDown(with: event)
        XCTAssertEqual(slider.doubleValue, 123.457, accuracy: 1e-9)
    }

    @MainActor func testNativeAXIncrementAndDecrement() {
        let slider = PrecisionSlider(); slider.minValue = -10; slider.maxValue = 10; slider.authoredStep = 0.001; slider.doubleValue = 0
        XCTAssertTrue(slider.accessibilityPerformIncrement()); XCTAssertEqual(slider.doubleValue, 0.001, accuracy: 1e-9)
        XCTAssertTrue(slider.accessibilityPerformDecrement()); XCTAssertEqual(slider.doubleValue, 0, accuracy: 1e-9)
    }

    @MainActor func testNativeClampsAndCommitsOncePerKey() {
        let slider = PrecisionSlider(); slider.minValue = 100; slider.maxValue = 200; slider.authoredStep = 0.001; slider.doubleValue = 200
        var commits = 0; slider.commit = { commits += 1 }; slider.advance(1)
        XCTAssertEqual(slider.doubleValue, 200); XCTAssertEqual(commits, 1)
        slider.doubleValue = 100; slider.advance(-1); XCTAssertEqual(slider.doubleValue, 100); XCTAssertEqual(commits, 2)
    }

    func testPresentationGroupRoundTripPreservesValues() throws {
        let schema = try parsed(); let presentation = WPEProjectSettingsPresentation(schema: schema, overrides: [:], excludedKeys: ["schemecolor"])
        let expanded = presentation.rows(expandedSectionIDs: Set(presentation.sections.map(\.id)))
        XCTAssertFalse(expanded.isEmpty)
        let collapsed = presentation.rows(expandedSectionIDs: [])
        XCTAssertLessThanOrEqual(collapsed.count, expanded.count)
        XCTAssertEqual(presentation.values, schema.defaultValues)
    }

    @MainActor func testGIFLRUEvictsAtNineClients() {
        let coordinator = GIFPlaybackCoordinator()
        var frozen = 0
        for _ in 0 ..< 9 {
            coordinator.requestPlayback(id: UUID()) { frozen += 1 }
        }
        XCTAssertEqual(frozen, 1)
    }

    func testGIFPlaybackGateBlocksHiddenReducedAndBlurred() {
        var gate = ThumbnailPlaybackGate(isVisible: true, isHovered: true, reduceMotion: false, isBlurred: false, trigger: .hover)
        XCTAssertTrue(gate.allowsPlayback)
        gate.reduceMotion = true; XCTAssertFalse(gate.allowsPlayback)
        gate.reduceMotion = false; gate.hostIsPresented = false; XCTAssertFalse(gate.allowsPlayback)
        gate.hostIsPresented = true; gate.isBlurred = true; XCTAssertFalse(gate.allowsPlayback)
        gate.isBlurred = false; gate.isVisible = false; XCTAssertFalse(gate.allowsPlayback)
    }

    private func parsed(_ id: String = "3351072238") throws -> WallpaperEngineProjectPropertySchema {
        let url = URL(fileURLWithPath: "/Users/taijial/Library/Application Support/Steam/steamapps/workshop/content/431960/\(id)/project.json")
        return try WallpaperEngineProjectPropertySchema.parse(data: Data(contentsOf: url), preferredLanguages: ["en"])
    }
}
