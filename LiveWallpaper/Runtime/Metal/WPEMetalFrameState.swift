#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal

/// Logical identity for a render target during one `render(...)` call. `.scene` is the persistent output texture; `.named(_)` covers FBOs and layer composites resolved through the pool.
enum WPEMetalTargetID: Hashable {
    case scene
    case named(String)

    init(target: WPERenderTarget) {
        switch target {
        case .scene:
            self = .scene
        case .fbo(let name), .layerComposite(let name):
            self = .named(name)
        }
    }
}

/// Attachment alpha writes are surface semantics, not a side effect of the authored blend mode. The render-graph `.scene` target must retain alpha like named FBOs; the terminal present pass makes opaque-alpha explicit in the fragment result, never via color write masks.
enum WPEMetalAlphaWritePolicy: Hashable, Sendable {
    case all

    /// `blendMode` is taken and deliberately ignored — not a leftover: keying the write mask off it produced RGB>0/A=0 texels wherever a transparent clear met a blended draw. (see `alphaWritePolicySeparatesTerminalSurfaceFromRenderGraph`)
    static func resolve(targetID: WPEMetalTargetID, blendMode _: String) -> Self {
        switch targetID {
        case .scene, .named:
            return .all
        }
    }

    var writeMask: MTLColorWriteMask {
        .all
    }
}

struct WPEMetalFrameState {
    let output: MTLTexture
    let sceneSize: CGSize
    let cameraUniforms: WPEMetalCameraUniforms
    var latestSceneTexture: MTLTexture?
    var latestNamedTextures: [String: MTLTexture] = [:]
    var writtenTargets: Set<WPEMetalTargetID> = []
    /// Bumped on every scene-target write. Scene-alias snapshots are stamped with this so a later pass can tell a stale capture from a current one — a snapshot for one layer must not be reused after other layers drew to the scene.
    var sceneWriteGeneration: Int = 0
    /// `sceneWriteGeneration` at snapshot time. An entry exists ONLY for snapshot-created textures; a real write to the same name removes it so snapshot logic never clobbers real content.
    var sceneAliasSnapshotGenerations: [String: Int] = [:]
    /// `sceneWriteGeneration` when the current layer's pass loop began. A scene-alias
    /// read may bind the live scene only while no pass of its own layer has written it.
    var layerEntrySceneWriteGeneration: Int = 0
    var sceneAliasSnapshotBlits = 0
    var sceneAliasDirectBinds = 0
    /// Ping-pong's secondary texture is allocated lazily and may contain garbage on first use. Tracking by texture identity (not target) decides whether `.load` is safe or whether we need `.clear` (or a blit-copy from the previous primary).
    var initializedTextures: Set<ObjectIdentifier> = []
    var depthTextures: [WPEMetalDepthTextureKey: MTLTexture] = [:]
    /// Identity of the output texture whose REFRACT snapshot is still current. Cleared the moment that same physical texture is written again, so a recycled output never inherits a stale snapshot.
    private var freshRefractionSnapshotOutputID: ObjectIdentifier?
    /// Scene-level camera parallax for this frame; object-quad (scene-targeted)
    /// draws translate each layer by `cameraParallax.pixelOffset(depth:…)`.
    var cameraParallax: WPECameraParallaxFrame = .neutral
    /// Threaded so `resolve()` can honor a first-frame read of an unwritten but declared local FBO. Optional so hand-built frame states (tests) omit it and keep the strict miss→throw.
    let renderTargetPool: WPEMetalRenderTargetPool?

    init(
        output: MTLTexture,
        sceneSize: CGSize,
        cameraUniforms: WPEMetalCameraUniforms = .identity,
        previousSceneTexture: MTLTexture? = nil,
        previousNamedTextures: [String: MTLTexture] = [:],
        renderTargetPool: WPEMetalRenderTargetPool? = nil
    ) {
        self.output = output
        self.sceneSize = sceneSize
        self.cameraUniforms = cameraUniforms
        self.latestSceneTexture = previousSceneTexture
        self.latestNamedTextures = previousNamedTextures
        self.renderTargetPool = renderTargetPool
    }

    func latestTexture(for targetID: WPEMetalTargetID) -> MTLTexture? {
        switch targetID {
        case .scene:
            return latestSceneTexture
        case .named(let name):
            return latestNamedTextures[name]
        }
    }

    var currentFrameSceneTexture: MTLTexture? {
        writtenTargets.contains(.scene) ? latestSceneTexture : nil
    }

    mutating func registerWrite(texture: MTLTexture, targetID: WPEMetalTargetID) {
        let textureID = ObjectIdentifier(texture)
        writtenTargets.insert(targetID)
        initializedTextures.insert(textureID)
        if freshRefractionSnapshotOutputID == textureID {
            freshRefractionSnapshotOutputID = nil
        }
        switch targetID {
        case .scene:
            latestSceneTexture = texture
            sceneWriteGeneration += 1
        case .named(let name):
            latestNamedTextures[name] = texture
            sceneAliasSnapshotGenerations.removeValue(forKey: name)
        }
    }

    mutating func markRefractionSnapshotFresh(for texture: MTLTexture) {
        freshRefractionSnapshotOutputID = ObjectIdentifier(texture)
    }

    func hasFreshRefractionSnapshot(for texture: MTLTexture) -> Bool {
        freshRefractionSnapshotOutputID == ObjectIdentifier(texture)
    }

    mutating func seedPreviousTexture(_ texture: MTLTexture, targetID: WPEMetalTargetID) {
        switch targetID {
        case .scene:
            latestSceneTexture = texture
        case .named(let name):
            latestNamedTextures[name] = texture
        }
    }

    mutating func markInitialized(_ texture: MTLTexture) {
        initializedTextures.insert(ObjectIdentifier(texture))
    }

    func hasInitialized(_ texture: MTLTexture) -> Bool {
        initializedTextures.contains(ObjectIdentifier(texture))
    }
}

struct WPEMetalPipelineKey: Hashable {
    let vertexName: String
    let fragmentName: String
    let blendMode: String
    let alphaWritePolicy: WPEMetalAlphaWritePolicy
    let colorPixelFormat: MTLPixelFormat
    /// Every pipeline state must declare the same depth attachment format as the render pass that drives it. Default `.invalid` for non-depth passes so Metal validation does not fail when a fullscreen copy without depth meets a pipeline that thought it had `.depth32Float`.
    let depthPixelFormat: MTLPixelFormat
}

struct WPEMetalDepthKey: Hashable {
    let depthTest: String
    let depthWrite: String
    let reversedZ: Bool
}

/// Per-frame depth-texture identity. Keys by (target, exact size) so a
/// scaled FBO's depth attachment matches its color attachment dimensions.
struct WPEMetalDepthTextureKey: Hashable {
    let targetID: WPEMetalTargetID
    let width: Int
    let height: Int
}
#endif
