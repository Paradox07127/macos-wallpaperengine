public enum WPEParityProgramBuilder {
    /// One entry per draw operation, in frame order.
    public static func draws(frame: WPEParityFrame, scene: WPEParityProgramScene) -> [WPEParityProgramDraw] {
        frame.draws.keys.sorted().map { index in
            let material: WPEParityProgramMaterial? = switch frame.draws[index] {
            case let .scene(draw)?: sceneMaterial(draw, scene)
            case let .post(draw)?: scene.engineMaterial(draw.shader)
            case nil: nil
            }
            let description = material.map {
                WPEParityProgramDescription(material: $0, engineFlags: scene.engineFlags,
                                            boundTextures: $0.textures.mapValues { _ in WPEBoundComboTexture() })
            }
            return WPEParityProgramDraw(operationIndex: index, pass: frame.operations[index].pass,
                                        description: description)
        }
    }

    private static func sceneMaterial(_ draw: WPEParitySceneDraw,
                                      _ scene: WPEParityProgramScene) -> WPEParityProgramMaterial? {
        if let effect = draw.effectID, let index = draw.passIndex {
            return scene.effectPasses["\(draw.objectID)/\(effect)"]?[index]
        }
        switch draw.shader {
        case "effectpassthrough_4":
            // The image layer adds its BLENDMODE to the pass JSON (FUN_140206ae0).
            var material = scene.engineMaterial(draw.shader)
            material.combos["BLENDMODE"] = Int32(scene.colorBlendModes[draw.objectID] ?? 0)
            return material
        case "composelayer":
            return scene.engineMaterial(draw.shader)
        default:
            return scene.albedo[draw.objectID]
        }
    }
}
