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

    /// With shadow quality 0 (render context +0x1ac) `spotshadowcookie` only adds cookies and the other shadow keys
    /// are not read.
    public init(general: WPESceneJSONValue?, shadowQuality: Int32 = 0) {
        let config = general?["lightconfig"]
        func count(_ key: String, _ mask: Int32) -> Int32 {
            guard case let .number(value)? = config?[key], value >= 0,
                  value <= Double(UInt32.max), value.rounded(.towardZero) == value else { return 0 }
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
    public var tubeColor: [SIMD4<Float>] = []
    public var tubeOriginA: [SIMD4<Float>] = []
    public var tubeOriginB: [SIMD4<Float>] = []
    public var directionalColor: [SIMD4<Float>] = []
    /// float3 in the cbuffer (lightsCBuffer); WPE stages it as a float4 with w = 0.
    public var directionalDirection: [SIMD3<Float>] = []
    /// Shadow view-projections (P · V) and atlas rects by projection slot; see WPEParityShadowLayout.
    public var shadowProjection: [simd_float4x4] = []
    public var shadowProjectionTransform: [SIMD4<Float>] = []
    public var shadowPointProjection: [SIMD4<Float>] = []
    public var shadowPointProjectionTransform: [SIMD4<Float>] = []

    public init(ambient: SIMD3<Float>, skylight: SIMD3<Float>) {
        self.ambient = ambient
        self.skylight = skylight
    }

    public init(document: WPESceneDocument) {
        func color(_ name: String) -> SIMD3<Float> {
            let raw = document.resolvedGeneralJSON[name]
            let value = raw?["value"] ?? raw
            // 140199780 binds both colours to 1a4230; do not use the generic vector parser here.
            switch value {
            case let .number(number)?: return SIMD3(repeating: Float(number))
            case let .string(text)?: return WPEParityNumericConversion.asciiSpaceVector3(text)
            default: return .zero
            }
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
    /// With `shadowQuality` ≠ 0 casting lights fill each type's leading shadow section (140190c80.c:536-580).
    public init(document: WPESceneDocument, transforms: WPEParityLayerTransformSet, state: WPEParitySceneState?,
                shadowQuality: Int32 = 0, shadows: WPEParityShadowLayout? = nil) {
        self.init(document: document)
        for (name, keyPath) in [("ambientcolor", \Self.ambient), ("skylightcolor", \Self.skylight)] {
            if case let .vector(value)? = state?.scriptField(name, of: "") {
                self[keyPath: keyPath] = SIMD3(value.x, value.y, value.z)
            }
        }
        if let shadows {
            shadowProjection = shadows.projections
            shadowProjectionTransform = shadows.projectionTransforms
            shadowPointProjection = shadows.pointProjections
            shadowPointProjectionTransform = shadows.pointProjectionTransforms
        }
        let config = WPEParityLightConfig(general: document.resolvedGeneralJSON, shadowQuality: shadowQuality)
        let degrees = Float.pi / 180
        // Per type: lights left, next shadow slot, next plain slot. Spot cookie sections stay empty.
        var point = (left: config.point, shadow: 0, plain: Int(config.pointShadow))
        let spotShadowBase = Int(config.spotShadowCookie + config.spotCookie)
        var spot = (left: config.spot, shadow: spotShadowBase,
                    plain: shadowQuality == 0 ? 0 : spotShadowBase + Int(config.spotShadow))
        var directional = (left: config.directional, shadow: 0, plain: Int(config.directionalShadow))
        for light in document.lightObjects where state?.isVisible(light.id) ?? light.visible {
            let casts = shadowQuality != 0 && light.castShadow
            func slot(_ cursor: inout (left: Int32, shadow: Int, plain: Int)) -> Int {
                cursor.left -= 1
                if casts {
                    cursor.shadow += 1
                    return cursor.shadow - 1
                }
                cursor.plain += 1
                return cursor.plain - 1
            }
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
            case .point where point.left > 0:
                let index = slot(&point), capacity = Int(config.point)
                pointColor.setSlot(index, color, capacity: capacity, zero: .zero)
                pointOrigin.setSlot(index, SIMD4(origin, exponent), capacity: capacity, zero: .zero)
            case .spot where spot.left > 0:
                let index = slot(&spot), capacity = Int(config.spot)
                let inner = cos(scalar("innercone", light.innerConeDegrees) * degrees)
                let outer = cos(scalar("outercone", light.outerConeDegrees) * degrees)
                spotColor.setSlot(index, color, capacity: capacity, zero: .zero)
                spotOrigin.setSlot(index, SIMD4(origin, inner), capacity: capacity, zero: .zero)
                spotDirection.setSlot(index, SIMD4(axis, outer), capacity: capacity, zero: .zero)
                spotExponent.setSlot(index, SIMD4(exponent, 0, 0, 0), capacity: capacity, zero: .zero)
            case .tube where tubeColor.count < config.tube:
                // 140190c80.c:832–893: the second endpoint is W · (controlpoint, 1), not an axis or direction.
                let point: SIMD3<Float> = if case let .vector(value)? = state?.scriptField("controlpoint", of: light.id) {
                    SIMD3(value.x, value.y, value.z)
                } else if let values = light.fieldBindings["controlpoint"]?.resolvedValue?.vectorValue {
                    SIMD3(values.indices.contains(0) ? Float(values[0]) : 0,
                          values.indices.contains(1) ? Float(values[1]) : 0,
                          values.indices.contains(2) ? Float(values[2]) : 0)
                } else if let value = light.fieldBindings["controlpoint"]?.resolvedValue?.numberValue {
                    SIMD3(repeating: Float(value))
                } else {
                    SIMD3(2, 0, 0)
                }
                let first = world.columns.1 * point.y + world.columns.0 * point.x
                let second = world.columns.3 + world.columns.2 * point.z
                let end = second + first
                tubeColor.append(color)
                tubeOriginA.append(SIMD4(origin, exponent))
                tubeOriginB.append(SIMD4(end.x, end.y, end.z, 0))
            case .directional where directional.left > 0:
                let index = slot(&directional), capacity = Int(config.directional)
                directionalColor.setSlot(index, SIMD4(color.x, color.y, color.z, 1), capacity: capacity, zero: .zero)
                directionalDirection.setSlot(index, -axis, capacity: capacity, zero: .zero)
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
            ("g_LTube_Color", tubeColor), ("g_LTube_OriginA", tubeOriginA),
            ("g_LDirectional_Color", directionalColor),
            ("g_LFeature_ShadowProjectionTransform", shadowProjectionTransform),
            ("g_LFeature_ShadowPointProjection", shadowPointProjection),
            ("g_LFeature_ShadowPointProjectionTransform", shadowPointProjectionTransform),
        ]
        for (name, array) in arrays where !array.isEmpty {
            values[name] = .array(array.map { .vector([$0.x, $0.y, $0.z, $0.w]) })
        }
        if !shadowProjection.isEmpty {
            values["g_LFeature_ShadowProjection"] = .array(shadowProjection.map { .wpeTransposed($0) })
        }
        // The shared HLSL lighting cbuffer stages endpoint B as float3, like directional direction.
        if !tubeOriginB.isEmpty {
            values["g_LTube_OriginB"] = .array(tubeOriginB.map { .vector([$0.x, $0.y, $0.z]) })
        }
        if !directionalDirection.isEmpty {
            values["g_LDirectional_Direction"] = .array(directionalDirection.map { .vector([$0.x, $0.y, $0.z]) })
        }
        return values
    }
}
