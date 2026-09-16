#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Metal
import simd
import Testing

/// Pins Swift `WPESceneModelMeshUniforms` to the MSL struct byte for byte. The struct block is cut
/// out of `WPEMetalBuiltins.metal` at test time and compiled into a compute probe, so a field added,
/// moved or retyped on only one side fails here instead of silently misreading GPU memory.
@Suite("WPESceneModelMeshUniforms layout")
struct WPESceneModelMeshUniformsLayoutTests {
    private static let structName = "WPESceneModelMeshUniforms"

    @Test("Field order, stride and every field offset match the MSL struct compiled from the .metal source")
    func swiftLayoutMatchesMSL() throws {
        let swiftOffsets: [String: PartialKeyPath<WPESceneModelMeshUniforms>] = [
            "modelViewProjectionMatrix": \.modelViewProjectionMatrix,
            "modelMatrix": \.modelMatrix,
            "viewProjectionMatrix": \.viewProjectionMatrix,
            "normalMatrix": \.normalMatrix,
            "modeAndPadding": \.modeAndPadding,
            "eyeAndPadding": \.eyeAndPadding,
        ]
        let metal = try RepositoryRoot.source("LiveWallpaper/Runtime/Metal/WPEMetalBuiltins.metal")
        let block = try #require(Self.structBlock(named: Self.structName, in: metal))
        let mslFields = Self.fieldNames(in: block)
        #expect(mslFields.count >= 5)

        let zero = WPESceneModelMeshUniforms(
            modelViewProjectionMatrix: matrix_identity_float4x4,
            modelMatrix: matrix_identity_float4x4,
            viewProjectionMatrix: matrix_identity_float4x4,
            normalMatrix: matrix_identity_float3x3,
            modeAndPadding: .zero,
            eyeAndPadding: .zero
        )
        let swiftFields = Mirror(reflecting: zero).children.compactMap(\.label)
        #expect(swiftFields == mslFields, "Swift declaration order \(swiftFields) vs MSL \(mslFields)")

        // o[0] = sizeof, o[i + 1] = offsetof(field i) in MSL declaration order.
        let offsetLines = mslFields.enumerated().map { index, field in
            "    o[\(index + 1)] = __builtin_offsetof(\(Self.structName), \(field));"
        }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        \(block)
        kernel void abi(device uint* o [[buffer(0)]]) {
            o[0] = sizeof(\(Self.structName));
        \(offsetLines.joined(separator: "\n"))
        }
        """
        let gpu = try Self.runProbe(source: source, resultCount: mslFields.count + 1)

        #expect(gpu[0] == MemoryLayout<WPESceneModelMeshUniforms>.stride,
                "MSL sizeof \(gpu[0]) vs Swift stride \(MemoryLayout<WPESceneModelMeshUniforms>.stride)")
        for (index, field) in mslFields.enumerated() {
            let keyPath = try #require(swiftOffsets[field], "no Swift key path registered for MSL field \(field)")
            let swiftOffset = try #require(MemoryLayout<WPESceneModelMeshUniforms>.offset(of: keyPath))
            #expect(gpu[index + 1] == swiftOffset, "\(field): MSL offset \(gpu[index + 1]) vs Swift \(swiftOffset)")
        }
    }

    private static func structBlock(named name: String, in source: String) -> String? {
        guard let start = source.range(of: "struct \(name) {"),
              let end = source.range(of: "};", range: start.upperBound ..< source.endIndex) else {
            return nil
        }
        return String(source[start.lowerBound ..< end.upperBound])
    }

    /// `type name;` declarations, comments stripped, in declaration order.
    private static func fieldNames(in block: String) -> [String] {
        block.split(separator: "\n").compactMap { line in
            let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = code.split(whereSeparator: { $0 == " " || $0 == ";" || $0 == "\t" })
            guard parts.count == 2, !code.contains("{"), !code.contains("}") else { return nil }
            return String(parts[1])
        }
    }

    private static func runProbe(source: String, resultCount: Int) throws -> [Int] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: source, options: nil)
        let function = try #require(library.makeFunction(name: "abi"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let buffer = try #require(device.makeBuffer(length: resultCount * 4, options: .storageModeShared))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.error == nil)
        let values = buffer.contents().bindMemory(to: UInt32.self, capacity: resultCount)
        return (0 ..< resultCount).map { Int(values[$0]) }
    }
}
#endif
