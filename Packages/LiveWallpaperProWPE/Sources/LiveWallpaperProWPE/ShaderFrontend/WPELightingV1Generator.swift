/// `#require LightingV1` generator (FUN_140169140): light uniforms followed by `PerformLighting_V1`.
/// The preprocessor inserts it at the directive's `#`; the rewriter later moves the uniforms to g_bufLights.
enum WPELightingV1Generator {
    private static let head = "vec3 PerformLighting_V1(vec3 worldPos, vec3 color, vec3 normal, vec3 viewVector, "
        + "vec3 specularTint, vec3 ambient, float roughness, float metallic)\n{\n\tvec3 light = CAST3(0.0);\n"
    private static let pointDelta = "\tvec3 lightDelta = g_LPoint_Origin[i].xyz - worldPos;\n"
    private static let spotDelta = "\tvec3 lightDelta = g_LSpot_Origin[i].xyz - worldPos;\n"
    private static let spotProjection =
        "\tvec3 projectedCoords = CalculateProjectedCoords(worldPos, g_LFeature_ShadowProjection[i]);\n"
    private static let spotShadowFactor =
        "\tfloat shadowFactor = PerformShadowMapping(projectedCoords, g_LFeature_ShadowProjectionTransform[i]);\n"
    private static let spotCookie = "\tvec3 colorCookie = texSample2D(COOKIE_SAMPLER, projectedCoords.xy).rgb;\n"
    private static let spotCone = "\tfloat spotCookie = -dot(normalize(lightDelta), g_LSpot_Direction[i].xyz);\n"
        + "\tspotCookie = smoothstep(g_LSpot_Direction[i].w, g_LSpot_Origin[i].w, spotCookie);\n"
    private static let cascade = [
        "\tvec4 projectedCoords1 = CalculateProjectedCoordsCascades(worldPos, g_LFeature_ShadowProjection[p1]);",
        "\tvec4 projectedCoords2 = CalculateProjectedCoordsCascades(worldPos, g_LFeature_ShadowProjection[p2]);",
        "\tvec4 projectedCoords3 = CalculateProjectedCoordsCascades(worldPos, g_LFeature_ShadowProjection[p3]);",
        "\tprojectedCoords1.xyz = mix(projectedCoords1.xyz, projectedCoords2.xyz, projectedCoords1.w);",
        "\tprojectedCoords1.xyz = mix(projectedCoords1.xyz, projectedCoords3.xyz, projectedCoords2.w);",
        "\tvec4 uvTransforms = mix(g_LFeature_ShadowProjectionTransform[p1], g_LFeature_ShadowProjectionTransform[p2], projectedCoords1.w);",
        "\tuvTransforms = mix(uvTransforms, g_LFeature_ShadowProjectionTransform[p3], projectedCoords2.w);",
        "\tfloat shadowFactor = max(projectedCoords3.w, PerformShadowMapping(projectedCoords1.xyz, uvTransforms));",
    ].map { $0 + "\n" }.joined()

    private static func pbr(_ color: String, _ intensity: String, _ radius: String, _ shadow: String) -> String {
        "\tlight += ComputePBRLightShadow(normal, lightDelta, viewVector, color, \(color), \(intensity), \(radius), "
            + "specularTint, ambient, roughness, metallic, \(shadow));\n"
    }

    private static func infinite(_ shadow: String) -> String {
        "\tlight += ComputePBRLightShadowInfinite(normal, g_LDirectional_Direction[i].xyz, viewVector, color, "
            + "g_LDirectional_Color[i].rgb, specularTint, ambient, roughness, metallic, \(shadow));\n"
    }

    /// Empty unless the argument is `LightingV1` and LIGHTING is non-zero. The nine LIGHTS_* counts are read
    /// with `unordered_map::at`, so a missing one is an error.
    static func generate(argument: [UInt8], defines: WPEShaderMacros) throws -> [UInt8] {
        guard argument == Latin1.bytes("LightingV1"), let lighting = defines[Latin1.bytes("LIGHTING")],
              atoi(lighting) != 0 else { return [] }
        func count(_ key: String) throws -> Int {
            guard let value = defines[Latin1.bytes(key)] else { throw WPEHLSLRewriteError.missingDefine(key) }
            return atoi(value)
        }
        let point = try count("LIGHTS_POINT")
        let spot = try count("LIGHTS_SPOT")
        let tube = try count("LIGHTS_TUBE")
        let directional = try count("LIGHTS_DIRECTIONAL")
        let spotShadowCookie = try count("LIGHTS_SPOT_SHADOW_COOKIE")
        let spotShadow = try count("LIGHTS_SPOT_SHADOW")
        let spotCookieCount = try count("LIGHTS_SPOT_COOKIE")
        let directionalShadow = try count("LIGHTS_DIRECTIONAL_SHADOW")
        let pointShadow = try count("LIGHTS_POINT_SHADOW")

        var o = ""
        func uniforms(_ type: String, _ names: [String], _ n: Int) {
            for name in names {
                o += "uniform \(type) \(name)[\(n)];\n"
            }
        }
        func block(_ i: Int, _ lines: String...) {
            o += "{\n\tconst uint i = \(i)u;\n" + lines.joined() + "}\n"
        }
        if point != 0 {
            uniforms("vec4", ["g_LPoint_Color", "g_LPoint_Origin"], point)
        }
        if spot != 0 {
            uniforms("vec4", ["g_LSpot_Color", "g_LSpot_Origin", "g_LSpot_Direction", "g_LSpot_Exponent"], spot)
        }
        if tube != 0 {
            uniforms("vec4", ["g_LTube_Color", "g_LTube_OriginA", "g_LTube_OriginB"], tube)
        }
        if directional != 0 {
            uniforms("vec4", ["g_LDirectional_Color", "g_LDirectional_Direction"], directional)
        }
        // The array size argument is elided in the decompile; assumed equal to the sum the branch tests.
        let projections = spotCookieCount + directionalShadow * 3 + spotShadow + spotShadowCookie
        if projections != 0 {
            uniforms("mat4", ["g_LFeature_ShadowProjection"], projections)
            uniforms("vec4", ["g_LFeature_ShadowProjectionTransform"], projections)
        }
        if pointShadow != 0 {
            uniforms("vec4", ["g_LFeature_ShadowPointProjection", "g_LFeature_ShadowPointProjectionTransform"], pointShadow)
        }
        o += head
        let pointArgs = ("g_LPoint_Color[i].rgb", "g_LPoint_Color[i].w", "g_LPoint_Origin[i].w")
        var i = 0
        while i < pointShadow {
            block(
                i, pointDelta,
                "\tvec4 projectedCoords = CalculateProjectedCoordsPoint(worldPos, g_LPoint_Origin[i].xyz, "
                    + "g_LFeature_ShadowPointProjection[i], g_LFeature_ShadowPointProjectionTransform[i]);\n",
                "\tfloat shadowFactor = PerformPointShadowMapping(projectedCoords);\n",
                pbr(pointArgs.0, pointArgs.1, pointArgs.2, "shadowFactor")
            )
            i += 1
        }
        while i < point {
            block(i, pointDelta, pbr(pointArgs.0, pointArgs.1, pointArgs.2, "1.0"))
            i += 1
        }
        func spotLight(_ color: String, _ shadow: String) -> String {
            pbr(color, "g_LSpot_Color[i].w", "g_LSpot_Exponent[i].x", shadow)
        }
        let cookieColor = "g_LSpot_Color[i].rgb * colorCookie"
        let coneColor = "g_LSpot_Color[i].rgb * spotCookie"
        var k = 0
        for _ in 0 ..< max(0, spotShadowCookie) {
            block(k, spotDelta, spotProjection, spotShadowFactor, spotCookie, spotLight(cookieColor, "shadowFactor"))
            k += 1
        }
        for _ in 0 ..< max(0, spotCookieCount) {
            block(k, spotDelta, spotProjection, spotCookie, spotLight(cookieColor, "1.0"))
            k += 1
        }
        for _ in 0 ..< max(0, spotShadow) {
            block(k, spotDelta, spotCone, spotProjection, spotShadowFactor, spotLight(coneColor, "shadowFactor"))
            k += 1
        }
        // First cascade slot = number of spot shadow/cookie projections.
        var cascadeBase = k
        while k < spot {
            block(k, spotDelta, spotCone, spotLight(coneColor, "1.0"))
            k += 1
        }
        for t in 0 ..< max(0, tube) {
            block(
                t,
                "\tvec3 lightDelta = PointSegmentDelta(worldPos, g_LTube_OriginA[i].xyz, g_LTube_OriginB[i].xyz);\n",
                pbr("g_LTube_Color[i].rgb", "g_LTube_Color[i].w", "g_LTube_OriginA[i].w", "1.0")
            )
        }
        var d = 0
        while d < directionalShadow {
            let slots = "\tconst uint p1 = \(cascadeBase)u;\n\tconst uint p2 = \(cascadeBase + 1)u;\n"
                + "\tconst uint p3 = \(cascadeBase + 2)u;\n"
            block(d, slots, cascade, infinite("shadowFactor"))
            // The decompile advances the base by one, not three, so consecutive cascades overlap.
            cascadeBase += 1
            d += 1
        }
        while d < directional {
            block(d, infinite("1.0"))
            d += 1
        }
        o += "\treturn light;\n}\n"
        return Latin1.bytes(o)
    }

    /// `atoi`-like: optional leading whitespace and sign, then decimal digits; 0 when none.
    private static func atoi(_ s: [UInt8]) -> Int {
        var k = 0
        while k < s.count, Latin1.isSpace(s[k]) {
            k += 1
        }
        var negative = false
        if k < s.count, s[k] == 0x2B || s[k] == 0x2D {
            negative = s[k] == 0x2D
            k += 1
        }
        var value = 0
        while k < s.count, Latin1.isASCIIDigit(s[k]) {
            value = value &* 10 &+ Int(s[k] - 0x30)
            k += 1
        }
        return negative ? 0 &- value : value
    }
}
