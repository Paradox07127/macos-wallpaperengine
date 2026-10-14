/// An effect FBO as its effect file declares it.
struct WPEParityAuthoredFBO: Sendable {
    let name: String
    let scale: Double
    let fit: Double?
    let format: String
    /// The FBO a `swap` command of the same effect exchanges it with.
    let swapPartner: String?
    let unique: Bool
    var explicitWidth: Double?
    var explicitHeight: Double?
    var initialClear: WPEClearColor?
    var repeats = false

    /// FUN_1401e63b0: arrays and each object in them are AND groups. Missing combo values are integer zero;
    /// nonarrays and nonobject elements are accepted. PE constants fix op/ge/gt/le/lt (see wave1 raw evidence).
    static func conditionsMatch(_ conditions: WPESceneJSONValue?, combos: WPESceneJSONValue?) -> Bool {
        guard case let .array(groups)? = conditions else { return true }
        func integer(_ value: WPESceneJSONValue?) -> Int32 {
            guard case let .number(number)? = value else { return 0 }
            return Int32(exactly: number.rounded(.towardZero)) ?? 0
        }
        for group in groups {
            guard case let .object(entries) = group else { continue }
            for (name, condition) in entries {
                let actual = integer(combos?[name])
                switch condition {
                case .number:
                    if actual != integer(condition) {
                        return false
                    }
                case let .object(specification):
                    let expected = integer(specification["value"])
                    let operation: String = if case let .string(value)? = specification["op"] {
                        value
                    } else {
                        ""
                    }
                    let accepted: Bool = switch operation {
                    case "ge": actual >= expected
                    case "gt": actual > expected
                    case "le": actual <= expected
                    case "lt": actual < expected
                    default: actual == expected
                    }
                    if !accepted {
                        return false
                    }
                default:
                    break
                }
            }
        }
        return true
    }
}

/// One effect file pass before its FBO names resolve against the scene.
struct WPEParityAuthoredPass: Sendable {
    enum Kind: Sendable {
        case draw
        /// A nil source is `previous`.
        case copy(source: String?)
        case swap(first: String, second: String)
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
        if case let .swap(first, second) = kind {
            names += [first, second]
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
    var width: Int
    var height: Int
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
    func parityFBO(shared: Bool, format: String,
                   physicalCanvasSize: (SIMD2<Int>) -> SIMD2<Int> = { $0 },
                   pixelScale: Double = 1) -> WPEParitySceneFBO {
        // Validate the raw uint16 overrides first. Mac scaling must never turn a rejected author value into an
        // accepted override. Convert the undivided base, then apply the original Float fit and integer divisor.
        let logical = baseExtent
        let base = physicalCanvasSize(SIMD2(logical.width, logical.height))
        var fitted = base
        if let logicalFit = explicitExtent(fbo.fit), max(base.x, base.y) > 0 {
            let edge = min(Int(Double(logicalFit) * pixelScale), max(base.x, base.y))
            fitted = base.x < base.y
                ? SIMD2(Int(Float(base.x) / Float(base.y) * Float(edge)), edge)
                : SIMD2(edge, Int(Float(base.y) / Float(base.x) * Float(edge)))
        }
        let size = SIMD2(max(2, Int(Double(fitted.x) / divisor)), max(2, Int(Double(fitted.y) / divisor)))
        return WPEParitySceneFBO(name: fbo.name, width: size.x, height: size.y, format: format,
                                 shared: shared, swapPartner: local ? fbo.swapPartner : nil, unique: fbo.unique,
                                 unscaledSize: fitted,
                                 scale: Int(divisor), sizing: WPEParitySceneFBOSizing(
                                     scale: fbo.scale, fit: fbo.fit, width: fbo.explicitWidth, height: fbo.explicitHeight,
                                     layerSize: SIMD2(width, height)
                                 ), initialClear: fbo.initialClear, repeats: fbo.repeats)
    }

    /// Native scale is an integer byte (+0xc); keep zero safe rather than reproducing integer division by zero.
    private var divisor: Double {
        let integer = Int32(exactly: fbo.scale.rounded(.towardZero)) ?? 1
        return Double(max(1, UInt8(truncatingIfNeeded: integer)))
    }

    /// Native width/height/fit are uint16; only values <= 4096 override the layer extent (1401ea500:537-574).
    private func explicitExtent(_ value: Double?) -> Int? {
        guard let value, let integer = Int32(exactly: value.rounded(.towardZero)) else { return nil }
        let native = Int(UInt16(truncatingIfNeeded: integer))
        return native <= 4096 ? native : nil
    }

    private var baseExtent: (width: Int, height: Int) {
        (explicitExtent(fbo.explicitWidth) ?? width, explicitExtent(fbo.explicitHeight) ?? height)
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

public extension WPEParitySceneFBO {
    /// Reuses the declaration converter; no ratio inferred from an already rounded allocation size.
    func resized(layerWidth: Int, layerHeight: Int,
                 physicalCanvasSize: (SIMD2<Int>) -> SIMD2<Int> = { $0 },
                 pixelScale: Double = 1) -> WPEParitySceneFBO {
        guard let sizing else {
            // Caller-created absolute FBOs have no raw declaration to re-evaluate.
            var result = self
            let size = physicalCanvasSize(SIMD2(width, height))
            result.width = size.x
            result.height = size.y
            result.unscaledSize = physicalCanvasSize(unscaledSize)
            return result
        }
        let authored = WPEParityAuthoredFBO(name: name, scale: sizing.scale, fit: sizing.fit, format: format,
                                            swapPartner: swapPartner, unique: unique,
                                            explicitWidth: sizing.width, explicitHeight: sizing.height,
                                            initialClear: initialClear, repeats: repeats)
        let declaration = WPEParitySceneFBOScope.Declaration(fbo: authored, width: layerWidth,
                                                             height: layerHeight, local: true)
        return declaration.parityFBO(shared: shared, format: format,
                                     physicalCanvasSize: physicalCanvasSize, pixelScale: pixelScale)
    }
}

private extension WPEParityAuthoredPass {
    /// `nil` for a `copy` whose source or target does not resolve; catsout's WPSceneParser.cpp skips those too.
    func resolved(_ visible: [String: WPEParitySceneFBOScope.Declaration]) -> WPEParityScenePass? {
        let target = target.flatMap { visible[$0] == nil ? nil : $0 }
        if case let .swap(first, second) = kind {
            guard visible[first] != nil, visible[second] != nil, first != second else { return nil }
            return WPEParityScenePass(shader: shader, kind: .swap(first: first, second: second))
        }
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
        if case let .swap(first, second) = kind {
            names += [first, second]
        }
        return names
    }
}
