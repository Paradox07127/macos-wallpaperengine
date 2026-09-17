#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Metal
import simd
import Testing

@Suite("WPE bone normal deformation", .serialized)
struct WPEBoneNormalDeformationTests {
    struct Case {
        let name: String
        let bones: [simd_float4x4]
        var weights = SIMD4<Float>(1, 0, 0, 0)
        var indices = SIMD4<UInt32>(0, 1, 0, 0)
        var singular = false
    }

    @Test("Production skin normal stays perpendicular to the actual skinned tangent", arguments: [false, true])
    func blendedInverseTranspose(fast: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try RepositoryRoot.source("LiveWallpaper/Runtime/Metal/WPEMetalBuiltins.metal") + "\n" + """
        kernel void boneNormalProbe(constant WPEPuppetVertex& v [[buffer(0)]],
                                    constant float4x4* bones [[buffer(1)]],
                                    device float4* output [[buffer(2)]],
                                    constant uint& count [[buffer(3)]]) {
            float3 n = normalize(wpe_skin_puppet_normal(v, bones, count));
            WPEPuppetVertex moved = v;
            moved.position.xyz += float3(1.0, -1.0, 0.0);
            float3 tangent = wpe_skin_puppet_position(moved, bones, count).xyz
                           - wpe_skin_puppet_position(v, bones, count).xyz;
            output[0] = float4(n, dot(n, normalize(tangent)));
            output[1] = float4(tangent, 0.0);
        }
        """
        let library = try device.makeLibrary(source: source, options: WPEMetalLibraryRegistry.Configuration(fastMathEnabled: fast).makeOptions())
        let function = try #require(library.makeFunction(name: "boneNormalProbe"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let queue = try #require(device.makeCommandQueue())
        for testCase in cases {
            let result = try run(testCase, device: device, queue: queue, pipeline: pipeline)
            let deformation = blendedMatrix(testCase)
            let sourceNormal = SIMD3<Double>(1, 1, 1)
            let expected = testCase.singular ? simd_normalize(sourceNormal) : simd_normalize(deformation.inverse.transpose * sourceNormal)
            let actual = SIMD3<Double>(Double(result.x), Double(result.y), Double(result.z))
            #expect(actual.x.isFinite && actual.y.isFinite && actual.z.isFinite)
            #expect(simd_length(actual - expected) < 0.0001, "\(testCase.name), fast=\(fast): \(actual) vs \(expected)")
            if !testCase.singular {
                #expect(abs(result.w) < 0.0001, "\(testCase.name): skinned normal is not perpendicular to the position helper's tangent")
            }
        }
    }

    @Test("The nonuniform and mixed cases distinguish the old plain 3x3 normal")
    func counterexamplesAreMeaningful() {
        for testCase in cases where ["nonuniform", "mixed", "mirrored"].contains(testCase.name) {
            let deformation = blendedMatrix(testCase)
            let n = SIMD3<Double>(1, 1, 1)
            let old = simd_normalize(deformation * n)
            let expected = simd_normalize(deformation.inverse.transpose * n)
            #expect(simd_length(old - expected) > 0.1, "\(testCase.name) would not catch the old implementation")
            #expect(abs(simd_dot(expected, simd_normalize(deformation * SIMD3<Double>(1, -1, 0)))) < 1e-12)
        }
    }

    private var cases: [Case] {
        [
            Case(name: "identity", bones: [matrix_identity_float4x4]),
            Case(name: "uniform", bones: [scale(2, 2, 2)]),
            Case(name: "nonuniform", bones: [scale(2, 1, 0.5)]),
            Case(name: "mirrored", bones: [scale(-2, 1, 0.5)]),
            Case(name: "rotated", bones: [rotation * scale(2, 1, 0.5)]),
            Case(name: "mixed", bones: [scale(2, 1, 0.5), rotation * scale(1, 3, 1)], weights: SIMD4(2, 3, 0, 0)),
            Case(name: "tiny", bones: [scale(2e-6, 1e-6, 0.5e-6)]),
            Case(name: "large", bones: [scale(2e6, 1e6, 0.5e6)]),
            Case(name: "invalid index uses identity", bones: [scale(2, 1, 0.5)], weights: SIMD4(1, 1, 0, 0), indices: SIMD4(0, 99, 0, 0)),
            Case(name: "negative weights ignored", bones: [scale(2, 1, 0.5), rotation], weights: SIMD4(1, -1, 0, 0)),
            Case(name: "zero weights", bones: [scale(2, 1, 0.5)], weights: .zero),
            Case(name: "singular blend", bones: [scale(1, 1, 1), scale(-1, 1, 1)], weights: SIMD4(1, 1, 0, 0), singular: true),
        ]
    }

    private func blendedMatrix(_ testCase: Case) -> simd_double3x3 {
        let weights = (0 ..< 4).map { max(Double(testCase.weights[$0]), 0) }
        let sum = weights.reduce(0, +)
        guard sum > 0.00001 else { return matrix_identity_double3x3 }
        var result = simd_double3x3(0)
        for index in 0 ..< 4 {
            let boneIndex = Int(testCase.indices[index])
            let bone = testCase.bones.indices.contains(boneIndex) ? testCase.bones[boneIndex] : matrix_identity_float4x4
            let linear = simd_double3x3(SIMD3<Double>(Double(bone[0].x), Double(bone[0].y), Double(bone[0].z)),
                                        SIMD3<Double>(Double(bone[1].x), Double(bone[1].y), Double(bone[1].z)),
                                        SIMD3<Double>(Double(bone[2].x), Double(bone[2].y), Double(bone[2].z)))
            result += linear * (weights[index] / sum)
        }
        return result
    }

    private func run(_ testCase: Case, device: MTLDevice, queue: MTLCommandQueue,
                     pipeline: MTLComputePipelineState) throws -> SIMD4<Float> {
        var vertex = WPEMetalPuppetVertex(position: SIMD4(0, 0, 0, 1), uv: .zero,
                                          skinBlendIndices: testCase.indices, skinBlendWeights: testCase.weights,
                                          normal: SIMD4(1, 1, 1, 0))
        let bones = try #require(testCase.bones.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
        let output = try #require(device.makeBuffer(length: 32, options: .storageModeShared))
        var count = UInt32(testCase.bones.count)
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&vertex, length: MemoryLayout.size(ofValue: vertex), index: 0)
        encoder.setBuffer(bones, offset: 0, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        encoder.setBytes(&count, length: MemoryLayout.size(ofValue: count), index: 3)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        try #require(command.status == .completed, "\(String(describing: command.error))")
        return output.contents().load(as: SIMD4<Float>.self)
    }

    private func scale(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(x, y, z, 1))
    }

    private var rotation: simd_float4x4 {
        let angle: Float = 0.7
        return simd_float4x4(SIMD4(cos(angle), sin(angle), 0, 0), SIMD4(-sin(angle), cos(angle), 0, 0),
                             SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
    }
}
#endif
