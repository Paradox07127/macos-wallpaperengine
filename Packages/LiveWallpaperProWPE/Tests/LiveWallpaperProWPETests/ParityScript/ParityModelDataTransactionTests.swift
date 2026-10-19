import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityModelDataTransactionTests: XCTestCase {
    /// CPU ownership only: a prepared marker stands for an immutable resource version. Actual Metal allocation,
    /// submitted readers, pixels and buffer retirement require the app's product guard.
    func testMaterialObserverKeepsErrorPrefixAndParsedAppendPreservesRetiredSlots() throws {
        let initial = try Self.document([["id": 1, "image": "models/a.json"]])
        var state = WPEParitySceneState(document: initial, hdr: false)
        var shape = WPEParityModelDataShapePatch()
        shape.vertices = Self.bytes([Float(0), 0, 0, 1, 0, 0, 0, 1, 0])
        shape.vertexFormat = 1
        shape.indices = .buffer(.init(data: Self.bytes([UInt16(0), 1, 2]), elementWidth: .uint16))
        shape.material = Data("materials/first.json".utf8)
        shape.isVertexBufferDynamic = true
        shape.isIndexBufferDynamic = true
        let first = CPUPreparedShape(tag: 0)
        let token = try state.createModelData(.init(shapes: [shape], bounds: nil), admitShape: { _, _ in first })
        let held = try XCTUnwrap(state.modelData(token)?.shapes.first)
        var patch = WPEParityModelDataShapePatch()
        patch.material = Data("materials/second.json".utf8)
        patch.vertices = Self.bytes([Float(7), 0, 0, 1, 0, 0, 0, 1, 0])
        patch.indices = .buffer(.init(data: Self.bytes([UInt32(0), 1, 2]), elementWidth: .uint32))
        let vertices = CPUPreparedShape(tag: 1)
        let material = CPUPreparedShape(tag: 2)
        var observed: [Int] = []
        XCTAssertThrowsError(try state.updateModelData(token, patch: .init(shapes: [patch], bounds: nil), replacing: true,
                                                       admitShape: { value, mutation in
                                                           switch mutation {
                                                           case .vertices:
                                                               XCTAssertTrue(value.prepared === first)
                                                               observed.append(1)
                                                               return vertices
                                                           case let .material(actualToken, index):
                                                               XCTAssertEqual(actualToken, token)
                                                               XCTAssertEqual(index, 0)
                                                               XCTAssertTrue(value.prepared === vertices)
                                                               XCTAssertEqual(value.material, patch.material)
                                                               observed.append(2)
                                                               return material
                                                           default: XCTFail("Unexpected mutation"); return nil
                                                           }
                                                       })) { error in
            XCTAssertEqual(error as? WPEParityModelDataFailure, .native(9))
        }
        XCTAssertEqual(observed, [1, 2], "the material observer consumes the completed VB prefix after IB rejection")
        let updated = try XCTUnwrap(state.modelData(token)?.shapes.first)
        XCTAssertTrue(updated.prepared === material)
        XCTAssertEqual(updated.indices?.elementWidth, .uint16)
        XCTAssertEqual(updated.vertices.data, patch.vertices)
        XCTAssertTrue(held.prepared === first, "a previous reader owns its exact old version")
        var materialOnly = WPEParityModelDataShapePatch()
        materialOnly.material = Data("materials/unavailable.json".utf8)
        XCTAssertThrowsError(try state.updateModelData(token, patch: .init(shapes: [materialOnly], bounds: nil), replacing: true,
                                                       admitShape: { _, _ in throw WPEParityModelDataFailure.native(1) }))
        XCTAssertEqual(state.modelData(token)?.shapes.first?.material, materialOnly.material)
        XCTAssertNil(state.modelData(token)?.shapes.first?.prepared, "failed material preparation cannot draw the previous program")
        XCTAssertTrue(state.removeObject("1"))
        let parsed = try Self.document([["id": 42, "name": "dynamic", "model": token,
                                         "origin": "7 8 9", "scale": "2 3 4", "angles": "0 0 0", "visible": true]])
        let descriptor = try XCTUnwrap(parsed.modelDataObjects.first)
        XCTAssertTrue(parsed.imageObjects.isEmpty, "a numeric model is never a fabricated image filename")
        try state.appendModelDataLayer(descriptor)
        XCTAssertEqual(state.ids, ["1", "42"])
        XCTAssertNil(state.index(of: "1"))
        XCTAssertFalse(state.objects[0].alive)
        XCTAssertEqual(state.commonOrder, ["42"])
        XCTAssertEqual(state.object("42")?.origin, SIMD3(7, 8, 9))
        XCTAssertEqual(state.object("42")?.scale, SIMD3(2, 3, 4))
        XCTAssertEqual(state.object("42")?.modelDataToken, token)
        XCTAssertEqual(state.modelData(token)?.references, 2)
        state.releaseModelData(token)
        XCTAssertEqual(state.modelData(token)?.references, 1)
        XCTAssertTrue(state.removeObject("42"))
        XCTAssertEqual(state.modelData(token)?.references, 1, "common membership alone is not the class destructor")
        state.releaseLayerModelData("42")
        XCTAssertNil(state.modelData(token))
        XCTAssertTrue(held.prepared === first)
    }

    private static func bytes(_ values: [some Any]) -> Data {
        values.withUnsafeBytes { Data($0) }
    }

    private static func document(_ objects: [[String: Any]]) throws -> WPESceneDocument {
        let source: [String: Any] = ["camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
                                     "general": ["orthogonalprojection": ["width": 64, "height": 64]], "objects": objects]
        return try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: source), userValues: [:])
    }
}

private final class CPUPreparedShape: WPEParityModelDataPreparedShape {
    let tag: Int
    let vertexFormat: UInt32 = 1
    let vertexCount = 3
    let indexElementWidth: WPEPuppetIndexElementWidth? = .uint16
    let indexCount = 3

    init(tag: Int) {
        self.tag = tag
    }
}
