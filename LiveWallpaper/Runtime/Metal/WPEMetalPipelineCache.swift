#if !LITE_BUILD
import Foundation
import Metal

final class WPEMetalPipelineCache {
    private let device: MTLDevice
    private let library: MTLLibrary
    private var pipelineStates: [WPEMetalPipelineKey: MTLRenderPipelineState] = [:]
    private var lowercasedBlendModes: [String: String] = [:]
    private var blendContracts: [String: WPEBlendContract] = [:]

    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        self.library = library
    }

    func pipelineState(
        vertexName: String = "wpe_fullscreen_vertex",
        fragmentName: String,
        blendMode: String,
        alphaWritePolicy: WPEMetalAlphaWritePolicy,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat,
        nativeAlpha: WPENativeAlphaPolicy = .compatibility,
        blendContract: WPEBlendContract? = nil
    ) throws -> MTLRenderPipelineState {
        let normalizedBlend: String
        if let cached = lowercasedBlendModes[blendMode] {
            normalizedBlend = cached
        } else {
            normalizedBlend = blendMode.lowercased()
            lowercasedBlendModes[blendMode] = normalizedBlend
        }
        let key = WPEMetalPipelineKey(
            vertexName: vertexName,
            fragmentName: fragmentName,
            blendMode: normalizedBlend,
            alphaWritePolicy: alphaWritePolicy,
            colorPixelFormat: colorPixelFormat,
            depthPixelFormat: depthPixelFormat,
            nativeAlpha: nativeAlpha, blendContract: blendContract
        )
        if let cached = pipelineStates[key] {
            return cached
        }

        guard let vertex = library.makeFunction(name: vertexName),
              let fragment = try WPEMetalColorOutput.fragment(library: library, name: fragmentName, format: colorPixelFormat, nativeAlpha: nativeAlpha) else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable(fragmentName)
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        guard let colorAttachment = descriptor.colorAttachments[0] else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable(fragmentName)
        }
        colorAttachment.pixelFormat = colorPixelFormat
        descriptor.depthAttachmentPixelFormat = depthPixelFormat
        let resolvedBlend: WPEBlendContract
        if let blendContract {
            resolvedBlend = blendContract
        } else if let cached = blendContracts[normalizedBlend] {
            resolvedBlend = cached
        } else {
            resolvedBlend = WPEBlendContract(normalizedBlend)
            blendContracts[normalizedBlend] = resolvedBlend
        }
        resolvedBlend.apply(to: colorAttachment)
        Self.applyAlphaWritePolicy(alphaWritePolicy, to: colorAttachment)

        let state: MTLRenderPipelineState
        do {
            state = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            let detail = """
            vertex: \(vertexName)
            fragment: \(fragmentName)
            blend: \(normalizedBlend)
            alphaWritePolicy: \(alphaWritePolicy)
            colorFormat: \(colorPixelFormat.rawValue)
            depthFormat: \(depthPixelFormat.rawValue)
            error: \(error.localizedDescription)
            """
            WPESceneDebugArtifacts.shared.recordPipelineFailure(
                fragmentName: fragmentName,
                blendMode: normalizedBlend,
                detail: detail
            )
            throw WPEMetalRenderExecutorError.pipelineStateBuildFailed(
                name: fragmentName,
                detail: error.localizedDescription
            )
        }
        pipelineStates[key] = state
        return state
    }

    /// WPE's authored `cullmode` for every draw path EXCEPT the scene-model mesh.
    /// `normal` deliberately falls through to `.none` here — see `sceneModelCullMode`.
    static func cullMode(for raw: String) -> MTLCullMode {
        switch raw.lowercased() {
        case "back":
            return .back
        case "front":
            return .front
        default:
            return .none
        }
    }

    /// Scene-model mesh draws only. `normal` there means ordinary back-face culling, not "no override". Kept off the shared mapping on purpose; widen this only with a capture of a non-mesh `normal` pass.
    static func sceneModelCullMode(for raw: String) -> MTLCullMode {
        switch raw.lowercased() {
        case "normal": .back
        case "inverted": .front
        default: cullMode(for: raw)
        }
    }

    static func applyAlphaWritePolicy(
        _ policy: WPEMetalAlphaWritePolicy,
        to attachment: MTLRenderPipelineColorAttachmentDescriptor
    ) {
        attachment.writeMask = policy.writeMask
    }

    static func applyBlendMode(_ mode: String, to attachment: MTLRenderPipelineColorAttachmentDescriptor) {
        WPEBlendContract(mode).apply(to: attachment)
    }
}
#endif
