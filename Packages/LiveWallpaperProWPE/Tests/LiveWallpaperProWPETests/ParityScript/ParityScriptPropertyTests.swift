import Foundation
import LiveWallpaperProWPE
import XCTest

final class ParityScriptPropertyTests: XCTestCase {
    private typealias Property = WPEParityScriptProperty

    private static func state() throws -> WPEParitySceneState {
        let scene: [String: Any] = ["camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
                                    "general": ["orthogonalprojection": ["width": 100, "height": 100]],
                                    "objects": [
                                        ["id": 1, "name": "A", "image": "models/a.json", "size": "10 10",
                                         "effects": [["id": 5, "file": "effects/x.json", "visible": true]]],
                                    ]]
        let document = try WPESceneDocumentParser.parse(
            data: JSONSerialization.data(withJSONObject: scene), userValues: [:],
            makeTransformScriptResolver: { _, _ in NoScripts() }
        )
        return WPEParitySceneState(document: document, hdr: false,
                                   constants: [WPEParityMaterialPassKey(objectID: "1", effectID: "5"): ["k": [0, 0]]])
    }

    private static func row(_ name: String, in table: [Property]) -> Property {
        table.first { $0.name == name }!
    }

    /// Each row of R25 §2: the written field and the counter its hook moves.
    func testEachWriteBackRowLandsInItsFieldAndInvalidation() throws {
        var state = try Self.state()
        func check(_ property: Property, _ value: WPEParitySceneState.ScriptValue, effect: String? = nil,
                   pass: WPEParityMaterialPassKey? = nil, objectID: String = "1",
                   expect invalidation: WPEParitySceneState.Invalidation, line: UInt = #line) {
            XCTAssertEqual(property.invalidation, invalidation, property.name, line: line)
            let before = WPEParitySceneState.Invalidation.allCases.map(state.generation)
            property.write(value, objectID: objectID, effectID: effect, pass: pass, to: &state)
            let after = WPEParitySceneState.Invalidation.allCases.map(state.generation)
            for kind in WPEParitySceneState.Invalidation.allCases where kind != .none {
                XCTAssertEqual(after[kind.rawValue] - before[kind.rawValue], kind == invalidation ? 1 : 0,
                               "\(property.name) \(kind)", line: line)
            }
            XCTAssertEqual(property.read(objectID: objectID, effectID: effect, pass: pass, from: state), value,
                           property.name, line: line)
        }
        let vector = WPEParitySceneState.ScriptValue.vector(SIMD4(3, 4, 5, 0))
        let scalar = WPEParitySceneState.ScriptValue.vector(SIMD4(0.25, 0, 0, 0))
        check(Self.row("origin", in: Property.base), vector, expect: .transform)
        check(Self.row("scale", in: Property.base), .vector(SIMD4(2, 2, 2, 0)), expect: .transform)
        check(Self.row("angles", in: Property.base), .vector(SIMD4(0, 0, 90, 0)), expect: .transform)
        check(Property.visible, .vector(.zero), expect: .visibility)
        check(Self.row("alpha", in: Property.image), scalar, expect: .none)
        check(Self.row("color", in: Property.image), .vector(SIMD4(0.5, 0.25, 1, 0)), expect: .none)
        check(Self.row("brightness", in: Property.image), scalar, expect: .none)
        check(Self.row("size", in: Property.image), .vector(SIMD4(20, 30, 0, 0)), expect: .none)
        try check(XCTUnwrap(Property.material(name: "k", components: 2)), .vector(SIMD4(1, 2, 0, 0)),
                  pass: WPEParityMaterialPassKey(objectID: "1", effectID: "5"), expect: .materialConstants)
        check(Property.effectVisible, .vector(.zero), effect: "5", expect: .effectPasses)
        check(Self.row("bloomStrength", in: Property.scene), scalar, objectID: "", expect: .bloom)
        check(Self.row("ambientColor", in: Property.scene), vector, objectID: "", expect: .lighting)
        check(Self.row("count", in: Property.particleInstance), scalar, expect: .particleInstance)
        check(Self.row("rate", in: Property.particleInstance), scalar, expect: .none)
        check(Self.row("fov", in: Property.camera), scalar, expect: .none)
        check(Self.row("text", in: Property.text), .string("12:34"), expect: .textLayout)
        check(Self.row("rate", in: Property.video), scalar, expect: .mediaPlayer)
        check(Self.row("volume", in: Property.sound), scalar, expect: .soundGain)
        XCTAssertEqual(state.scriptField("instance.rate", of: "1"), scalar)
        XCTAssertEqual(state.scriptField("video.rate", of: "1"), scalar)
    }

    /// Flag 4 stores radians: a script's 90° lands as 90 × DAT_140492628; writes overwrite.
    func testAngleFlagStoresRadiansAndWritesOverwrite() throws {
        var state = try Self.state()
        let angles = Self.row("angles", in: Property.base)
        angles.write(.vector(SIMD4(0, 0, 90, 0)), objectID: "1", to: &state)
        XCTAssertEqual(state.object("1")?.angles.z, 90 * Property.degreesToRadians)
        angles.write(.vector(SIMD4(0, 0, 45, 0)), objectID: "1", to: &state)
        XCTAssertEqual(state.object("1")?.angles.z, 45 * Property.degreesToRadians)
        XCTAssertEqual(Property.degreesToRadians.bitPattern, 0x3C8E_FA35)
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
