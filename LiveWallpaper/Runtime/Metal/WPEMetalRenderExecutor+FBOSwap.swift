#if !LITE_BUILD
import CoreGraphics
import LiveWallpaperProWPE
import Metal

extension WPEMetalRenderExecutor {
    /// Binds last frame's swapped textures as this frame's contents. A scene-size change re-keys the
    /// pool, so the old bindings are dropped like `previousFrameHistory`.
    func seedSwappedFBOBindings(sceneSize: CGSize, frameState: inout WPEMetalFrameState) {
        frameState.swapFBONames = cachedFBOAliasTopology?.swapFBONames ?? []
        guard let bindings = swappedFBOBindings, bindings.sceneSize == sceneSize else {
            swappedFBOBindings = nil
            return
        }
        for (name, texture) in bindings.textures where frameState.swapFBONames.contains(name) {
            frameState.seedPreviousTexture(texture, targetID: .named(name))
            frameState.markInitialized(texture)
        }
    }

    /// Runs after the layer's passes: exchanges each swap pair in the frame's bindings and the pool.
    func swapFBOBindings(of layer: WPERenderLayer, frameState: inout WPEMetalFrameState) {
        var swappedPairs: Set<String> = []
        for fbo in layer.localFBOs {
            // Repeated declarations of one FBO must still swap the pair once.
            guard let partner = fbo.swapPartner, swappedPairs.insert(min(fbo.name, partner)).inserted else { continue }
            let first = frameState.latestNamedTextures[fbo.name]
            let second = frameState.latestNamedTextures[partner]
            frameState.latestNamedTextures[fbo.name] = second
            frameState.latestNamedTextures[partner] = first
            targetPool.swapTextures(fbo.name, partner, layer: layer, sceneSize: frameState.sceneSize)
            var bindings = swappedFBOBindings ?? (frameState.sceneSize, [:])
            bindings.textures[fbo.name] = second
            bindings.textures[partner] = first
            swappedFBOBindings = bindings
        }
    }
}
#endif
