#if !LITE_BUILD
import CoreGraphics
import Foundation
import Metal

final class WPEMetalDepthStateCache {
    private let device: MTLDevice
    private var depthStencilStates: [WPEMetalDepthKey: MTLDepthStencilState] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    static let memorylessDepthDefaultsKey = "WPEMetalMemorylessDepthEnabled"
    /// Internal kill-switch, default ON. Frozen read-once (restart to apply); `defaults write com.loomscreen.pro WPEMetalMemorylessDepthEnabled -bool NO` is the per-user escape hatch (suite-first).
    static let isMemorylessDepthEnabled: Bool = {
        let suite = UserDefaults.appSuite
        if suite.object(forKey: memorylessDepthDefaultsKey) != nil {
            return suite.bool(forKey: memorylessDepthDefaultsKey)
        }
        return UserDefaults.standard.object(forKey: memorylessDepthDefaultsKey) as? Bool ?? true
    }()

    /// The caller additionally opts a target out (`allowTransient: false`) when more than one pass writes its depth, since those can load depth across encoders.
    var depthAttachmentIsTransient: Bool {
        Self.isMemorylessDepthEnabled
    }

    /// Derive load/store from the actual texture, never from the flag: pairing a memoryless texture with a `.store` action is a Metal validation crash.
    func isTransientDepthAttachment(_ texture: MTLTexture) -> Bool {
        texture.storageMode == .memoryless
    }

    func needsAttachment(for pass: WPEPreparedRenderPass) -> Bool {
        pass.pass.depthWrite.lowercased() == "enabled"
            || pass.pass.depthWrite.lowercased() == "true"
            || pass.pass.depthTest.lowercased() != "disabled"
    }

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
        descriptor.isDepthWriteEnabled = Self.depthWriteEnabled(key.depthWrite)

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

    static func depthWriteEnabled(_ raw: String) -> Bool {
        let lowered = raw.lowercased()
        return lowered == "enabled" || lowered == "true"
    }

    static func compareFunction(for raw: String, reversedZ: Bool = false) -> MTLCompareFunction {
        switch raw.lowercased() {
        // WPE `depthtest` is a boolean string, not a GL compare name. "enabled" means occlude by depth, so it must map to a real comparison — `default: .always` would disable testing while depth WRITE stayed on.
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
