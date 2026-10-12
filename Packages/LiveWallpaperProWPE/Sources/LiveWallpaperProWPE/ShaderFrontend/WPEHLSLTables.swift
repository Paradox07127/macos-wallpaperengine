/// Tables read from wallpaper64.exe that the GLSL-dialect rewriter indexes into.
enum WPEHLSLTables {
    /// Type table @0x140482eb0; the index is the WPE type id used everywhere below.
    static let glslTypes: [[UInt8]] = [
        "float", "vec2", "vec3", "vec4", "mat3", "mat4x3", "mat4", "sampler2D", "sampler2DBackBuffer",
        "sampler2DComparison", "sampler3D", "int", "ivec4", "uint", "uvec4",
    ].map(Latin1.bytes)

    static let hlslTypes: [String] = [
        "float", "float2", "float3", "float4", "float3x3", "float4x3", "float4x4", "sampler", "sampler",
        "samplerComparison", "sampler", "int", "int4", "uint", "uint4",
    ]

    /// Element type an array of each type is packed into (@0x140482e30).
    static let packedTypes = [3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 12, 12, 14, 14]

    /// Types whose arrays are packed: float, vec2, int, uint (bitmask 0x2803).
    static let packableTypes: Set<Int> = [0, 1, 11, 13]

    static let float4Type = 3
    static let float2Type = 1
    static let uintType = 13
    static let backBufferSamplerType = 8
    static let comparisonSamplerType = 9
    static let sampler3DType = 10

    static let semantics = ["POSITION", "NORMAL", "TANGENT", "TEXCOORD", "COLOR", "BLENDINDICES", "BLENDWEIGHT"]

    struct Attribute {
        let name: [UInt8]
        let hlslType: Int
        let semantic: Int
        let semanticIndex: Int
    }

    /// Attribute table @0x140484a90 with records @0x140482fa0; the first whole-word hit in this order wins.
    static let attributes: [Attribute] = ([
        ("a_Position", 2, 0, 0), ("a_PositionVec4", 3, 0, 0), ("a_PositionC1", 2, 0, 1),
        ("a_Normal", 2, 1, 0), ("a_Tangent4", 3, 2, 0), ("a_BlendIndices", 14, 5, 0),
        ("a_BlendWeights", 3, 6, 0), ("a_TexCoord", 1, 3, 0), ("a_TexCoordVec3", 2, 3, 0),
        ("a_TexCoordVec4", 3, 3, 0), ("a_TexCoordC1", 1, 3, 1), ("a_TexCoordVec3C1", 2, 3, 1),
        ("a_TexCoordVec4C1", 3, 3, 1), ("a_TexCoordC2", 1, 3, 2), ("a_TexCoordVec3C2", 2, 3, 2),
        ("a_TexCoordVec4C2", 3, 3, 2), ("a_TexCoordC3", 1, 3, 3), ("a_TexCoordVec3C3", 2, 3, 3),
        ("a_TexCoordVec4C3", 3, 3, 3), ("a_TexCoordC4", 1, 3, 4), ("a_TexCoordVec3C4", 2, 3, 4),
        ("a_TexCoordVec4C4", 3, 3, 4), ("a_TexCoordC5", 1, 3, 5), ("a_TexCoordVec3C5", 2, 3, 5),
        ("a_TexCoordVec4C5", 3, 3, 5), ("a_Color", 3, 4, 0),
    ] as [(String, Int, Int, Int)]).map { Attribute(name: Latin1.bytes($0.0), hlslType: $0.1, semantic: $0.2, semanticIndex: $0.3) }

    /// Engine uniform names in code order (static initializer FUN_140002860).
    static let uniformNames: [String] = {
        var names = [
            "g_Alpha", "g_Color", "g_Color4", "g_Time", "g_Frametime", "g_Daytime", "g_TexelSizeHalf",
            "g_TexelSize", "g_Screen", "g_ModelMatrix", "g_ModelMatrixInverse", "g_ViewProjectionMatrix",
            "g_ModelViewProjectionMatrixInverse", "g_ModelViewProjectionMatrix", "g_NormalModelMatrix",
            "g_AltModelMatrix", "g_AltNormalModelMatrix", "g_AltViewProjectionMatrix",
            "g_ViewportViewProjectionMatrices", "g_EffectModelMatrix", "g_EffectModelViewProjectionMatrix",
            "g_EffectModelViewProjectionMatrixInverse", "g_EffectTextureProjectionMatrix",
            "g_EffectTextureProjectionMatrixInverse", "g_LayerModelMatrix", "g_EyePosition", "g_ViewForward",
            "g_ViewRight", "g_ViewUp", "g_OrientationForward", "g_OrientationRight", "g_OrientationUp",
        ]
        for suffix in ["", "Rotation", "Translation", "Resolution", "Texel", "MipMapInfo"] {
            names += (0 ..< 10).map { "g_Texture\($0)\(suffix)" }
        }
        names += [
            "g_TextureReductionScale", "g_LightsColorRadius", "g_LightsColorPremultiplied", "g_LightsPosition",
            "g_LightAmbientColor", "g_LightSkylightColor", "g_AudioSpectrum16Left", "g_AudioSpectrum16Right",
            "g_AudioSpectrum32Left", "g_AudioSpectrum32Right", "g_AudioSpectrum64Left", "g_AudioSpectrum64Right",
            "g_PointerPositionLast", "g_PointerPosition", "g_PointerState", "g_ParallaxPosition",
            "g_RenderVar0", "g_RenderVar1", "g_RenderVar2", "g_RenderVar3", "g_RenderVar4", "g_Bones",
            "g_BonesAlpha", "g_BlendMap", "g_MorphOffsets", "g_MorphWeights", "g_MorphBoneTransform",
            "g_MorphBoneRules", "g_LPoint_Color", "g_LPoint_Origin", "g_LSpot_Color", "g_LSpot_Origin",
            "g_LSpot_Direction", "g_LSpot_Exponent", "g_LTube_Color", "g_LTube_OriginA", "g_LTube_OriginB",
            "g_LDirectional_Color", "g_LDirectional_Direction", "g_LFeature_ShadowProjection",
            "g_LFeature_ShadowProjectionTransform", "g_LFeature_ShadowPointProjection",
            "g_LFeature_ShadowPointProjectionTransform", "g_FogDistanceColor", "g_FogDistanceParams",
            "g_FogHeightColor", "g_FogHeightParams", "g_HDRParams",
        ]
        return names
    }()

    static let uniformCodes: [[UInt8]: Int] = Dictionary(
        uniqueKeysWithValues: uniformNames.enumerated().map { (Latin1.bytes($0.element), $0.offset) }
    )

    /// Code of `g_Texture0`; texture register = code - this.
    static let firstTextureCode = 0x20

    enum UniformBucket {
        case staticBuffer, dynamicBuffer, animationBuffer, lightsBuffer, texture, dropped
    }

    /// The uniform switch in FUN_1400f5cb0; names missing from the table land in g_bufStatic.
    static func uniformBucket(_ code: Int?) -> UniformBucket {
        guard let code, code >= 0 else { return .staticBuffer }
        switch code {
        case 0x20 ... 0x29: return .texture
        case 0x8C: return .dropped
        case 0x71: return .animationBuffer
        case 0x78 ... 0x86: return .lightsBuffer
        case 6, 7, 8, 0x5C: return .staticBuffer
        case 0x8B...: return .staticBuffer
        default: return .dynamicBuffer
        }
    }

    /// System values that become extra `main` parameters (FUN_140001640).
    static func systemValue(_ name: [UInt8]) -> (type: Int, semantic: String)? {
        switch Latin1.string(name) {
        case "gl_VertexID": (uintType, "SV_VERTEXID")
        case "gl_InstanceID": (uintType, "SV_INSTANCEID")
        default: nil
        }
    }

    static let prelude: [UInt8] = Latin1.bytes([
        "#define vec2 float2", "#define vec3 float3", "#define vec4 float4", "#define uvec4 uint4",
        "#define mat4 float4x4", "#define mat4x3 float4x3", "#define mat3 float3x3", "#define mat2 float2x2",
        "#define mix lerp", "#define mod(x, y) ((x)-(y)*floor((x)/(y)))", "#define CASTI(x) ((int)(x))",
        "#define CASTU(x) ((uint)(x))", "#define CASTF(x) ((float)(x))", "#define CAST2(x) ((float2)(x))",
        "#define CAST3(x) ((float3)(x))", "#define CAST4U(x) ((uint4)(x))", "#define CAST4(x) ((float4)(x))",
        "#define CAST3X3(x) ((float3x3)(x))",
        "#define DECLARE_SAMPLER2D_PARAMETER(t) Texture2D t, SamplerState t ## SamplerState",
        "#define MAKE_SAMPLER2D_ARGUMENT(t) t, t ## SamplerState",
        "#define DECLARE_SAMPLER2D_COMPARE_PARAMETER(t) Texture2D t, SamplerComparisonState t ## SamplerComparisonState",
        "#define MAKE_SAMPLER2D_COMPARE_ARGUMENT(t) t, t ## SamplerComparisonState",
        "#define texSample2D(s, u) s.Sample(s ## SamplerState, u)",
        "#define texSample2DLod(s, u, m) s.SampleLevel(s  ## SamplerState, u, m)",
        "#define texSample2DCompare(s, u, d) s.SampleCmpLevelZero(s ## SamplerComparisonState, u, d)",
        "#define texLoad2D(s, u, r) s.Load(int3((u) * (r), 0))",
        "#define texSample3D(s, u) s.Sample(s ## SamplerState, u)",
    ].map { $0 + "\n" }.joined())

    static let backBufferMSLine = Latin1.bytes("#define texSample2DBackBuffer(s, u, r) s.Load(int2((u) * (r)), 0)\n")
    static let backBufferLine = Latin1.bytes("#define texSample2DBackBuffer(s, u, r) texSample2D(s, (u))\n")
}
