import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityBindingStagePlanTests: XCTestCase {
    typealias Entry = WPEStageReflection.ArgumentEntry

    func reflection(_ entries: [Entry], resources: [WPEStageReflection.Resource] = [],
                    stage: WPEStageReflection.Stage = .vertex, schema: Int = 1) -> WPEStageReflection {
        .init(schema: schema, stage: stage, cbuffers: [], resources: resources, topLevelArgumentBuffer: entries)
    }

    func word(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        (0 ..< 8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
    }

    func testReflectedOffsetsSpacesAndStageIndependence() throws {
        let resources: [WPEStageReflection.Resource] = [
            .init(name: "tex", kind: .texture, register: 2, space: 1, dimension: .texture2D, count: 1),
            .init(name: "smp", kind: .sampler, register: 2, space: 1, dimension: .none, count: 1, comparison: true),
        ]
        let plan = try WPEStageBindingPlan(reflection([
            .init(kind: .sampler, register: 2, space: 1, offset: 104, size: 24),
            .init(kind: .cbv, register: 1, space: 0, offset: 32, size: 24),
            .init(kind: .srv, register: 2, space: 1, offset: 64, size: 24),
            .init(kind: .cbv, register: 1, space: 1, offset: 0, size: 24),
        ], resources: resources))
        XCTAssertEqual(plan.totalSize, 128)
        XCTAssertEqual(plan.cbufferOffset(register: 1), 32)
        XCTAssertEqual(plan.cbufferOffset(register: 1, space: 1), 0)
        XCTAssertEqual(plan.textureOffset(named: "tex"), 64)
        XCTAssertEqual(plan.samplerOffset(named: "smp"), 104)
        XCTAssertNil(plan.offset(kind: .srv, register: 2))
        XCTAssertNil(plan.textureOffset(named: "missing"))
        XCTAssertNil(plan.samplerOffset(named: "smp", element: -1))
        let fragment = try WPEStageBindingPlan(reflection([
            .init(kind: .cbv, register: 1, space: 0, offset: 0, size: 24),
        ], stage: .fragment))
        XCTAssertEqual(fragment.cbufferOffset(register: 1), 0)
        XCTAssertEqual(fragment.stage, .fragment)
        XCTAssertEqual(plan.stage, .vertex)
        XCTAssertEqual(try WPEStageBindingPlan(reflection([])).totalSize, 0)
    }

    func testResourceArrayOffsets() throws {
        let plan = try WPEStageBindingPlan(reflection([
            .init(kind: .srv, register: 4, space: 0, offset: 16, size: 72),
            .init(kind: .sampler, register: 4, space: 0, offset: 88, size: 48),
        ], resources: [
            .init(name: "textures", kind: .texture, register: 4, space: 0, dimension: .texture2DArray, count: 3),
            .init(name: "samplers", kind: .sampler, register: 4, space: 0, dimension: .none, count: 2),
        ]))
        XCTAssertEqual(plan.textureOffset(named: "textures", element: 2), 64)
        XCTAssertEqual(plan.samplerOffset(named: "samplers", element: 1), 112)
        XCTAssertNil(plan.textureOffset(named: "textures", element: 3))
        XCTAssertEqual(plan.totalSize, 136)
    }

    func testDescriptorFieldsMatchMSCRuntimeABI() throws {
        let plan = try WPEStageBindingPlan(reflection([
            .init(kind: .cbv, register: 0, space: 0, offset: 0, size: 24),
            .init(kind: .srv, register: 0, space: 0, offset: 24, size: 24),
            .init(kind: .sampler, register: 0, space: 0, offset: 48, size: 24),
            .init(kind: .uav, register: 0, space: 0, offset: 72, size: 24),
        ]))
        var bytes = [UInt8](repeating: 0xCC, count: 104)
        let address: UInt64 = 0xFEDC_BA98_7654_3210
        let resourceID: UInt64 = 0x8123_4567_89AB_CDEF
        try plan.writeEntry(at: 0, gpuAddress: address, resourceID: 0, metadata: 240, into: &bytes)
        let minLOD = UInt64(Float(2.5).bitPattern)
        try plan.writeEntry(at: 24, gpuAddress: 0, resourceID: resourceID, metadata: minLOD, into: &bytes)
        let lodBias = UInt64(Float(-0.5).bitPattern)
        try plan.writeEntry(at: 48, gpuAddress: resourceID, resourceID: 0, metadata: lodBias, into: &bytes)
        let bufferMetadata: UInt64 = (1 << 63) | (7 << 32) | 1024
        try plan.writeEntry(at: 72, gpuAddress: address, resourceID: resourceID, metadata: bufferMetadata, into: &bytes)
        XCTAssertEqual(word(bytes, at: 0), address)
        XCTAssertEqual(word(bytes, at: 8), 0)
        XCTAssertEqual(word(bytes, at: 16), 240)
        XCTAssertEqual(word(bytes, at: 24), 0)
        XCTAssertEqual(word(bytes, at: 32), resourceID)
        XCTAssertEqual(word(bytes, at: 40), minLOD)
        XCTAssertEqual(word(bytes, at: 48), resourceID)
        XCTAssertEqual(word(bytes, at: 56), 0)
        XCTAssertEqual(word(bytes, at: 64), lodBias)
        XCTAssertEqual(word(bytes, at: 88), bufferMetadata)
        XCTAssertEqual(Array(bytes[0 ..< 8]), [0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0xFE])
        XCTAssertEqual(Array(bytes[96 ..< 104]), Array(repeating: 0xCC, count: 8))
        let before = bytes
        XCTAssertThrowsError(try plan.writeEntry(at: 8, gpuAddress: 0, resourceID: 0, metadata: 0, into: &bytes))
        XCTAssertEqual(bytes, before)
        var short = [UInt8](repeating: 0, count: 95)
        XCTAssertThrowsError(try plan.writeEntry(at: 0, gpuAddress: 0, resourceID: 0, metadata: 0, into: &short))
    }

    func testMalformedPlansAreRejected() throws {
        let valid = Entry(kind: .cbv, register: 0, space: 0, offset: 0, size: 24)
        XCTAssertThrowsError(try WPEStageBindingPlan(reflection([valid], schema: 2)))
        for entry in [Entry(kind: .cbv, register: -1, space: 0, offset: 0, size: 24),
                      Entry(kind: .cbv, register: 0, space: -1, offset: 0, size: 24),
                      Entry(kind: .cbv, register: 0, space: 0, offset: 4, size: 24),
                      Entry(kind: .cbv, register: 0, space: 0, offset: 0, size: 8),
                      Entry(kind: .cbv, register: 0, space: 0, offset: Int.max - 7, size: 24)] {
            XCTAssertThrowsError(try WPEStageBindingPlan(reflection([entry])))
        }
        XCTAssertThrowsError(try WPEStageBindingPlan(reflection([valid, valid])))
        XCTAssertThrowsError(try WPEStageBindingPlan(reflection([
            valid, .init(kind: .srv, register: 0, space: 0, offset: 16, size: 24),
        ])))
        XCTAssertThrowsError(try WPEStageBindingPlan(reflection([
            valid, .init(kind: .cbv, register: 0, space: 0, offset: 24, size: 24),
        ])))
    }

    func testSchemaDecoding() throws {
        let json = #"""
        {"schema":1,"stage":"geometry","entry":"main","cbuffers":[
          {"name":"g_bufDynamic","register":1,"space":0,"size":16,"variables":[
            {"name":"flag","offset":0,"size":4,"baseType":"bool","class":"scalar",
             "rows":1,"columns":1,"elements":0,"used":false}]}],
         "resources":[{"name":"shadow","kind":"sampler","register":0,"space":0,
                       "dimension":"none","count":1,"comparison":true}],
         "topLevelArgumentBuffer":[{"kind":"cbv","register":1,"space":0,"offset":0,"size":24}],
         "vertexInputs":[{"name":"position0","index":0,"elementType":"float","columns":3}],
         "stageOutputs":[],"mscReflection":{"flag":true,"null":null,"id":18446744073709551615,
                                          "array":["s",2,{"v":false}]}}
        """#
        let reflected = try JSONDecoder().decode(WPEStageReflection.self, from: Data(json.utf8))
        XCTAssertEqual(reflected.stage, .geometry)
        XCTAssertEqual(reflected.resources[0].comparison, true)
        XCTAssertEqual(reflected.vertexInputs[0].columns, 3)
        XCTAssertEqual(reflected.mscReflection["flag"], .bool(true))
        XCTAssertEqual(reflected.mscReflection["null"], .null)
        XCTAssertEqual(reflected.mscReflection["id"], .unsignedInteger(.max))
        var packer = try WPECBufferPacker(layout: WPECBufferLayout(reflected.cbuffers[0]))
        try packer.write(true, to: "flag")
        XCTAssertEqual(packer.bytes[0], 1)
        XCTAssertEqual(try WPEStageBindingPlan(reflected).totalSize, 24)
        XCTAssertThrowsError(try JSONDecoder().decode(WPEStageReflection.self,
                                                      from: Data(json.replacingOccurrences(of: "\"geometry\"", with: "\"compute\"").utf8)))
    }
}

/// Saved MSC smoke-test reflections from <private-notes>
extension ParityBindingStagePlanTests {
    private func planFromMSC(_ json: String, stage: WPEStageReflection.Stage) throws -> WPEStageBindingPlan {
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let entries = try XCTUnwrap(raw["TopLevelArgumentBuffer"] as? [[String: Any]])
        let normalized = try entries.map { entry -> [String: Any] in
            let kind = try XCTUnwrap(entry["Type"] as? String).lowercased()
            return try ["kind": kind, "register": XCTUnwrap(entry["Slot"]),
                        "space": XCTUnwrap(entry["Space"]), "offset": XCTUnwrap(entry["EltOffset"]),
                        "size": XCTUnwrap(entry["Size"])]
        }
        var resources: [[String: Any]] = []
        if stage == .fragment {
            for index in 0 ..< 4 {
                resources.append(["name": "g_Texture\(index)", "kind": "texture", "register": index,
                                  "space": 0, "dimension": "2d", "count": 1])
                resources.append(["name": "g_Texture\(index)SamplerState", "kind": "sampler", "register": index,
                                  "space": 0, "dimension": "none", "count": 1])
            }
        }
        let schema: [String: Any] = ["schema": 1, "stage": stage.rawValue, "entry": "main", "cbuffers": [],
                                     "resources": resources, "topLevelArgumentBuffer": normalized,
                                     "vertexInputs": [], "stageOutputs": [], "mscReflection": raw]
        let data = try JSONSerialization.data(withJSONObject: schema)
        return try WPEStageBindingPlan(JSONDecoder().decode(WPEStageReflection.self, from: data))
    }

    func testExampleMSCVertexReflection() throws {
        let json = #"""
        {"ConstantBufferIndices":[65535,0],"EntryPoint":"main","Features":0,"FunctionConstants":[],"HasYieldLoop":false,"NeedsFunctionConstants":false,"ResourceCount":1,"ResourceUsages":0,"SamplerIndices":[],"ShaderID":"6365635226561051884","ShaderResourceViewIndices":[],"ShaderType":"Vertex","TopLevelArgumentBuffer":[{"EltOffset":0,"Name":"","Size":24,"Slot":1,"Space":0,"Type":"CBV"}],"UnorderedAccessViewIndices":[],"UsedResources":[{"bindingIndex":0,"isInGRS":true,"tableLength":1,"tableStartIndex":4294967295}],"UsesRayQuery":false,"state":{"instance_id_index":5,"max_primitives_per_mesh_threadgroup":0,"needs_draw_params":false,"vertex_id_index":4,"vertex_inputs":[{"columnCount":3,"elementType":"Float","index":0,"name":"position0"},{"columnCount":3,"elementType":"Float","index":1,"name":"normal0"},{"columnCount":4,"elementType":"Float","index":2,"name":"texcoord0"},{"columnCount":4,"elementType":"Float","index":3,"name":"tangent0"}],"vertex_output_size_in_bytes":128,"vertex_outputs":[{"columnCount":3,"elementType":"Float","index":1,"name":"texcoord0"},{"columnCount":4,"elementType":"Float","index":2,"name":"texcoord1"},{"columnCount":4,"elementType":"Float","index":3,"name":"texcoord2"},{"columnCount":4,"elementType":"Float","index":4,"name":"texcoord3"},{"columnCount":4,"elementType":"Float","index":5,"name":"texcoord4"},{"columnCount":3,"elementType":"Float","index":6,"name":"texcoord5"},{"columnCount":3,"elementType":"Float","index":7,"name":"texcoord6"},{"columnCount":4,"elementType":"Float","index":8,"name":"sv_position0"}]}}
        """#
        let plan = try planFromMSC(json, stage: .vertex)
        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertEqual(plan.cbufferOffset(register: 1), 0)
        XCTAssertNil(plan.cbufferOffset(register: 0))
        XCTAssertEqual(plan.totalSize, 24)
        var bytes = [UInt8](repeating: 0, count: plan.totalSize)
        try plan.writeEntry(at: 0, gpuAddress: 0x1234_5678_9ABC_DEF0, resourceID: 0, metadata: 240, into: &bytes)
        XCTAssertEqual(word(bytes, at: 0), 0x1234_5678_9ABC_DEF0)
        XCTAssertEqual(word(bytes, at: 8), 0)
        XCTAssertEqual(word(bytes, at: 16), 240)
        XCTAssertThrowsError(try plan.writeEntry(at: 24, gpuAddress: 0, resourceID: 0, metadata: 0, into: &bytes))
    }

    func testExampleMSCFragmentReflection() throws {
        let json = #"""
        {"ConstantBufferIndices":[4,5],"EntryPoint":"main","Features":0,"FunctionConstants":[],"HasYieldLoop":false,"NeedsFunctionConstants":false,"ResourceCount":10,"ResourceUsages":8,"SamplerIndices":[6,7,8,9],"ShaderID":"2139527585474030360","ShaderResourceViewIndices":[0,1,2,3],"ShaderType":"Fragment","TopLevelArgumentBuffer":[{"EltOffset":0,"Name":"","Size":24,"Slot":0,"Space":0,"Type":"SRV"},{"EltOffset":24,"Name":"","Size":24,"Slot":1,"Space":0,"Type":"SRV"},{"EltOffset":48,"Name":"","Size":24,"Slot":2,"Space":0,"Type":"SRV"},{"EltOffset":72,"Name":"","Size":24,"Slot":3,"Space":0,"Type":"SRV"},{"EltOffset":96,"Name":"","Size":24,"Slot":0,"Space":0,"Type":"CBV"},{"EltOffset":120,"Name":"","Size":24,"Slot":1,"Space":0,"Type":"CBV"},{"EltOffset":144,"Name":"","Size":24,"Slot":0,"Space":0,"Type":"Sampler"},{"EltOffset":168,"Name":"","Size":24,"Slot":1,"Space":0,"Type":"Sampler"},{"EltOffset":192,"Name":"","Size":24,"Slot":2,"Space":0,"Type":"Sampler"},{"EltOffset":216,"Name":"","Size":24,"Slot":3,"Space":0,"Type":"Sampler"}],"UnorderedAccessViewIndices":[],"UsedResources":[{"bindingIndex":0,"isInGRS":true,"tableLength":1,"tableStartIndex":4294967295},{"bindingIndex":1,"isInGRS":true,"tableLength":1,"tableStartIndex":4294967295},{"bindingIndex":2,"isInGRS":true,"tableLength":1,"tableStartIndex":4294967295},{"bindingIndex":3,"isInGRS":true,"tableLength":1,"tableStartIndex":4294967295},{"bindingIndex":4,"isInGRS":true,"tableLength":1,"tableStartIndex":4294967295},{"bindingIndex":5,"isInGRS":true,"tableLength":1,"tableStartIndex":4294967295},{"bindingIndex":6,"isInGRS":true,"tableLength":1,"tableStartIndex":4294967295},{"bindingIndex":7,"isInGRS":true,"tableLength":1,"tableStartIndex":4294967295},{"bindingIndex":8,"isInGRS":true,"tableLength":1,"tableStartIndex":4294967295},{"bindingIndex":9,"isInGRS":true,"tableLength":1,"tableStartIndex":4294967295}],"UsesRayQuery":false,"state":{"discards":false,"num_render_targets":1,"rt_index_int":0}}
        """#
        let plan = try planFromMSC(json, stage: .fragment)
        XCTAssertEqual(plan.entries.count, 10)
        XCTAssertEqual(plan.totalSize, 240)
        XCTAssertEqual(plan.cbufferOffset(register: 0), 96)
        XCTAssertEqual(plan.cbufferOffset(register: 1), 120)
        for index in 0 ..< 4 {
            XCTAssertEqual(plan.textureOffset(named: "g_Texture\(index)"), index * 24)
            XCTAssertEqual(plan.samplerOffset(named: "g_Texture\(index)SamplerState"), 144 + index * 24)
        }
        XCTAssertNil(plan.textureOffset(named: "g_Texture4"))
    }
}
