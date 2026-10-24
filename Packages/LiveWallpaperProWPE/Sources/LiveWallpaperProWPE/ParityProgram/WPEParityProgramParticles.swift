extension WPEParityProgramScene {
    /// Root depth is 0; a depth-10 system exists but cannot instantiate further children (22ebe0/22f890).
    static let particleChildDepthLimit = 10
    /// Ceiling in bytes of a frame's particle vertex arena; one larger batch can never be uploaded.
    public static let maxParticleShare = 256 << 20

    /// The draws of the particle JSON at `path`, keyed the way `WPEParityParticleSystem` nests its children.
    static func particleDraws(objectID: String, path: String, assets: WPEParityProgramAssets,
                              diagnostics: inout [WPEParitySceneDiagnostic]) -> [WPEParitySceneParticleDraw] {
        guard let config = WPEParityParticleConfig(path: path, assets: assets, is3D: false) else { return [] }
        var draws: [WPEParitySceneParticleDraw] = []
        appendParticleDraws(config, at: WPEParityParticleDrawKey(objectID: objectID, path: [], renderer: 0),
                            assets: assets, draws: &draws, diagnostics: &diagnostics)
        return draws
    }

    /// Draw order: the system's entries, then static children depth first, then one group per event child.
    private static func appendParticleDraws(_ config: WPEParityParticleConfig, at node: WPEParityParticleDrawKey,
                                            assets: WPEParityProgramAssets,
                                            draws: inout [WPEParitySceneParticleDraw],
                                            diagnostics: inout [WPEParitySceneDiagnostic]) {
        diagnostics.append(contentsOf: config.omittedChildPaths.map {
            .particleChildOmitted(objectID: node.objectID, path: $0)
        })
        diagnostics.append(contentsOf: config.unsupportedChildren.map {
            .particleChildUnsupported(objectID: node.objectID, path: $0.path, asset: $0.asset,
                                      field: $0.field, reason: $0.reason)
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
    /// The system material's texture0 (1401c5490.c:10129-10138; 1401d2340.c:139-142).
    init(texture0 header: WPEParityProgramTextureHeader?) {
        self.init(spriteSheet: header.map { $0.flags & 4 != 0 } ?? false,
                  spriteSheetNPOT: header.map { $0.imageWidth < $0.textureWidth } ?? false,
                  texture0Format: header.map { Int($0.format) })
    }
}

extension WPEParityParticleConfig {
    /// 14022c3c0:507–520 loads the system base with no entry extras and only the all-rope shader override.
    /// 1401515b0 then derives its special-texture flags from the compiled VS/PS texture-slot list.
    func appendMaterialProbes(objectID: String, path: [WPEParityParticlePathElement],
                              assets: WPEParityProgramAssets, engineFlags: WPEEngineComboFlags,
                              into probes: inout [WPEParityParticleMaterialProbe]) {
        let material: WPEParityParticleMaterialProbe.Material
        if let materialPath, var base = WPEParityProgramMaterial(path: materialPath, assets: assets) {
            base.shader = WPEParityParticleSystem.shaderOverride(renderers: renderers) ?? base.shader
            do {
                let description = WPEParityProgramBuilder.description(base, engineFlags: engineFlags, assets: assets)
                let program = try WPEParityProgramResolver.resolve(description, sources: assets)
                material = .ready(program: program,
                                  textureNames: WPEParityProgramBuilder.resolvedTextureNames(base, assets: assets))
            } catch {
                material = .unavailable("particle \(objectID) \(path): \(materialPath): \(error)")
            }
        } else {
            material = .unavailable("particle \(objectID) \(path): material \(materialPath ?? "<missing>") unavailable")
        }
        probes.append(WPEParityParticleMaterialProbe(objectID: objectID, path: path, material: material))
        for (index, child) in children.filter({ $0.trigger == .always }).enumerated() {
            child.config.appendMaterialProbes(objectID: objectID, path: path + [.staticChild(index)],
                                              assets: assets, engineFlags: engineFlags, into: &probes)
        }
        for (group, child) in children.filter({ $0.trigger != .always }).enumerated() {
            child.config.appendMaterialProbes(objectID: objectID, path: path + [.eventGroup(group)],
                                              assets: assets, engineFlags: engineFlags, into: &probes)
        }
    }
}
