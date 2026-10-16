public enum WPEParityProgramBuilder {
    /// Nil for a scene draw without a material file.
    public static func description(of draw: WPEParityFrameDraw,
                                   scene: WPEParityProgramScene) -> WPEParityProgramDescription? {
        let material: WPEParityProgramMaterial? = switch draw {
        case let .scene(draw): scene.material(for: draw)
        case let .post(draw): scene.engineMaterial(draw)
        }
        return material.map { description($0, engineFlags: scene.engineFlags, assets: scene.assets) }
    }

    /// Each sampler loads its bound texture, or its annotation default when unbound (1401a5c40.c:659-750); both
    /// give a TEXI format, but only bound slots carry component flags into the combo tail.
    static func description(_ material: WPEParityProgramMaterial, engineFlags: WPEEngineComboFlags,
                            assets: WPEParityProgramAssets) -> WPEParityProgramDescription {
        var flags = engineFlags
        var bound = material.textures.mapValues { _ in WPEBoundComboTexture() }
        let sources = WPEParityProgramResolver.expandedSources(shader: material.shader, sources: assets)
        let samplers = WPEShaderAnnotationCombos(vertexSource: sources.vertex, fragmentSource: sources.fragment).samplers
        for (slot, sampler) in samplers.entries {
            let name = material.textures[slot] ?? (sampler.defaultTexture.isEmpty ? nil : sampler.defaultTexture)
            guard let header = name.flatMap(assets.textureHeader(named:)) else { continue }
            flags.textureFormats[slot] = header.format
            bound[slot]?.flags = header.flags
        }
        return WPEParityProgramDescription(material: material, engineFlags: flags, boundTextures: bound)
    }
}
