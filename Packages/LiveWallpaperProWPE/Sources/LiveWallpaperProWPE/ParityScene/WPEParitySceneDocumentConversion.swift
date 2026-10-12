public enum WPEParitySceneConversionError: Error, Hashable, Sendable {
    /// An effect FBO `format` names no format the parity frame knows how to allocate.
    case unknownFBOFormat(String)
}

/// An effect FBO as its effect file declares it.
struct WPEParityAuthoredFBO: Sendable {
    let name: String
    let scale: Double
    let fit: Double?
    let format: String
    /// The FBO a `swap` command of the same effect exchanges it with.
    let swapPartner: String?
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
    let enabled: Bool
    let fbos: [WPEParityAuthoredFBO]
    let passes: [WPEParityAuthoredPass]
}

struct WPEParityAuthoredObject: Sendable {
    let id: String
    /// Extent the object's FBOs are sized from.
    let width: Int
    let height: Int
    let effects: [WPEParityAuthoredEffect]

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

    func effects(of object: WPEParityAuthoredObject) throws(WPEParitySceneConversionError)
        -> [WPEParitySceneEffect] {
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
                try declared.append(declaration.parityFBO(shared: shared.contains(name),
                                                          backbufferFormat: backbufferFormat))
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
    func parityFBO(shared: Bool,
                   backbufferFormat: String) throws(WPEParitySceneConversionError) -> WPEParitySceneFBO {
        let size = extent
        return try WPEParitySceneFBO(name: fbo.name, width: size.width, height: size.height,
                                     format: Self.metalFormat(fbo.format, backbufferFormat: backbufferFormat),
                                     shared: shared, swapPartner: local ? fbo.swapPartner : nil)
    }

    /// `fit` over the object extent, else the object extent divided by `scale`.
    var extent: (width: Int, height: Int) {
        // catsout WPImageObject.cpp parses `scale` as uint32_t and resets 0 to 1, so fractions truncate and a scale
        // below 1 never enlarges; WPSceneParser.cpp truncates `size / scale`.
        let divisor = max(1, fbo.scale.rounded(.towardZero))
        if let fit = fbo.fit, fit > 0, max(width, height) > 0 {
            let ratio = fit / Double(max(width, height))
            return (max(1, Int((Double(width) * ratio).rounded())), max(1, Int((Double(height) * ratio).rounded())))
        }
        return (max(1, Int(Double(width) / divisor)), max(1, Int(Double(height) / divisor)))
    }

    static func metalFormat(_ format: String,
                            backbufferFormat: String) throws(WPEParitySceneConversionError) -> String {
        switch format.lowercased() {
        case "rgba8888": "rgba8unorm"
        case "rgba16f", "rgba_half", "rgba16161616f": "rgba16float"
        case "r8", "r8unorm": "r8unorm"
        case "rg88": "rg8unorm"
        case "r16f": "r16float"
        case "rg1616f": "rg16float"
        // No source found (catsout ignores FBO formats); read as the frame's backbuffer format.
        case "rgba_backbuffer": backbufferFormat
        default: throw .unknownFBOFormat(format)
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
        return WPEParityScenePass(shader: shader, target: target, binds: binds, compose: compose,
                                  readsFullFrameBuffer: textures.contains(WPESceneAliasName.fullFrameBuffer),
                                  blend: blend, source: source)
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
