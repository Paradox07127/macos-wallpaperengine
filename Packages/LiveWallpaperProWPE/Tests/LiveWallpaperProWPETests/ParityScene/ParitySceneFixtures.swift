import LiveWallpaperProWPE

/// Scene fixtures and a one-line rendering of each operation so expectations read like the report's step lists.
enum ParitySceneFixtures {
    static let sceneWidth = 1920
    static let sceneHeight = 1080
    static let br0 = "sc.512.256.br0"
    static let br1 = "sc.512.256.br1"
    static let sceneBind = "bind backbuffer|backbufferDepth"
    static let sceneClear = ["clear backbuffer 0.1,0.2,0.3,1.0", "clearDepth backbufferDepth 0.0"]

    static func scene(_ objects: [WPEParitySceneObject], clearEnabled: Bool = true,
                      msaaSamples: Int = 1) -> WPEParitySceneDescription {
        WPEParitySceneDescription(width: sceneWidth, height: sceneHeight, clearColor: SIMD3(0.1, 0.2, 0.3),
                                  clearEnabled: clearEnabled, msaaSamples: msaaSamples, objects: objects)
    }

    static func layer(_ id: String = "L", sortKey: Int = 0, visible: Bool = true, colorBlendMode: Int = 0,
                      passthrough: Bool = false, copyBackground: Bool = true, parentID: String? = nil,
                      effects: [WPEParitySceneEffect] = []) -> WPEParitySceneObject {
        WPEParitySceneObject(id: id, sortKey: sortKey, visible: visible, width: 512, height: 256,
                             colorBlendMode: colorBlendMode, passthrough: passthrough, copyBackground: copyBackground,
                             parentID: parentID, effects: effects)
    }

    static func effect(_ id: String, enabled: Bool = true, readsFullFrameBuffer: Bool = false,
                       compose: Bool = false) -> WPEParitySceneEffect {
        WPEParitySceneEffect(id: id, enabled: enabled,
                             passes: [WPEParityScenePass(shader: id, compose: compose,
                                                         readsFullFrameBuffer: readsFullFrameBuffer)])
    }

    static func lines(_ scene: WPEParitySceneDescription) -> [String] {
        lines(WPEParitySceneFrameBuilder.build(scene))
    }

    static func lines(_ frame: WPEParitySceneFrame) -> [String] {
        frame.operations.map { operation in
            switch operation.kind {
            case let .setTargets(color, depth):
                "bind " + (color.map(\.resource.rawValue) + [depth?.resource.rawValue].compactMap(\.self))
                    .joined(separator: "|")
            case let .clearColor(view, color):
                "clear \(view.resource) \(color.red),\(color.green),\(color.blue),\(color.alpha)"
            case let .clearDepth(view, depth):
                "clearDepth \(view.resource) \(depth)"
            case .draw:
                describe(frame.draws[operation.pass])
            case let .copy(source, destination):
                "copy \(source)->\(destination)"
            case let .generateMips(id):
                "mips \(id)"
            case let .resolve(source, destination):
                "resolve \(source)->\(destination)"
            }
        }
    }

    private static func describe(_ draw: WPEParitySceneDraw?) -> String {
        guard let draw else { return "draw <missing description>" }
        let geometry = draw.geometry == .layerMesh ? "mesh" : "quad"
        let mask = draw.writeMask == .rgba ? "rgba" : "rgb"
        return "draw \(draw.shader) [\(draw.reads.map(\.rawValue).joined(separator: ","))] "
            + "\(draw.blend.rawValue)\(draw.alphaMax ? "+max" : "") \(mask) \(geometry)"
    }

    /// Target bound for the albedo draw (or clear) of `objectID`.
    static func albedoTarget(_ scene: WPEParitySceneDescription, _ objectID: String = "L") -> WPEResourceID? {
        WPEParitySceneFrameBuilder.build(scene).draws[WPEPassIdentity("\(objectID)/albedo")]?.target
    }
}
