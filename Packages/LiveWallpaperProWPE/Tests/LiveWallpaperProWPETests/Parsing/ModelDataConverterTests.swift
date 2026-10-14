import Foundation
import JavaScriptCore
@testable import LiveWallpaperProWPE
import XCTest

final class ModelDataConverterTests: XCTestCase {
    func testOriginalTypedViewsPreserveWordsWidthsAndPatchSentinels() throws {
        let context = try XCTUnwrap(JSContext())
        let input = try XCTUnwrap(context.evaluateScript(#"""
        const words = new Uint32Array([99, 0x3f800000, 0x7fc12345, 0x80000000,
            0x40000000, 0x40400000, 0x40800000, 0x40a00000, 0x40c00000, 0x40e00000, 99]);
        const wide = new Uint32Array([99, 65536, 2, 0, 99]);
        const small = new Uint16Array([99, 0, 1, 2, 99]);
        const first = {vertexBuffer: new Float32Array(words.buffer, 4, 9),
            indexBuffer: new Uint32Array(wide.buffer, 4, 3),
            vertexFormat: ['unknown', 'position', 'position\0ignored'], material: 'materials/a',
            isVertexBufferDynamic: true, isIndexBufferDynamic: false};
        first;
        """#))
        let patch = try convert(input, required: true)
        let first = try XCTUnwrap(patch.shapes.first)
        XCTAssertEqual(first.vertices, data([0x3F80_0000, 0x7FC1_2345, 0x8000_0000, 0x4000_0000, 0x4040_0000,
                                             0x4080_0000, 0x40A0_0000, 0x40C0_0000, 0x40E0_0000] as [UInt32]))
        XCTAssertEqual(first.vertexStream?.vertexCount, 3)
        XCTAssertEqual(first.vertexStream?.layout.stride, 12)
        guard case let .buffer(wide) = first.indices else { return XCTFail("original Uint32Array view missing") }
        XCTAssertEqual(wide.elementWidth, .uint32)
        XCTAssertEqual(wide.count, 3)
        XCTAssertEqual(wide.data, data([65536, 2, 0] as [UInt32]))
        XCTAssertEqual(first.isVertexBufferDynamic, true)
        XCTAssertEqual(first.isIndexBufferDynamic, false)
        let partial = try XCTUnwrap(context.evaluateScript(#"""
        ({shapes: [undefined, null, {indexBuffer: null, isVertexBufferDynamic: 1, isIndexBufferDynamic: false},
            {indexBuffer: new Uint16Array(small.buffer, 2, 3), vertexFormat: ['uv', 'normal', 'position', 'uv']}],
          boundingBoxMins: {x: -1, y: '2', z: -3}, boundingBoxMaxs: {x: 1, y: 2, z: 3}});
        """#))
        let updates = try convert(partial, required: false)
        XCTAssertEqual(updates.shapes.count, 4)
        XCTAssertFalse(updates.shapes[0].remove)
        XCTAssertTrue(updates.shapes[1].remove)
        XCTAssertEqual(updates.shapes[2].indices, .remove)
        XCTAssertNil(updates.shapes[2].isVertexBufferDynamic)
        XCTAssertEqual(updates.shapes[2].isIndexBufferDynamic, false)
        guard case let .buffer(small) = updates.shapes[3].indices else { return XCTFail("original Uint16Array view missing") }
        XCTAssertEqual(small.elementWidth, .uint16)
        XCTAssertEqual(small.data, data([0, 1, 2] as [UInt16]))
        XCTAssertEqual(updates.shapes[3].vertexFormat, 0xB)
        XCTAssertEqual(updates.bounds?.minimum, SIMD3(-1, 0, -3))
        XCTAssertEqual(updates.bounds?.maximum, SIMD3(1, 2, 3))
        let normal = try XCTUnwrap(context.evaluateScript("({vertexBuffer: new Float32Array(3), vertexFormat: ['normal']})"))
        let nativeLayout = try XCTUnwrap(convert(normal, required: false).shapes.first?.vertexStream?.layout)
        XCTAssertEqual(nativeLayout.stride, 12)
        XCTAssertEqual(nativeLayout.attributes.map(\.semantic), ["NORMAL"])
        XCTAssertFalse(nativeLayout.hasSyntheticPosition)
        let noBounds = try XCTUnwrap(context.evaluateScript("({get boundingBoxMaxs() {throw Error('maxs must not be read');}})"))
        XCTAssertNil(try convert(noBounds, required: false).bounds)
    }

    func testGetterExceptionIdentityAndOwnerBudgetsRemainEffective() throws {
        let context = try XCTUnwrap(JSContext())
        let input = try XCTUnwrap(context.evaluateScript("const originalError = {marker: 17}; ({get vertexBuffer() {throw originalError;}});"))
        XCTAssertThrowsError(try convert(input, required: true)) {
            XCTAssertEqual($0 as? WPEModelDataConverter.Failure, .javascriptException)
        }
        let caught = try XCTUnwrap(context.exception)
        context.exception = nil
        context.setObject(caught, forKeyedSubscript: "caught" as NSString)
        XCTAssertEqual(context.evaluateScript("caught === originalError")?.toBool(), true)
        let sparse = try XCTUnwrap(context.evaluateScript("({shapes: new Array(1024)})"))
        XCTAssertThrowsError(try convert(sparse, required: false)) {
            XCTAssertEqual($0 as? WPEModelDataConverter.Failure, .shapeLimitExceeded)
        }
        let buffer = try XCTUnwrap(context.evaluateScript("({vertexBuffer: new Float32Array(4)})"))
        XCTAssertThrowsError(try WPEModelDataConverter.convert(buffer, requireFields: false, maximumArrayEntries: 16,
                                                               maximumBufferBytes: 4, resolveMaterial: { _ in Data() })) {
            XCTAssertEqual($0 as? WPEModelDataConverter.Failure, .bufferLimitExceeded)
        }
        let pair = try XCTUnwrap(context.evaluateScript("({vertexBuffer:new Float32Array(4),indexBuffer:new Uint32Array(4)})"))
        let admitted = try WPEModelDataConverter.convert(pair, requireFields: false, maximumArrayEntries: 16,
                                                         maximumBufferBytes: Int.max, maximumSingleBufferBytes: 16,
                                                         resolveMaterial: { _ in Data() })
        XCTAssertEqual(admitted.shapes.first?.vertices?.count, 16)
        guard case let .buffer(indices)? = admitted.shapes.first?.indices else {
            return XCTFail("two separately admitted buffers must not become one aggregate device cap")
        }
        XCTAssertEqual(indices.data.count, 16)
        XCTAssertThrowsError(try WPEModelDataConverter.convert(pair, requireFields: false, maximumArrayEntries: 16,
                                                               maximumBufferBytes: Int.max, maximumSingleBufferBytes: 15,
                                                               resolveMaterial: { _ in Data() })) {
            XCTAssertEqual($0 as? WPEModelDataConverter.Failure, .singleBufferLimitExceeded)
        }
    }

    private func convert(_ value: JSValue, required: Bool) throws -> WPEParityModelDataPatch {
        try WPEModelDataConverter.convert(value, requireFields: required, maximumArrayEntries: 16,
                                          maximumBufferBytes: 4096, resolveMaterial: { Data($0.toString().utf8) })
    }

    private func data(_ values: [some FixedWidthInteger]) -> Data {
        values.reduce(into: Data()) { result, value in
            withUnsafeBytes(of: value.littleEndian) { result.append(contentsOf: $0) }
        }
    }
}
