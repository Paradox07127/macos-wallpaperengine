#if !LITE_BUILD
import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal

/// A real clear-only scene exercises session and actor lifetime without an external shader toolchain or Steam install.
@MainActor
struct ParityLifecycleFixture {
    let root: URL
    let descriptor: SceneDescriptor

    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory.appending(path: "parity-lifecycle-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scene = #"{"camera":{"center":"0 0 -1","eye":"0 0 0","up":"0 1 0"},"general":{"orthogonalprojection":{"width":64,"height":64},"clearenabled":true,"clearcolor":"0 0 1"},"objects":[]}"#
        try Data(scene.utf8).write(to: root.appending(path: "scene.json"))
        return Self(root: root, descriptor: .init(workshopID: "parity-lifecycle", cacheRelativePath: "wpe-cache/parity-lifecycle",
                                                  entryFile: "scene.json", capabilityTier: .imageOnly))
    }

    func inputs(surface: WPERenderSurface, actor: WPEDisplayRenderActor,
                frames: WPESceneSpanFrames? = nil) -> WPEParitySceneInputs {
        var inputs = WPEParitySceneInputs(
            descriptor: descriptor, entryResolver: .init(cacheRootURL: root), projectRoot: root,
            assets: .init(sceneDirectory: root, assetRoots: []), settings: .init(bloom: false), compiler: nil,
            device: surface.metalLayer.device!, presentLayer: .init(layer: surface.metalLayer), mailbox: surface.mailbox,
            surfaceControl: WPERenderThreadFramePacer(surface: surface, renderActor: actor),
            drawableSize: CGSize(width: 64, height: 64), pixelFormat: surface.metalLayer.pixelFormat,
            span: frames.map { ($0, 9) }
        )
        inputs.compilerIdentity = "parity-lifecycle-clear"
        inputs.textureCompression = false
        inputs.renderScaleOverride = 1
        return inputs
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
