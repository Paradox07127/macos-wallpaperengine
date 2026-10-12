import CoreGraphics

public extension WPEParitySceneDescription {
    /// Scene fields come from `document`, layers and effect passes from `graph`. Inputs neither carries take WPE's
    /// defaults: MSAA off unless passed, no transparent sorting, no global composite flag, no ledsource/puppet bit4.
    init(document: WPESceneDocument, graph: WPERenderGraph, msaaSamples: Int = 1) {
        let width = Int(document.general.orthogonalProjection.width.rounded())
        let height = Int(document.general.orthogonalProjection.height.rounded())
        let images = Dictionary(document.imageObjects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.init(width: width, height: height, clearColor: document.general.clearColor,
                  clearEnabled: document.general.clearEnabled.resolvedValue, msaaSamples: msaaSamples,
                  objects: graph.layers.map {
                      WPEParitySceneObject(layer: $0, image: images[$0.objectID], sceneWidth: width,
                                           sceneHeight: height)
                  })
    }
}

extension WPEParitySceneObject {
    init(layer: WPERenderLayer, image: WPESceneImageObject?, sceneWidth: Int, sceneHeight: Int) {
        let size = layer.compositeSourceExtent?.compositeSize ?? layer.geometry.size
        let width = size.map { Int($0.width.rounded()) } ?? sceneWidth
        let height = size.map { Int($0.height.rounded()) } ?? sceneHeight
        let material = layer.passes.first { $0.phase == .material }
        let colorBlendMode = image?.colorBlendMode ?? 0
        let materialBlend = material.map { $0.authoredJSON.materialPass?["blending"]?.parityString ?? $0.blending }
        self.init(id: layer.objectID, sortKey: layer.sortIndex, visible: layer.visible, width: width, height: height,
                  materialShader: material?.shader ?? "genericimage2",
                  blend: colorBlendMode == 31 ? .additive : WPEParitySceneBlend(material: materialBlend ?? "translucent"),
                  colorBlendMode: colorBlendMode, passthrough: image?.config.passthrough ?? false,
                  copyBackground: image?.copyBackground ?? true,
                  fullscreen: layer.utilityModelKind == .fullScreenLayer, parentID: layer.parentObjectID,
                  effects: Self.effects(layer, image: image, width: width, height: height))
    }

    private static func effects(_ layer: WPERenderLayer, image: WPESceneImageObject?, width: Int,
                                height: Int) -> [WPEParitySceneEffect] {
        var order: [String] = []
        var grouped: [String: [WPERenderPass]] = [:]
        for pass in layer.passes {
            guard case .effect = pass.phase, let identity = pass.authoredJSON.effectIdentity else { continue }
            if grouped[identity.stableEffectID] == nil {
                order.append(identity.stableEffectID)
            }
            grouped[identity.stableEffectID, default: []].append(pass)
        }
        let fbos = Dictionary(layer.localFBOs.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { stableID in
            guard let passes = grouped[stableID], let identity = passes.first?.authoredJSON.effectIdentity else {
                return nil
            }
            let authored = image?.effects.first { $0.id == identity.authoredEffectID }
            let enabled = passes.first?.visibilityGate?.initialVisible ?? authored?.visible ?? true
            let converted = passes.map { WPEParityScenePass(pass: $0, fbos: fbos) }
            let used = Set(converted.flatMap { $0.binds + [$0.target].compactMap(\.self) })
            let declared = layer.localFBOs.filter { used.contains($0.name) }.map { fbo in
                let pixels = fbo.pixelSize
                    ?? CGSize(width: Double(width) / max(fbo.scale, 1), height: Double(height) / max(fbo.scale, 1))
                return WPEParitySceneFBO(name: fbo.name, width: max(1, Int(pixels.width.rounded())),
                                         height: max(1, Int(pixels.height.rounded())))
            }
            return WPEParitySceneEffect(id: identity.authoredEffectID, enabled: enabled, passes: converted,
                                        fbos: declared)
        }
    }
}

extension WPEParityScenePass {
    init(pass: WPERenderPass, fbos: [String: WPERenderFBO]) {
        let references = [pass.source] + pass.textures.sorted { $0.key < $1.key }.map(\.value)
            + pass.binds.sorted { $0.key < $1.key }.map(\.value)
        var target: String?
        if case let .fbo(name) = pass.target, fbos[name] != nil {
            target = name
        }
        var binds: [String] = []
        for case let .fbo(name) in references where fbos[name] != nil && name != target && !binds.contains(name) {
            binds.append(name)
        }
        let authoredBlend = pass.authoredJSON.effectPass?["blending"]?.parityString
            ?? pass.authoredJSON.materialPass?["blending"]?.parityString
        self.init(shader: pass.shader, target: target, binds: binds,
                  compose: pass.authoredJSON.effectPass?["compose"] == .bool(true),
                  readsFullFrameBuffer: references.contains(.fbo(WPESceneAliasName.fullFrameBuffer)),
                  blend: WPEParitySceneBlend(material: authoredBlend ?? pass.blending))
    }
}

private extension WPESceneJSONValue {
    var parityString: String? {
        if case let .string(value) = self {
            value
        } else {
            nil
        }
    }
}
