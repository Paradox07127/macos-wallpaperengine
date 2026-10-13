/// An effect FBO as its effect file declares it.
struct WPEParityAuthoredFBO: Sendable {
    let name: String
    let scale: Double
    let fit: Double?
    let format: String
    /// The FBO a `swap` command of the same effect exchanges it with.
    let swapPartner: String?
    let unique: Bool
}

/// One effect file pass before its FBO names resolve against the scene.
struct WPEParityAuthoredPass: Sendable {
    enum Kind: Sendable {
        case draw
        /// A nil source is `previous`.
        case copy(source: String?)
    }

    let kind: Kind
    let shader: String
    let target: String?
    /// Every texture name the pass samples, in slot order.
    let textures: [String]
    let compose: Bool
    let blend: WPEParitySceneBlend
    let source: WPEParitySceneMaterialSource?

    var references: [String] {
        var names = textures + [target].compactMap(\.self)
        if case let .copy(source?) = kind {
            names.append(source)
        }
        return names
    }
}

struct WPEParityAuthoredEffect: Sendable {
    let id: String
    var enabled: Bool
    let fbos: [WPEParityAuthoredFBO]
    let passes: [WPEParityAuthoredPass]
}

struct WPEParityAuthoredObject: Sendable {
    let id: String
    /// Extent the object's FBOs are sized from.
    let width: Int
    let height: Int
    var effects: [WPEParityAuthoredEffect]

    var localFBOs: [WPEParityAuthoredFBO] {
        effects.flatMap(\.fbos)
    }
}

/// FBO names are scene-wide: a name an object does not declare resolves to the last object that does, and every
/// object then uses one shared resource for it.
struct WPEParitySceneFBOScope {
    struct Declaration {
        let fbo: WPEParityAuthoredFBO
        /// Extent of the declaring object, which sizes the FBO.
        let width: Int
        let height: Int
        let local: Bool
    }

    let backbufferFormat: String
    private var declarations: [String: Declaration] = [:]
    private var shared: Set<String> = []

    init(_ objects: [WPEParityAuthoredObject], backbufferFormat: String) {
        self.backbufferFormat = backbufferFormat
        for object in objects {
            for fbo in object.localFBOs {
                declarations[fbo.name] = Declaration(fbo: fbo, width: object.width, height: object.height,
                                                     local: false)
            }
        }
        for object in objects {
            let local = Set(object.localFBOs.map(\.name))
            for name in object.effects.flatMap(\.passes).flatMap(\.references) where !local.contains(name) {
                guard let declaration = declarations[name] else { continue }
                shared.insert(name)
                if let partner = declaration.fbo.swapPartner {
                    shared.insert(partner)
                }
            }
        }
    }

    func effects(of object: WPEParityAuthoredObject,
                 diagnostics: inout [WPEParitySceneDiagnostic]) -> [WPEParitySceneEffect] {
        // The object's own declarations (first one wins) take precedence over the scene's.
        var visible = declarations
        for fbo in object.localFBOs.reversed() {
            visible[fbo.name] = Declaration(fbo: fbo, width: object.width, height: object.height, local: true)
        }
        let localNames = object.localFBOs.map(\.name)
        // The first enabled effect using a local name declares it and later effects read that one.
        var declaredLocally: Set<String> = []
        var effects: [WPEParitySceneEffect] = []
        for effect in object.effects {
            let passes = effect.passes.compactMap { $0.resolved(visible) }
            var used = Set(passes.flatMap(\.fboNames))
            used.formUnion(used.compactMap { name in visible[name].flatMap { $0.local ? $0.fbo.swapPartner : nil } })
            var ordered: [String] = []
            for name in localNames + used.sorted() where used.contains(name) && !ordered.contains(name) {
                ordered.append(name)
            }
            var declared: [WPEParitySceneFBO] = []
            for name in ordered {
                guard let declaration = visible[name], !(declaration.local && declaredLocally.contains(name)) else {
                    continue
                }
                let format = Declaration.metalFormat(declaration.fbo.format, backbufferFormat: backbufferFormat)
                if format == nil {
                    let diagnostic = WPEParitySceneDiagnostic.compressedFBOFormat(fbo: name,
                                                                                  format: declaration.fbo.format)
                    if !diagnostics.contains(diagnostic) {
                        diagnostics.append(diagnostic)
                    }
                }
                declared.append(declaration.parityFBO(shared: shared.contains(name),
                                                      format: format ?? WPEParitySceneResource.colorFormat))
            }
            if effect.enabled {
                declaredLocally.formUnion(declared.map(\.name).filter { visible[$0]?.local == true })
            }
            effects.append(WPEParitySceneEffect(id: effect.id, enabled: effect.enabled, passes: passes,
                                                fbos: declared))
        }
        return effects
    }
}

private extension WPEParitySceneFBOScope.Declaration {
    func parityFBO(shared: Bool, format: String) -> WPEParitySceneFBO {
        let size = extent
        let fitted = fittedExtent
        return WPEParitySceneFBO(name: fbo.name, width: size.width, height: size.height, format: format,
                                 shared: shared, swapPartner: local ? fbo.swapPartner : nil, unique: fbo.unique,
                                 unscaledSize: SIMD2(fitted?.width ?? width, fitted?.height ?? height),
                                 scale: Int(divisor))
    }

    /// catsout WPImageObject.cpp parses `scale` as uint32_t and resets 0 to 1, so fractions truncate and a scale
    /// below 1 never enlarges; WPSceneParser.cpp truncates `size / scale`.
    private var divisor: Double {
        max(1, fbo.scale.rounded(.towardZero))
    }

    private var fittedExtent: (width: Int, height: Int)? {
        guard let fit = fbo.fit, fit > 0, max(width, height) > 0 else { return nil }
        let ratio = fit / Double(max(width, height))
        return (max(1, Int((Double(width) * ratio).rounded())), max(1, Int((Double(height) * ratio).rounded())))
    }

    /// `fit` over the object extent, else the object extent divided by `scale`.
    var extent: (width: Int, height: Int) {
        fittedExtent ?? (max(1, Int(Double(width) / divisor)), max(1, Int(Double(height) / divisor)))
    }

    /// 1401e7170.c:220-242 and FUN_1401e53a0 (string → engine code), FUN_1400d2a20 (engine code → DXGI); nil for a
    /// block-compressed format.
    static func metalFormat(_ format: String, backbufferFormat: String) -> String? {
        if ["rgba_backbuffer", "rgb_backbuffer"].contains(format.lowercased()) {
            return backbufferFormat
        }
        switch format {
        case "rg88": return "rg8unorm"
        case "r8": return "r8unorm"
        case "rg1616f": return "rg16float"
        case "r16f": return "r16float"
        case "rgba1010102": return "rgb10a2unorm"
        case "rgba16161616f", "rgb161616f": return "rgba16float"
        case "rgba16161616", "rgb161616": return "rgba16unorm"
        case "rgba16161616S", "rgb161616S": return "rgba16snorm"
        case "dxt5", "dxt3", "dxt1", "bc7": return nil
        // rgba8888, rgb888, rgb565, rgba8888s and unknown strings all decode to R8G8B8A8_UNORM.
        default: return WPEParitySceneResource.colorFormat
        }
    }
}

private extension WPEParityAuthoredPass {
    /// `nil` for a `copy` whose source or target does not resolve; catsout's WPSceneParser.cpp skips those too.
    func resolved(_ visible: [String: WPEParitySceneFBOScope.Declaration]) -> WPEParityScenePass? {
        let target = target.flatMap { visible[$0] == nil ? nil : $0 }
        if case let .copy(source) = kind {
            guard let target, source.map({ visible[$0] != nil }) ?? true else { return nil }
            return WPEParityScenePass(shader: shader, target: target, kind: .copy(source: source))
        }
        var binds: [String] = []
        for name in textures where visible[name] != nil && name != target && !binds.contains(name) {
            binds.append(name)
        }
        let frameReads = Self.frameReads(textures.filter { visible[$0] == nil })
        return WPEParityScenePass(shader: shader, target: target, binds: binds, compose: compose,
                                  readsFullFrameBuffer: textures.contains(WPESceneAliasName.fullFrameBuffer),
                                  blend: blend, source: source, frameReads: frameReads)
    }
}

extension WPEParityAuthoredPass {
    /// The `_rt_*` names among `textures` other than `_rt_FullFrameBuffer`, which draws flag on their own.
    static func frameReads(_ textures: [String]) -> [WPEResourceID] {
        var reads: [WPEResourceID] = []
        for name in textures where name.hasPrefix("_rt_") && name != WPESceneAliasName.fullFrameBuffer {
            let id = WPEResourceID(name)
            if !reads.contains(id) {
                reads.append(id)
            }
        }
        return reads
    }
}

private extension WPEParityScenePass {
    var fboNames: [String] {
        var names = binds + [target].compactMap(\.self)
        if case let .copy(source?) = kind {
            names.append(source)
        }
        return names
    }
}
