#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal

/// Bind points the Metal Shader Converter runtime expects; values mirror metal_irconverter_runtime.h.
enum WPEParityMSCRuntime {
    /// kIRArgumentBufferBindPoint
    static let argumentBufferBindPoint = 2
    /// kIRArgumentBufferDrawArgumentsBindPoint
    static let drawArgumentsBindPoint = 4
    /// kIRArgumentBufferUniformsBindPoint
    static let uniformsBindPoint = 5
    /// kIRVertexBufferBindPoint
    static let vertexBufferBindPoint = 6
    /// kIRStageInAttributeStartIndex
    static let stageInAttributeStartIndex = 11
    /// kIRNonIndexedDraw
    static let nonIndexedDraw: UInt16 = 0
}

enum WPEParityExecutionError: Error, Equatable {
    case geometryStageUnsupported
    case missingFunction(String)
    case unsupportedVertexInput(String)
    case pipelineObjectUnavailable
    case samplerUnsupported
    case missingTexture(String)
    case missingSampler(String)
    case resourceArrayUnsupported(String)
    case arenaExhausted
}

/// A render pipeline plus the per-stage layouts the draw encoder needs to fill MSC argument buffers.
struct WPEParityPipeline {
    struct Stage {
        let reflection: WPEStageReflection
        let bindingPlan: WPEStageBindingPlan
        let cbuffers: [WPECBufferLayout]

        init(_ reflection: WPEStageReflection) throws {
            self.reflection = reflection
            bindingPlan = try WPEStageBindingPlan(reflection)
            cbuffers = try reflection.cbuffers.map(WPECBufferLayout.init)
        }
    }

    let state: MTLRenderPipelineState
    let vertex: Stage
    let fragment: Stage
}

final class WPEParityPipelineFactory {
    let device: MTLDevice
    private var depthStencilStates: [WPEParityDepthStencilState: MTLDepthStencilState] = [:]
    private var samplerStates: [WPEParitySamplerState: MTLSamplerState] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    func makePipeline(
        artifact: WPEParityShaderArtifact,
        blend: WPEParityBlendState,
        colorPixelFormat: MTLPixelFormat,
        depthStencilPixelFormat: MTLPixelFormat = .invalid,
        sampleCount: Int = 1
    ) throws -> WPEParityPipeline {
        guard artifact.geometry == nil else { throw WPEParityExecutionError.geometryStageUnsupported }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try makeFunction(artifact.vertex)
        descriptor.fragmentFunction = try makeFunction(artifact.fragment)
        if !artifact.vertex.reflection.vertexInputs.isEmpty {
            descriptor.vertexDescriptor = try Self.vertexDescriptor(for: artifact.vertex.reflection.vertexInputs)
        }
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        WPEParityMetalStateMapping.apply(blend, to: descriptor)
        descriptor.depthAttachmentPixelFormat = depthStencilPixelFormat
        if [.depth32Float_stencil8, .depth24Unorm_stencil8].contains(depthStencilPixelFormat) {
            descriptor.stencilAttachmentPixelFormat = depthStencilPixelFormat
        }
        descriptor.rasterSampleCount = sampleCount
        return try WPEParityPipeline(
            state: device.makeRenderPipelineState(descriptor: descriptor),
            vertex: WPEParityPipeline.Stage(artifact.vertex.reflection),
            fragment: WPEParityPipeline.Stage(artifact.fragment.reflection)
        )
    }

    func depthStencilState(_ state: WPEParityDepthStencilState) throws -> MTLDepthStencilState {
        if let cached = depthStencilStates[state] {
            return cached
        }
        guard let made = device.makeDepthStencilState(
            descriptor: WPEParityMetalStateMapping.depthStencilDescriptor(state)
        ) else { throw WPEParityExecutionError.pipelineObjectUnavailable }
        depthStencilStates[state] = made
        return made
    }

    func samplerState(_ state: WPEParitySamplerState) throws -> MTLSamplerState {
        if let cached = samplerStates[state] {
            return cached
        }
        guard let descriptor = WPEParityMetalStateMapping.samplerDescriptor(state) else {
            throw WPEParityExecutionError.samplerUnsupported
        }
        guard let made = device.makeSamplerState(descriptor: descriptor) else {
            throw WPEParityExecutionError.pipelineObjectUnavailable
        }
        samplerStates[state] = made
        return made
    }

    /// One interleaved buffer: attributes packed tightly in reflection `index` order.
    static func vertexDescriptor(for inputs: [WPEStageReflection.StageAttribute]) throws -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        var offset = 0
        for input in inputs.sorted(by: { $0.index < $1.index }) {
            let attribute = descriptor.attributes[WPEParityMSCRuntime.stageInAttributeStartIndex + input.index]!
            attribute.format = try vertexFormat(input)
            attribute.offset = offset
            attribute.bufferIndex = WPEParityMSCRuntime.vertexBufferBindPoint
            offset += input.columns * 4
        }
        let layout = descriptor.layouts[WPEParityMSCRuntime.vertexBufferBindPoint]!
        layout.stride = offset
        layout.stepFunction = .perVertex
        layout.stepRate = 1
        return descriptor
    }

    private static func vertexFormat(_ input: WPEStageReflection.StageAttribute) throws -> MTLVertexFormat {
        // MSC reports element types capitalised ("Float"); the schema documents lowercase. wpe-shaderc reports a
        // uint4 BLENDINDICES input as "uint32".
        let formats: [MTLVertexFormat]? = switch input.elementType.lowercased() {
        case "float": [.float, .float2, .float3, .float4]
        case "int", "sint": [.int, .int2, .int3, .int4]
        case "uint", "uint32": [.uint, .uint2, .uint3, .uint4]
        default: nil
        }
        guard let formats, (1 ... 4).contains(input.columns) else {
            throw WPEParityExecutionError.unsupportedVertexInput(input.name)
        }
        return formats[input.columns - 1]
    }

    private func makeFunction(_ stage: WPEParityShaderArtifact.Stage) throws -> MTLFunction {
        let data = stage.metallib.withUnsafeBytes { DispatchData(bytes: $0) }
        let library = try device.makeLibrary(data: data)
        guard let function = library.makeFunction(name: stage.functionName) else {
            throw WPEParityExecutionError.missingFunction(stage.functionName)
        }
        return function
    }
}
#endif
