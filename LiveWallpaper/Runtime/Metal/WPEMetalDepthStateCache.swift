#if !LITE_BUILD
import CoreGraphics
import Foundation
import Metal

/// Owns Metal depth state for one `WPEMetalRenderExecutor` lifetime. The
/// per-frame depth texture dictionary stays on `WPEMetalFrameState`, but its
/// allocation goes through here so descriptor + storage mode stay aligned
/// with the rest of the pipeline.
final class WPEMetalDepthStateCache {
    private let device: MTLDevice
    private var depthStencilStates: [WPEMetalDepthKey: MTLDepthStencilState] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    static let memorylessDepthDefaultsKey = "WPEMetalMemorylessDepthEnabled"
    /// Internal kill-switch, default ON: `.memoryless` (tile-only) depth on Apple GPUs saves
    /// depth-texture bandwidth/footprint but is precision-sensitive, so
    /// `defaults write com.loomscreen.pro WPEMetalMemorylessDepthEnabled -bool NO` stays as
    /// the per-user escape hatch (suite-first so it's honoured even in a process whose
    /// standard domain isn't the app's). Frozen read-once (restart to apply) — this was the last per-frame UserDefaults read in the release render loop; no in-app code writes or expects a live toggle.
    static let isMemorylessDepthEnabled: Bool = {
        let suite = UserDefaults.appSuite
        if suite.object(forKey: memorylessDepthDefaultsKey) != nil {
            return suite.bool(forKey: memorylessDepthDefaultsKey)
        }
        return UserDefaults.standard.object(forKey: memorylessDepthDefaultsKey) as? Bool ?? true
    }()

    /// Whether the flag permits memoryless (tile-only) depth at all. The caller
    /// additionally opts a target out (`allowTransient: false`) when more than
    /// one pass writes its depth, since those can load depth across encoders.
    /// (arm64-only distribution: every Mac GPU is Apple family / TBDR.)
    var depthAttachmentIsTransient: Bool {
        Self.isMemorylessDepthEnabled
    }

    /// Derive load/store from the actual texture, never from the flag: pairing a
    /// memoryless texture (cached for the frame) with a `.store` action is a Metal
    /// validation crash. The flag is frozen read-once, so a mid-process flip can't
    /// happen anymore, but the texture's own storage mode stays the source of truth.
    func isTransientDepthAttachment(_ texture: MTLTexture) -> Bool {
        texture.storageMode == .memoryless
    }

    func needsAttachment(for pass: WPEPreparedRenderPass) -> Bool {
        pass.pass.depthWrite.lowercased() == "enabled"
            || pass.pass.depthWrite.lowercased() == "true"
            || pass.pass.depthTest.lowercased() != "disabled"
    }

    /// Keys depth textures by target and exact dimensions so scaled FBO color and depth attachments match.
    func attachmentTexture(
        for destination: (id: WPEMetalTargetID, texture: MTLTexture),
        frameState: inout WPEMetalFrameState,
        allowTransient: Bool = true
    ) throws -> MTLTexture {
        let key = WPEMetalDepthTextureKey(
            targetID: destination.id,
            width: destination.texture.width,
            height: destination.texture.height
        )
        if let existing = frameState.depthTextures[key] {
            return existing
        }
        let texture = try makeDepthTexture(width: key.width, height: key.height, allowTransient: allowTransient)
        frameState.depthTextures[key] = texture
        return texture
    }

    func stencilState(depthTest: String, depthWrite: String, reversedZ: Bool) -> MTLDepthStencilState {
        let key = WPEMetalDepthKey(
            depthTest: depthTest.lowercased(),
            depthWrite: depthWrite.lowercased(),
            reversedZ: reversedZ
        )
        if let cached = depthStencilStates[key] {
            return cached
        }

        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = Self.compareFunction(for: key.depthTest, reversedZ: key.reversedZ)
        descriptor.isDepthWriteEnabled = key.depthWrite == "enabled" || key.depthWrite == "true"

        let state = device.makeDepthStencilState(descriptor: descriptor)!
        depthStencilStates[key] = state
        return state
    }

    private func makeDepthTexture(width: Int, height: Int, allowTransient: Bool) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: max(width, 1),
            height: max(height, 1),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = allowTransient && depthAttachmentIsTransient ? .memoryless : .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = "WPE Metal executor depth"
        return texture
    }

    static func compareFunction(for raw: String, reversedZ: Bool = false) -> MTLCompareFunction {
        switch raw.lowercased() {
        // WPE materials express depth testing as a boolean string: every `depthtest` in
        // the corpus is "enabled" (33) or "disabled" (799), never a GL compare name.
        // "enabled" means "occlude by depth", so it must map to a real comparison — the
        // old `default: .always` silently disabled depth testing while depth WRITE stayed
        // on, so a no-cull mesh (sphere) drew in index order (half the surface "fault"ed)
        // and a nearer object (three-body stars) was overwritten by a farther one (the
        // skybox). "disabled" correctly keeps `.always`: those passes carry no depth
        // attachment, so the compare is moot.
        case "enabled", "true":
            return reversedZ ? .greaterEqual : .lessEqual
        case "always", "disabled", "false":
            return .always
        case "never":
            return .never
        case "less":
            return .less
        case "lequal", "lessequal", "less_equal":
            return .lessEqual
        case "greater":
            return .greater
        case "gequal", "greaterequal", "greater_equal":
            return .greaterEqual
        case "equal":
            return .equal
        case "notequal", "not_equal":
            return .notEqual
        default:
            return .always
        }
    }

    static func clearDepth(reversedZ: Bool) -> Double {
        reversedZ ? 0 : 1
    }
}
#endif
