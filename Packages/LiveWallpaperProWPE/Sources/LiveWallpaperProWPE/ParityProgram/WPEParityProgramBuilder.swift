public enum WPEParityProgramBuilder {
    /// One entry per draw operation, in frame order.
    public static func draws(frame: WPEParityFrame, scene: WPEParityProgramScene) -> [WPEParityProgramDraw] {
        frame.draws.keys.sorted().map { index in
            let material: WPEParityProgramMaterial? = switch frame.draws[index] {
            case let .scene(draw)?: scene.material(for: draw)
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
}
