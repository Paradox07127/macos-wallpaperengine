#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import XCTest

/// The audio-shader scan of a plan against a String search of every stage.
extension WPEParitySceneDriverTests {
    func testAudioScanMatchesTheStringSearchOverRealScenes() throws {
        var verdicts: [String: Bool] = [:]
        var programOnly = false
        for id in ["3815666789", "3660962877", "3509243656"] {
            let (document, assets) = try sceneInputs(sceneID: id)
            let plan = try WPEParityFramePlan(
                document: document, assets: assets,
                settings: WPEParityProgramSettings(bloom: true, hdrPostProcessing: true, msaa: true),
                width: 1920, height: 1080
            )
            let expected = Self.stringSearchReadsAudio(plan)
            XCTAssertEqual(WPEParitySceneDriver.readsAudio(plan), expected, id)
            verdicts[id] = expected
            programOnly = programOnly || (expected && !document.general.supportsAudioProcessing)
        }
        XCTAssertTrue(verdicts.values.contains(false), "\(verdicts)")
        XCTAssertTrue(programOnly, "no scene reads audio through its shaders alone: \(verdicts)")
    }

    /// The scan as it decoded every stage to a String.
    private static func stringSearchReadsAudio(_ plan: WPEParityFramePlan) -> Bool {
        plan.document.general.supportsAudioProcessing || plan.programs.values.contains { program in
            [program.hlsl.vertex, program.hlsl.geometry, program.hlsl.fragment].contains { stage in
                stage.flatMap { String(bytes: $0, encoding: .utf8) }?.contains("g_AudioSpectrum") == true
            }
        }
    }
}
#endif
