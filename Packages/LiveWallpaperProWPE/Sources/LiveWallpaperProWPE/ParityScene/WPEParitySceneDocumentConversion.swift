import CoreGraphics

public enum WPEParitySceneConversionError: Error, Hashable, Sendable {
    /// `WPERenderFBO.format` names no format the parity frame knows how to allocate.
    case unknownFBOFormat(String)
}

public extension WPEParitySceneDescription {
    /// Scene fields come from `document`, layers and effect passes from `graph`. Inputs neither carries take WPE's
    /// defaults: MSAA off unless passed, no transparent sorting, no global composite flag, no ledsource/puppet bit4.
    init(document: WPESceneDocument, graph: WPERenderGraph,
         msaaSamples: Int = 1) throws(WPEParitySceneConversionError) {
        let width = Int(document.general.orthogonalProjection.width.rounded())
        let height = Int(document.general.orthogonalProjection.height.rounded())
        let images = Dictionary(document.imageObjects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let scope = WPEParitySceneFBOScope(graph.layers, sceneWidth: width, sceneHeight: height)
        var objects: [WPEParitySceneObject] = []
        for layer in graph.layers {
            try objects.append(WPEParitySceneObject(layer: layer, image: images[layer.objectID], scope: scope))
        }
        self.init(width: width, height: height, clearColor: document.general.clearColor,
                  clearEnabled: document.general.clearEnabled.resolvedValue, msaaSamples: msaaSamples,
                  objects: objects)
    }
}

/// FBO names are scene-wide, as in the current graph builder: a name a layer does not declare resolves to the last
/// layer that does, and every layer then uses one shared resource for it.
private struct WPEParitySceneFBOScope {
    struct Declaration {
        let fbo: WPERenderFBO
        /// Extent of the declaring layer, which sizes the FBO.
        let width: Int
        let height: Int
        let local: Bool
    }

    let sceneWidth: Int
    let sceneHeight: Int
    private var declarations: [String: Declaration] = [:]
    private(set) var shared: Set<String> = []

    init(_ layers: [WPERenderLayer], sceneWidth: Int, sceneHeight: Int) {
        self.sceneWidth = sceneWidth
        self.sceneHeight = sceneHeight
        for layer in layers {
            let size = extent(of: layer)
            for fbo in layer.localFBOs {
                declarations[fbo.name] = Declaration(fbo: fbo, width: size.width, height: size.height, local: false)
            }
        }
        for layer in layers {
            let local = Set(layer.localFBOs.map(\.name))
            for pass in layer.passes {
                for case let .fbo(name) in pass.parityReferences + [pass.target.parityReference].compactMap(\.self)
                    where !local.contains(name) {
                    guard let declaration = declarations[name] else { continue }
                    shared.insert(name)
                    if let partner = declaration.fbo.swapPartner {
                        shared.insert(partner)
                    }
                }
            }
        }
    }

    func extent(of layer: WPERenderLayer) -> (width: Int, height: Int) {
        let size = layer.compositeSourceExtent?.compositeSize ?? layer.geometry.size
        return (size.map { Int($0.width.rounded()) } ?? sceneWidth, size.map { Int($0.height.rounded()) } ?? sceneHeight)
    }

    /// Every scene declaration, with the layer's own (first one wins) taking precedence.
    func declarations(visibleFrom layer: WPERenderLayer) -> [String: Declaration] {
        let size = extent(of: layer)
        var visible = declarations
        for fbo in layer.localFBOs.reversed() {
            visible[fbo.name] = Declaration(fbo: fbo, width: size.width, height: size.height, local: true)
        }
        return visible
    }
}

private extension WPEParitySceneFBOScope.Declaration {
    func parityFBO(shared: Bool) throws(WPEParitySceneConversionError) -> WPEParitySceneFBO {
        let size = extent
        return try WPEParitySceneFBO(name: fbo.name, width: size.width, height: size.height,
                                     format: Self.metalFormat(fbo.format), shared: shared,
                                     swapPartner: local ? fbo.swapPartner : nil)
    }

    /// `pixelSize`, else `fit` over the layer extent, else the layer extent divided by `scale`.
    var extent: (width: Int, height: Int) {
        // catsout WPImageObject.cpp parses `scale` as uint32_t and resets 0 to 1, so fractions truncate and a scale
        // below 1 never enlarges; WPSceneParser.cpp truncates `size / scale`.
        let divisor = max(1, fbo.scale.rounded(.towardZero))
        func divided(_ edge: Double) -> Int {
            max(1, Int(edge / divisor))
        }
        if let size = fbo.pixelSize {
            return (divided(Double(size.width)), divided(Double(size.height)))
        }
        if let fit = fbo.fit, fit > 0, max(width, height) > 0 {
            let ratio = fit / Double(max(width, height))
            return (max(1, Int((Double(width) * ratio).rounded())), max(1, Int((Double(height) * ratio).rounded())))
        }
        return (divided(Double(width)), divided(Double(height)))
    }

    static func metalFormat(_ format: String) throws(WPEParitySceneConversionError) -> String {
        switch format.lowercased() {
        case "rgba8888": "rgba8unorm"
        case "rgba16f", "rgba_half", "rgba16161616f": "rgba16float"
        case "r8", "r8unorm": "r8unorm"
        case "rg88": "rg8unorm"
        case "r16f": "r16float"
        case "rg1616f": "rg16float"
        default: throw .unknownFBOFormat(format)
        }
    }
}

extension WPEParitySceneObject {
    fileprivate init(layer: WPERenderLayer, image: WPESceneImageObject?,
                     scope: WPEParitySceneFBOScope) throws(WPEParitySceneConversionError) {
        let (width, height) = scope.extent(of: layer)
        let material = layer.passes.first { $0.phase == .material }
        let colorBlendMode = image?.colorBlendMode ?? 0
        let materialBlend = material.map { $0.authoredJSON.materialPass?["blending"]?.parityString ?? $0.blending }
        try self.init(id: layer.objectID, sortKey: layer.sortIndex, visible: layer.visible, width: width,
                      height: height, materialShader: material?.shader ?? "genericimage2",
                      blend: colorBlendMode == 31
                          ? .additive : WPEParitySceneBlend(material: materialBlend ?? "translucent"),
                      colorBlendMode: colorBlendMode, passthrough: image?.config.passthrough ?? false,
                      copyBackground: image?.copyBackground ?? true,
                      fullscreen: layer.utilityModelKind == .fullScreenLayer, parentID: layer.parentObjectID,
                      effects: Self.effects(layer, image: image, scope: scope))
    }

    private static func effects(_ layer: WPERenderLayer, image: WPESceneImageObject?,
                                scope: WPEParitySceneFBOScope) throws(WPEParitySceneConversionError)
        -> [WPEParitySceneEffect] {
        var order: [String] = []
        var grouped: [String: [WPERenderPass]] = [:]
        for pass in layer.passes {
            guard pass.phase != .material, let identity = pass.authoredJSON.effectIdentity else { continue }
            if grouped[identity.stableEffectID] == nil {
                order.append(identity.stableEffectID)
            }
            grouped[identity.stableEffectID, default: []].append(pass)
        }
        let visible = scope.declarations(visibleFrom: layer)
        let fbos = visible.mapValues(\.fbo)
        let localNames = layer.localFBOs.map(\.name)
        var effects: [WPEParitySceneEffect] = []
        for stableID in order {
            guard let passes = grouped[stableID], let identity = passes.first?.authoredJSON.effectIdentity else {
                continue
            }
            let authored = image?.effects.first { $0.id == identity.authoredEffectID }
            let enabled = passes.first?.visibilityGate?.initialVisible ?? authored?.visible ?? true
            let converted = passes.compactMap { WPEParityScenePass(pass: $0, fbos: fbos) }
            var used = Set(converted.flatMap(\.fboNames))
            used.formUnion(used.compactMap { name in visible[name].flatMap { $0.local ? $0.fbo.swapPartner : nil } })
            var ordered: [String] = []
            for name in localNames + used.sorted() where used.contains(name) && !ordered.contains(name) {
                ordered.append(name)
            }
            var declared: [WPEParitySceneFBO] = []
            for name in ordered {
                guard let declaration = visible[name] else { continue }
                try declared.append(declaration.parityFBO(shared: scope.shared.contains(name)))
            }
            effects.append(WPEParitySceneEffect(id: identity.authoredEffectID, enabled: enabled, passes: converted,
                                                fbos: declared))
        }
        return effects
    }
}

extension WPEParityScenePass {
    /// `nil` for a command other than a `copy` whose source and target both resolve; catsout's WPSceneParser.cpp
    /// skips those too.
    init?(pass: WPERenderPass, fbos: [String: WPERenderFBO]) {
        if case .command = pass.phase {
            guard pass.shader == "commands/copy", case let .fbo(target) = pass.target, fbos[target] != nil else {
                return nil
            }
            switch pass.textures[0] {
            case .previous:
                self.init(shader: pass.shader, target: target, kind: .copy(source: nil))
            case let .fbo(name) where fbos[name] != nil:
                self.init(shader: pass.shader, target: target, kind: .copy(source: name))
            default:
                return nil
            }
            return
        }
        let references = pass.parityReferences
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

    fileprivate var fboNames: [String] {
        var names = binds + [target].compactMap(\.self)
        if case let .copy(source?) = kind {
            names.append(source)
        }
        return names
    }
}

private extension WPERenderPass {
    var parityReferences: [WPETextureReference] {
        [source] + textures.sorted { $0.key < $1.key }.map(\.value) + binds.sorted { $0.key < $1.key }.map(\.value)
    }
}

private extension WPERenderTarget {
    var parityReference: WPETextureReference? {
        if case let .fbo(name) = self {
            .fbo(name)
        } else {
            nil
        }
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
