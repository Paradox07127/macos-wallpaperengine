import simd

/// General `lightconfig`: the per-type light slots every LIGHTING material compiles for (render context +0x121c,
/// 140186c90.c:574-621); FUN_1401a5c40 turns them into the LIGHTS_* combos.
public struct WPEParityLightConfig: Sendable, Equatable {
    public var point: Int32 = 0
    public var spot: Int32 = 0
    public var tube: Int32 = 0
    public var directional: Int32 = 0
    public var spotCookie: Int32 = 0
    public var spotShadowCookie: Int32 = 0
    public var spotShadow: Int32 = 0
    public var directionalShadow: Int32 = 0
    public var pointShadow: Int32 = 0

    public init() {}

    /// With shadow quality 0 (render context +0x1ac) `spotshadowcookie` only adds cookies and the other shadow keys
    /// are not read.
    public init(general: WPESceneJSONValue?, shadowQuality: Int32 = 0) {
        let config = general?["lightconfig"]
        func count(_ key: String, _ mask: Int32) -> Int32 {
            guard let value = WPEParityProgramScene.number(config?[key]), value >= 0 else { return 0 }
            return Int32(truncatingIfNeeded: Int64(value)) & mask
        }
        point = count("point", 0xF)
        spot = count("spot", 0xF)
        tube = count("tube", 0xF)
        directional = count("directional", 0xF)
        spotCookie = count("spotcookie", 3)
        if shadowQuality == 0 {
            spotCookie |= count("spotshadowcookie", 3)
        } else {
            spotShadowCookie = count("spotshadowcookie", 3)
            spotShadow = count("spotshadow", 3)
            directionalShadow = count("directionalshadow", 3)
            pointShadow = count("pointshadow", 3)
        }
    }

    public func apply(to flags: inout WPEEngineComboFlags) {
        flags.pointLights = point
        flags.spotLights = spot
        flags.tubeLights = tube
        flags.directionalLights = directional
        flags.spotCookieLights = spotCookie
        flags.spotShadowCookieLights = spotShadowCookie
        flags.spotShadowLights = spotShadow
        flags.directionalShadowLights = directionalShadow
        flags.pointShadowLights = pointShadow
    }
}

/// Ambient / skylight are general's raw colours (140186c90.c:682-686); the g_L* arrays hold the visible lights in
/// file order, at most the `lightconfig` count per type (140190c80.c:593-1010).
public struct WPEParityUniformLights: Sendable, Equatable {
    public var ambient: SIMD3<Float>
    public var skylight: SIMD3<Float>
    public var pointColor: [SIMD4<Float>] = []
    public var pointOrigin: [SIMD4<Float>] = []
    public var spotColor: [SIMD4<Float>] = []
    public var spotOrigin: [SIMD4<Float>] = []
    public var spotDirection: [SIMD4<Float>] = []
    public var spotExponent: [SIMD4<Float>] = []
    public var directionalColor: [SIMD4<Float>] = []
    /// float3 in the cbuffer (lightsCBuffer); WPE stages it as a float4 with w = 0.
    public var directionalDirection: [SIMD3<Float>] = []

    public init(ambient: SIMD3<Float>, skylight: SIMD3<Float>) {
        self.ambient = ambient
        self.skylight = skylight
    }

    public init(document: WPESceneDocument) {
        func color(_ name: String) -> SIMD3<Float> {
            let raw = document.resolvedGeneralJSON[name]
            let value = raw?["value"] ?? raw
            guard case let .string(text)? = value else { return .zero }
            let components = text.split(separator: " ").compactMap { Float($0) }
            guard components.count >= 3 else { return .zero }
            return SIMD3(components[0], components[1], components[2])
        }
        // 140186c90 initializes absent ambient/skylight to zero. The generic parser's legacy white fallback must
        // not create light in parity scenes.
        self.init(ambient: color("ambientcolor"), skylight: color("skylightcolor"))
    }

    /// `transforms` gives each light's world matrix W. Colour is colour × intensity; point and spot origins are W's
    /// translation, the spot direction W's first column and the directional direction its negation, all unnormalised.
    public init(document: WPESceneDocument, transforms: WPEParityLayerTransformSet) {
        self.init(document: document, transforms: transforms, state: nil)
    }

    /// Rebuilds from one live state snapshot. Ancestor visibility, light fields and general colours are consumed
    /// together, so rebuilding moving lights cannot restore static ambient/skylight over a script write.
    public init(document: WPESceneDocument, transforms: WPEParityLayerTransformSet, state: WPEParitySceneState?) {
        self.init(document: document)
        for (name, keyPath) in [("ambientcolor", \Self.ambient), ("skylightcolor", \Self.skylight)] {
            if case let .vector(value)? = state?.scriptField(name, of: "") {
                self[keyPath: keyPath] = SIMD3(value.x, value.y, value.z)
            }
        }
        let config = WPEParityLightConfig(general: document.resolvedGeneralJSON)
        let degrees = Float.pi / 180
        for light in document.lightObjects where state?.isVisible(light.id) ?? light.visible {
            func scalar(_ name: String, _ fallback: Double) -> Float {
                if case let .vector(value)? = state?.scriptField(name, of: light.id) {
                    return value.x
                }
                return Float(fallback)
            }
            let world = transforms.world(light.id)
            let liveColor = state?.object(light.id)?.color ?? SIMD3<Float>(light.color)
            let color = SIMD4(liveColor * scalar("intensity", light.intensity), scalar("radius", light.radius))
            let origin = SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
            let axis = SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z)
            let exponent = scalar("exponent", light.exponent)
            switch light.type {
            case .point where pointColor.count < config.point:
                pointColor.append(color)
                pointOrigin.append(SIMD4(origin, exponent))
            case .spot where spotColor.count < config.spot:
                spotColor.append(color)
                spotOrigin.append(SIMD4(origin, cos(scalar("innercone", light.innerConeDegrees) * degrees)))
                spotDirection.append(SIMD4(axis, cos(scalar("outercone", light.outerConeDegrees) * degrees)))
                spotExponent.append(SIMD4(exponent, 0, 0, 0))
            case .directional where directionalColor.count < config.directional:
                directionalColor.append(SIMD4(color.x, color.y, color.z, 1))
                directionalDirection.append(-axis)
            default:
                break
            }
        }
    }

    public var values: [String: WPECBufferValue] {
        var values: [String: WPECBufferValue] = [
            "g_LightAmbientColor": .vector([ambient.x, ambient.y, ambient.z]),
            "g_LightSkylightColor": .vector([skylight.x, skylight.y, skylight.z]),
        ]
        let arrays = [
            ("g_LPoint_Color", pointColor), ("g_LPoint_Origin", pointOrigin), ("g_LSpot_Color", spotColor),
            ("g_LSpot_Origin", spotOrigin), ("g_LSpot_Direction", spotDirection), ("g_LSpot_Exponent", spotExponent),
            ("g_LDirectional_Color", directionalColor),
        ]
        for (name, array) in arrays where !array.isEmpty {
            values[name] = .array(array.map { .vector([$0.x, $0.y, $0.z, $0.w]) })
        }
        if !directionalDirection.isEmpty {
            values["g_LDirectional_Direction"] = .array(directionalDirection.map { .vector([$0.x, $0.y, $0.z]) })
        }
        return values
    }
}
