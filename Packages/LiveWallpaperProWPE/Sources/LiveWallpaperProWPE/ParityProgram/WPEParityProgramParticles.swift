extension WPEParityProgramScene {
    static let particleChildDepthLimit = 8

    /// The draws of the particle JSON at `path`, keyed the way `WPEParityParticleSystem` nests its children.
    static func particleDraws(objectID: String, path: String, assets: WPEParityProgramAssets,
                              diagnostics: inout [WPEParitySceneDiagnostic]) -> [WPEParitySceneParticleDraw] {
        guard let json = assets.json(path) else { return [] }
        var draws: [WPEParitySceneParticleDraw] = []
        appendParticleDraws(json, at: WPEParityParticleDrawKey(objectID: objectID, renderer: 0), ancestors: [path],
                            assets: assets, draws: &draws, diagnostics: &diagnostics)
        return draws
    }

    /// R16 Q4: the system's entries, then static children depth first, then one group per event child.
    private static func appendParticleDraws(_ json: WPESceneJSONValue, at node: WPEParityParticleDrawKey,
                                            ancestors: [String], assets: WPEParityProgramAssets,
                                            draws: inout [WPEParitySceneParticleDraw],
                                            diagnostics: inout [WPEParitySceneDiagnostic]) {
        // Children resolve to nil so the config parses only this system, indexed as the simulation indexes it.
        let config = WPEParityParticleConfig(json: json, is3D: false) { _ in nil }
        if let path = string(json["material"]), let material = WPEParityProgramMaterial(path: path, assets: assets) {
            let texture = WPEParityParticleMaterial(texture0: material.textures[0].flatMap(assets.textureHeader(named:)))
            let shader = WPEParityParticleSystem.shaderOverride(renderers: config.renderers)
            let state = materialState(assets.json(path)?["passes"]?[0])
            for (index, renderer) in config.renderers.enumerated() {
                var key = node
                key.renderer = index
                let combos = WPEParityParticleSystem.combos(config: config, material: texture, renderer: renderer)
                draws.append(WPEParitySceneParticleDraw(
                    key: key, shader: shader ?? material.shader,
                    source: WPEParitySceneMaterialSource(materialPath: path, combos: combos, shader: shader),
                    blend: WPEParitySceneBlend(material.blending), materialState: state,
                    readsFullFrameBuffer: (material.combos["REFRACT"] ?? 0) != 0,
                    worldSpace: config.flags & 1 != 0, perspective: config.flags & 4 != 0
                ))
            }
        }

        var staticCount = 0
        var eventGroups: [(json: WPESceneJSONValue, path: String)] = []
        for entry in array(json["children"]) {
            let kind = WPEParticleChildEventKind(authoredType: string(entry["type"]),
                                                 flags: number(entry["flags"]).map { Int($0) })
            guard [.staticSystem, .spawn, .death].contains(kind) else { continue }
            let path = string(entry["name"]) ?? string(entry["particle"]) ?? ""
            guard node.eventGroup == nil, !ancestors.contains(path), ancestors.count < particleChildDepthLimit else {
                diagnostics.append(.particleChildOmitted(objectID: node.objectID, path: path))
                continue
            }
            guard let child = assets.json(path) else { continue }
            if kind == .staticSystem {
                var key = node
                key.node.append(staticCount)
                staticCount += 1
                appendParticleDraws(child, at: key, ancestors: ancestors + [path], assets: assets, draws: &draws,
                                    diagnostics: &diagnostics)
            } else {
                eventGroups.append((child, path))
            }
        }
        for (group, event) in eventGroups.enumerated() {
            var key = node
            key.eventGroup = group
            appendParticleDraws(event.json, at: key, ancestors: ancestors + [event.path], assets: assets, draws: &draws,
                                diagnostics: &diagnostics)
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
