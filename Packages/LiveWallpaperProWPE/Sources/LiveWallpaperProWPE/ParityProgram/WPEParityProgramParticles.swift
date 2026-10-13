extension WPEParityProgramScene {
    static let particleChildDepthLimit = 8

    /// The draws of the particle JSON at `path`, keyed the way `WPEParityParticleSystem` nests its children.
    static func particleDraws(objectID: String, path: String, assets: WPEParityProgramAssets,
                              diagnostics: inout [WPEParitySceneDiagnostic]) -> [WPEParitySceneParticleDraw] {
        guard let config = WPEParityParticleConfig(path: path, assets: assets, is3D: false) else { return [] }
        var draws: [WPEParitySceneParticleDraw] = []
        appendParticleDraws(config, at: WPEParityParticleDrawKey(objectID: objectID, path: [], renderer: 0),
                            assets: assets, draws: &draws, diagnostics: &diagnostics)
        return draws
    }

    /// R16 Q4: the system's entries, then static children depth first, then one group per event child.
    private static func appendParticleDraws(_ config: WPEParityParticleConfig, at node: WPEParityParticleDrawKey,
                                            assets: WPEParityProgramAssets,
                                            draws: inout [WPEParitySceneParticleDraw],
                                            diagnostics: inout [WPEParitySceneDiagnostic]) {
        diagnostics.append(contentsOf: config.omittedChildPaths.map {
            .particleChildOmitted(objectID: node.objectID, path: $0)
        })
        if let path = config.materialPath, let material = WPEParityProgramMaterial(path: path, assets: assets) {
            let state = materialState(assets.json(path)?["passes"]?[0])
            for (index, renderer) in config.renderers.enumerated() {
                var key = node
                key.renderer = index
                let shader = WPEParityParticleSystem.shaderOverride(renderer: renderer)
                let combos = WPEParityParticleSystem.combos(config: config, material: config.material, renderer: renderer)
                draws.append(WPEParitySceneParticleDraw(
                    key: key, shader: shader ?? material.shader,
                    source: WPEParitySceneMaterialSource(materialPath: path, combos: combos, shader: shader),
                    blend: WPEParitySceneBlend(material.blending), materialState: state,
                    readsFullFrameBuffer: (material.combos["REFRACT"] ?? 0) != 0,
                    worldSpace: config.flags & 1 != 0, perspective: config.flags & 4 != 0
                ))
            }
        }

        for (index, child) in config.children.filter({ $0.trigger == .always }).enumerated() {
            var key = node
            key.path.append(.staticChild(index))
            appendParticleDraws(child.config, at: key, assets: assets, draws: &draws, diagnostics: &diagnostics)
        }
        for (group, child) in config.children.filter({ $0.trigger != .always }).enumerated() {
            var key = node
            key.path.append(.eventGroup(group))
            appendParticleDraws(child.config, at: key, assets: assets, draws: &draws, diagnostics: &diagnostics)
        }
    }
}

extension WPEParityParticleMaterial {
    /// The system material's texture0 (B/1401c5490.c:10129-10138; D/1401d2340.c:139-142).
    init(texture0 header: WPEParityProgramTextureHeader?) {
        self.init(spriteSheet: header.map { $0.flags & 4 != 0 } ?? false,
                  spriteSheetNPOT: header.map { $0.imageWidth < $0.textureWidth } ?? false,
                  texture0Format: header.map { Int($0.format) })
    }
}
