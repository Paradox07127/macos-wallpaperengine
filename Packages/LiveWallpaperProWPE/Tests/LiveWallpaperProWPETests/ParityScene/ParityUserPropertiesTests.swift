import Foundation
import LiveWallpaperCore
@testable import LiveWallpaperProWPE
import XCTest

final class ParityUserPropertiesTests: XCTestCase {
    func testBloomDocumentDeltaAppliesOnlyChangedValidBoolAndPreservesLiveScriptValue() throws {
        let source = #"""
        {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
         "general":{"orthogonalprojection":{"width":32,"height":32},"bloom":{"user":"toggle","value":true}},
         "objects":[{"id":1,"image":"models/surface.json","alpha":{"user":"fade","value":1}}]}
        """#
        func document(_ bloom: WallpaperEngineProjectPropertyValue, alpha: Double = 1) throws -> WPESceneDocument {
            try WPESceneDocumentParser.parse(data: Data(source.utf8),
                                             userValues: ["toggle": bloom, "fade": .number(alpha)],
                                             makeTransformScriptResolver: { _, _ in UserPropertiesNoScripts() })
        }
        let before = try document(.bool(false))
        let enabled = try document(.bool(true))
        XCTAssertEqual(WPEParityUserProperties.bindings(document: before)["toggle"]?.first?.action, .incremental)
        var state = WPEParitySceneState(document: before, hdr: false)
        state.setScriptField("bloom", of: "", to: .vector(.zero), invalidating: .none)
        let constantsGeneration = state.generation(.bloom)
        let enable = try XCTUnwrap(WPEParityUserPropertyUpdate(from: before, to: enabled))
        XCTAssertEqual(enable.sceneBloom, true)
        enable.apply(to: &state)
        XCTAssertEqual(state.scriptField("bloom", of: ""), .vector(SIMD4(1, 0, 0, 0)))

        // A script changed the running field after the document seed. An unrelated fade must not reset it.
        state.setScriptField("bloom", of: "", to: .vector(.zero), invalidating: .none)
        let fieldsGeneration = state.scriptFieldsGeneration
        let faded = try document(.bool(true), alpha: 0.25)
        let unrelated = try XCTUnwrap(WPEParityUserPropertyUpdate(from: enabled, to: faded))
        XCTAssertNil(unrelated.sceneBloom)
        unrelated.apply(to: &state)
        XCTAssertEqual(state.object("1")?.alpha, 0.25)
        XCTAssertEqual(state.scriptField("bloom", of: ""), .vector(.zero))
        XCTAssertEqual(state.scriptFieldsGeneration, fieldsGeneration)

        let invalid = try document(.number(0), alpha: 0.25)
        let reject = try XCTUnwrap(WPEParityUserPropertyUpdate(from: faded, to: invalid))
        XCTAssertNil(reject.sceneBloom)
        reject.apply(to: &state)
        XCTAssertEqual(state.scriptField("bloom", of: ""), .vector(.zero), "Invalid new input must not become defaulttrue")

        // Old invalid is not defaulttrue when comparing: a newly accepted true must still reach the live field.
        let recover = try XCTUnwrap(WPEParityUserPropertyUpdate(from: invalid, to: faded))
        XCTAssertEqual(recover.sceneBloom, true)
        recover.apply(to: &state)
        XCTAssertEqual(state.scriptField("bloom", of: ""), .vector(SIMD4(1, 0, 0, 0)))
        let same = try XCTUnwrap(WPEParityUserPropertyUpdate(from: faded, to: faded))
        XCTAssertNil(same.sceneBloom)
        let recoveredGeneration = state.scriptFieldsGeneration
        same.apply(to: &state)
        XCTAssertEqual(state.scriptFieldsGeneration, recoveredGeneration)
        let string = try document(.string("0"), alpha: 0.25)
        let rejectString = try XCTUnwrap(WPEParityUserPropertyUpdate(from: faded, to: string))
        XCTAssertNil(rejectString.sceneBloom)
        rejectString.apply(to: &state)
        XCTAssertEqual(state.scriptField("bloom", of: ""), .vector(SIMD4(1, 0, 0, 0)))
        XCTAssertEqual(state.generation(.bloom), constantsGeneration, "No Float bloom-constant hook is synthesized")
    }
}

private struct UserPropertiesNoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
