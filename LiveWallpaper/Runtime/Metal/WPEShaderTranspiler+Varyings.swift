#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

extension WPEShaderTranspiler {
    // MARK: - auto_sway varying reconstruction

    /// Fragment-side reconstruction of auto_sway v2 (uniform-only except UV-affine dots). v1/v3 keep the fallback.
    static func autoSwayVaryingReconstructionLines(
        varyings: [WPEVaryingDecl],
        availableUniforms: Set<String>,
        comboValues: [String: Int]
    ) -> [String] {
        let varyingNames = Set(varyings.map(\.name))
        guard varyingNames.contains("v_MotionRadian1"),
              varyingNames.contains("v_EndpointDirection1"),
              varyingNames.contains("v_TexCoord"),
              varyingNames.contains("v_aspect"),
              hasUniforms(
                "g_SpinCenter1", "g_SpinCenter2", "g_WindDirection2",
                "g_Inertia", "g_SigmentCount", "g_Speed", "g_GlobalTimeOffset",
                "g_GlobalWindOffset", "g_Time", "g_Texture0Resolution",
                "g_SmoothDistance", "g_DirectionalCompensation",
                in: availableUniforms
              ) else {
            return []
        }
        let nodeCount = min(max(comboValues["NODE_COUNT"] ?? 2, 2), 11)
        let autoTimeoffset = (comboValues["AUTO_TIMEOFFSET"] ?? 1) == 1
        let interpolation = comboValues["AUTO_TIMEOFFSET_INTERPOLATION"] ?? 0
        let usesExponent = (comboValues["EXPONENT"] ?? 0) == 1 && availableUniforms.contains("g_Exponent")
        let usesNoise = (comboValues["NOISE"] ?? 0) == 1
            && hasUniforms("g_NoiseSpeed", "g_Friction", "g_NoiseAmount", in: availableUniforms)
        let halfPi = "1.5707963267948966"

        /// Fold `linearStep` over compile-time constants. A zero span mirrors D3D saturate: 0/0 → 0, k/0 → 1.
        func stepValue(_ x: Double) -> Double {
            let span = Double(nodeCount) - 2
            let raw = (x - 2) / span
            let t = raw.isNaN ? 0 : min(max(raw, 0), 1)
            switch interpolation {
            case 1: return pow(t, 3)
            case 2: return pow(t, 4)
            case 3: return pow(t, 5)
            case 4: return 1 - (1 - pow(t, 2)).squareRoot()
            case 5: return 1 - cos(t * Double.pi * 0.5)
            case 6: return 1 - pow(1 - t, 3)
            case 7: return 1 - pow(1 - t, 4)
            case 8: return 1 - pow(1 - t, 5)
            case 9: return (1 - pow(t - 1, 2)).squareRoot()
            case 10: return sin(t * Double.pi * 0.5)
            default: return t
            }
        }

        var lines: [String] = []
        lines.append("    // auto_sway v2 vertex-stage state, reconstructed per-pixel (uniform-only + UV-affine).")
        lines.append("    v_aspect = g_Texture0Resolution.z / g_Texture0Resolution.w;")
        if varyingNames.contains("v_reciprocalAspect") {
            lines.append("    v_reciprocalAspect = 1.0 / v_aspect;")
        }
        lines.append("    v_TexCoord = float4(in.uv.x * v_aspect, in.uv.y, in.uv.x * v_aspect, in.uv.y);")
        lines.append("    {")
        lines.append("        float2 wpeAS_endpointC = float2(g_SpinCenter1.x * v_aspect, g_SpinCenter1.y);")
        lines.append("        float wpeAS_baseTime = g_GlobalTimeOffset + g_Time * g_Speed;")
        if autoTimeoffset {
            lines.append("        float wpeAS_motionOffset = g_Inertia * g_SigmentCount;")
        }
        if usesNoise {
            lines.append("        float2 wpeAS_friction = g_Friction;")
        }

        for node in 2...nodeCount {
            let i = node - 1
            let requiredVaryings = [
                "v_Direction\(i)", "v_EndpointDirection\(i)", "v_Len\(i)",
                "v_EndpointLen\(i)", "v_PosX\(i)", "v_EndpointPosX\(i)", "v_MotionRadian\(i)",
            ]
            guard requiredVaryings.allSatisfy(varyingNames.contains),
                  hasUniforms("g_SpinCenter\(node - 1)", "g_SpinCenter\(node)", "g_WindDirection\(node)", in: availableUniforms) else {
                continue
            }
            let nextWind = node == 11 ? halfPi
                : (availableUniforms.contains("g_WindDirection\(node + 1)") ? "g_WindDirection\(node + 1)" : "\(halfPi)")
            let thisTimeTerm: String
            let prevTimeTerm: String
            if autoTimeoffset {
                thisTimeTerm = "wpeAS_motionOffset * \(stepValue(Double(node)))"
                prevTimeTerm = "wpeAS_motionOffset * \(stepValue(Double(node + 1)))"
            } else {
                thisTimeTerm = availableUniforms.contains("g_TimeOffset\(node - 1)") ? "g_TimeOffset\(node - 1)" : "0.0"
                prevTimeTerm = node == 11 ? "0.0"
                    : (availableUniforms.contains("g_TimeOffset\(node)") ? "g_TimeOffset\(node)" : "0.0")
            }
            lines.append("        {")
            lines.append("            float2 wpeAS_thisC = float2(g_SpinCenter\(node - 1).x * v_aspect, g_SpinCenter\(node - 1).y);")
            lines.append("            float2 wpeAS_nextC = float2(g_SpinCenter\(node).x * v_aspect, g_SpinCenter\(node).y);")
            lines.append("            float2 wpeAS_nodeVec = wpeAS_thisC - wpeAS_nextC;")
            lines.append("            float2 wpeAS_eNodeVec = wpeAS_endpointC - wpeAS_nextC;")
            lines.append("            v_Direction\(i) = wpe_safe_normalize(wpeAS_nodeVec);")
            lines.append("            v_EndpointDirection\(i) = mix(wpe_safe_normalize(wpeAS_eNodeVec), v_Direction\(i), g_DirectionalCompensation);")
            lines.append("            v_Len\(i) = dot(wpeAS_nodeVec, v_Direction\(i));")
            lines.append("            v_EndpointLen\(i) = mix(v_Len\(i), dot(wpeAS_eNodeVec, v_EndpointDirection\(i)), g_SmoothDistance);")
            lines.append("            float2 wpeAS_relTC = v_TexCoord.zw - wpeAS_nextC;")
            lines.append("            v_EndpointPosX\(i) = dot(wpeAS_relTC, v_EndpointDirection\(i));")
            lines.append("            v_PosX\(i) = v_EndpointPosX\(i);")
            lines.append("            float wpeAS_thisT = wpeAS_baseTime + \(thisTimeTerm);")
            lines.append("            float wpeAS_prevT = wpeAS_baseTime + \(prevTimeTerm);")
            lines.append("            float wpeAS_thisRad = sin(wpeAS_thisT * \(halfPi));")
            lines.append("            float wpeAS_prevRad = sin(wpeAS_prevT * \(halfPi)) * g_Inertia;")
            if usesExponent {
                lines.append("            wpeAS_thisRad = sign(wpeAS_thisRad) * pow(abs(wpeAS_thisRad), g_Exponent);")
                lines.append("            wpeAS_prevRad = sign(wpeAS_prevRad) * pow(abs(wpeAS_prevRad), g_Exponent);")
            }
            lines.append("            wpeAS_thisRad += sin(g_WindDirection\(node) + \(halfPi)) + sin(g_GlobalWindOffset);")
            lines.append("            wpeAS_prevRad += sin(\(nextWind) + \(halfPi));")
            if usesNoise {
                for (radVar, timeVar) in [("wpeAS_thisRad", "wpeAS_thisT"), ("wpeAS_prevRad", "wpeAS_prevT")] {
                    lines.append("            {")
                    lines.append("                float4 wpeAS_sines = fract(g_NoiseSpeed * \(timeVar) / \(halfPi) * float4(1.0, -0.16161616, 0.0083333, -0.00019841)) * \(halfPi);")
                    lines.append("                float4 wpeAS_csines = cos(wpeAS_sines);")
                    lines.append("                wpeAS_sines = sin(wpeAS_sines);")
                    lines.append("                float4 wpeAS_base = step(float4(0.0), wpeAS_csines);")
                    lines.append("                wpeAS_sines = wpeAS_sines * 0.498 + 0.5;")
                    lines.append("                wpeAS_sines = mix(1.0 - pow(1.0 - wpeAS_sines, float4(wpeAS_friction.x)), pow(wpeAS_sines, float4(wpeAS_friction.y)), wpeAS_base);")
                    lines.append("                \(radVar) += (dot(float4(0.5), wpeAS_sines) - 1.0) * g_NoiseAmount;")
                    lines.append("            }")
                }
            }
            lines.append("            v_MotionRadian\(i) = wpeAS_thisRad - wpeAS_prevRad;")
            lines.append("        }")
        }
        lines.append("    }")
        return lines
    }

    // MARK: - v_TexCoord.zw resolution-scaled aux UV families

    /// Families in `texCoordZWResolutionSlot` keep `.zw`; every other shader keeps the historical `.xy` fallback.
    static func rewriteTexCoordMaskUVFallback(
        _ source: String,
        varyingTypesByName: [String: String],
        preserveTexCoordZW: Bool
    ) -> String {
        guard preserveTexCoordZW, varyingTypesByName["v_TexCoord"] == "float4" else {
            return source.replacingOccurrences(of: "v_TexCoord.zw", with: "v_TexCoord.xy")
        }
        return source
    }

    static func shouldPreserveTexCoordZW(shaderName: String, comboValues: [String: Int]) -> Bool {
        // swing/twirl: .zw is aspect + sine phase. blur_precise_gaussian: .zw is the per-tap step, not a scaled UV.
        if let family = texCoordZWFamilyName(shaderName: shaderName),
           family == "swing" || family == "twirl" || family == "blur_precise_gaussian" {
            return true
        }
        // lens_distortion: `.zw` is the aspect·size divisor, not a UV; the `.xy` downgrade would collapse `coord` to 2.
        if texCoordZWFamilyName(shaderName: shaderName) == "lens_distortion" {
            return true
        }
        // frame_builder: `.zw` is the sample UV and `.xy` is the signed pixel coordinate; the downgrade must not run.
        if texCoordZWFamilyName(shaderName: shaderName) == "frame_builder_by_gariam" {
            return true
        }
        return texCoordZWResolutionSlot(shaderName: shaderName, comboValues: comboValues) != nil
    }

    /// Returns texture slot N whose resolution the `.vert` writes into `.zw`, or nil when `.zw` has different semantics.
    static func texCoordZWResolutionSlot(shaderName: String, comboValues: [String: Int]) -> Int? {
        guard let family = texCoordZWFamilyName(shaderName: shaderName) else { return nil }
        switch family {
        case "waterwaves":
            // waterwaves.vert ladder: MASK scales by T1, else TIMEOFFSET by T2.
            // Both off leaves .zw unscaled AND unread, so the slot-1 default is inert.
            return comboValues["TIMEOFFSET"] == 1 && comboValues["MASK"] != 1 ? 2 : 1
        case "blend", "blendgradient":
            // TRANSFORMUV == 1 appends offset/rotate/scale steps after the resolution
            // scale that we don't synthesize — keep the historical .xy downgrade there.
            return comboValues["TRANSFORMUV"] == 1 ? nil : 1
        case "foliagesway":
            // MODE != 0 (vertex-displacement sway) leaves .zw = (0,0) — a constant
            // mask sample we can't reproduce with a scaled UV; keep the downgrade.
            return (comboValues["MODE"] ?? 0) == 0 ? 1 : nil
        // glitter_combine scales by g_Texture1Resolution even though the mask binds at slot 2 — replicate, don't "fix" to slot 2.
        case "glitter_combine", "waterflow", "tint", "shake", "iris",
             "localcontrast_combine", "cloudmotion", "chromatic_aberration", "fire",
             "caustics", "opacity", "blur_combine", "godrays_downsample2",
             "depthparallax", "reflection", "xray", "shimmer", "shine_downsample2", "waterripple":
            return 1
        case "refract", "motionblur_accumulation", "vhs", "pulse", "clouds",
             "filmgrain", "nitro":
            return 2
        case "lightshafts":
            return 3
        default:
            return nil
        }
    }

    // MARK: - lens_distortion (workshop 2811235087)

    /// Vertex-only uniforms the fragment-only path still needs to rebuild `v_Distorsion` / `v_Transforms` / `v_TexCoord`.
    static let lensDistortionVertexUniforms: [(name: String, glslType: String)] = [
        ("u_zoom", "float"),
        ("u_general", "float"),
        ("u_distorsion1", "float"),
        ("u_distorsion2", "float"),
        ("u_aberration", "float"),
        ("u_center", "vec2"),
        ("u_angle", "float"),
        ("u_size", "float"),
        ("g_Texture0Resolution", "vec4"),
    ]

    /// Uniforms `gaussian.vert` / `bokeh.vert` (workshop 2798319181) declare and their
    /// fragments do not. Every one of them feeds the per-tap STEP.
    static let bokehBlurVertexUniforms: [(name: String, glslType: String)] = [
        ("g_TexelSize", "vec2"),
        ("g_Texture0Resolution", "vec4"),
        ("u_aperture", "float"),
        ("u_ratio", "float"),
    ]

    /// Only a `uniform` declaration counts: a comment or a bare use of the name must not pass.
    static func declaresUniform(_ name: String, in source: String) -> Bool {
        source.range(
            of: "(?m)^\\s*uniform\\s+\\w+\\s+\(name)\\s*(\\[[^\\]]*\\])?\\s*;",
            options: .regularExpression
        ) != nil
    }

    static func declaringVertexOnlyUniforms(in source: String, shaderName: String) -> String {
        let source = declaringAudioResponseUniforms(in: source)
        let needed: [(name: String, glslType: String)]
        if texCoordZWFamilyName(shaderName: shaderName) == "lens_distortion",
           source.contains("v_Distorsion") {
            needed = lensDistortionVertexUniforms
        } else if bokehBlurStage(inSource: source) != nil {
            needed = bokehBlurVertexUniforms
        } else if isFrameBuilder(inSource: source) {
            needed = frameBuilderVertexUniforms
        } else {
            return source
        }
        let missing = needed
            .filter { !declaresUniform($0.name, in: source) }
            .map { "uniform \($0.glslType) \($0.name);" }
        guard !missing.isEmpty else { return source }
        return missing.joined(separator: "\n") + "\n" + source
    }

    // MARK: - audio-reactive engine effects (2370927443, issue #133)

    /// Whole declarations, not (name, type) pairs, because two are arrays.
    static let audioResponseVertexUniforms: [(name: String, declaration: String)] = [
        ("g_AudioSpectrum16Left", "uniform float g_AudioSpectrum16Left[16];"),
        ("g_AudioSpectrum16Right", "uniform float g_AudioSpectrum16Right[16];"),
        ("g_AudioFrequencyMin", "uniform float g_AudioFrequencyMin;"),
        ("g_AudioFrequencyMax", "uniform float g_AudioFrequencyMax;"),
        ("g_AudioPower", "uniform float g_AudioPower;"),
        ("g_AudioBounds", "uniform vec2 g_AudioBounds;"),
        ("g_AudioMultiply", "uniform float g_AudioMultiply;"),
    ]

    static let audioResponseVaryings = ["v_AudioPulse", "v_AudioShift", "v_Pulse"]

    /// Appended after the preamble so `#if AUDIOPROCESSING` is defined; `stripInactivePreprocessorBranches` then drops the block when audio is off.
    static func declaringAudioResponseUniforms(in source: String) -> String {
        guard audioResponseVaryings.contains(where: { source.contains($0) }) else { return source }
        let missing = audioResponseVertexUniforms
            .filter { !declaresUniform($0.name, in: source) }
            .map(\.declaration)
        guard !missing.isEmpty else { return source }
        return source + "\n#if AUDIOPROCESSING\n" + missing.joined(separator: "\n") + "\n#endif\n"
    }

    // MARK: - frame_builder (workshop 3647393229)

    /// Uniforms `frame_builder_by_gariam.vert` declares and its fragment does not.
    static let frameBuilderVertexUniforms: [(name: String, glslType: String)] = [
        ("u_position", "vec2"),
        ("u_rotation", "float"),
        ("g_LayerModelMatrix", "mat4"),
    ]

    static func isFrameBuilder(varyingNames names: Set<String>) -> Bool {
        names.isSuperset(of: ["v_TexCoord", "v_Size", "v_Transform"])
    }

    static func isFrameBuilder(inSource source: String) -> Bool {
        source.contains("varying")
            && ["v_TexCoord", "v_Size", "v_Transform"].allSatisfy { source.contains($0) }
    }

    /// Writes are in pixels and `v_TexCoord.xy` is a signed coordinate; a 0…1 UV fallback collapses every pixel onto the same corner branch.
    static func frameBuilderVaryingReconstructionLines(
        varyings: [WPEVaryingDecl],
        availableUniforms: Set<String>,
        comboValues: [String: Int]
    ) -> [String] {
        let names = Set(varyings.map(\.name))
        guard isFrameBuilder(varyingNames: names),
              hasUniforms(
                  "u_position", "u_rotation", "g_LayerModelMatrix", "u_size",
                  "u_NotchSize", "u_Thickness", "u_extrudeEdge", "u_Softness",
                  "g_Texture0Resolution",
                  in: availableUniforms
              ) else {
            return []
        }

        // REF_RES: the .vert declares `u_refResolution` as vec2 and the .frag as float; splat the fragment declaration we parsed.
        let resolution = (comboValues["REF_RES"] ?? 0) == 1 && availableUniforms.contains("u_refResolution")
            ? "float2(u_refResolution)"
            : "g_Texture0Resolution.xy"
        // FIXSCALE (default on) divides out the layer's own scale so the frame keeps its
        // authored pixel thickness however the layer is stretched.
        let scale = (comboValues["FIXSCALE"] ?? 1) == 1
            ? "float2(length(g_LayerModelMatrix[0].xy), length(g_LayerModelMatrix[1].xy))"
            : "float2(1.0)"
        // Round-cornered TYPEs measure the notch on the diagonal: `length(vec2(x))` = x·√2.
        let roundedTypes = Set([0, 7, 8, 9, 10, 11, 13])
        let notchDiagonal = roundedTypes.contains(comboValues["TYPE"] ?? 0)

        var lines: [String] = []
        lines.append("    // workshop 3647393229 frame_builder vertex stage, reconstructed per-pixel.")
        lines.append("    {")
        lines.append("        float2 wpeFB_res = \(resolution);")
        lines.append("        float2 wpeFB_scale = \(scale);")
        lines.append("        v_Transform.x = max(1e-6, u_NotchSize * wpeFB_res.x * 0.2);")
        if notchDiagonal {
            lines.append("        v_Transform.x = length(float2(v_Transform.x));")
        }
        lines.append("        v_Transform.y = u_Thickness * wpeFB_res.x * 0.05;")
        lines.append("        v_Transform.z = u_extrudeEdge * wpeFB_res.x * 0.1;")
        lines.append("        v_TexCoord.zw = in.uv;")
        lines.append("        v_TexCoord.xy = wpe_rotate_vec2("
            + "(in.uv + u_position - 0.5) * wpeFB_res * wpeFB_scale, u_rotation);")
        lines.append("        v_Size.xy = u_size * wpeFB_res * 0.5 * wpeFB_scale"
            + " - v_Transform.y - u_Softness - u_Softness;")
        lines.append("    }")
        return lines
    }

    // MARK: - bokeh_blur depth of field (workshop 2798319181)

    enum BokehBlurStage {
        case gaussian
        case bokeh
    }

    /// Matched on the varying signature, not the shader name, so an unrelated `effects/gaussian` does not inherit these `.vert` semantics.
    static func bokehBlurStage(varyingNames names: Set<String>) -> BokehBlurStage? {
        guard names.contains("v_PixelSize"), names.contains("v_TexCoord") else {
            return nil
        }
        if names.contains("qualityNormalizer") {
            return .gaussian
        }
        if names.isSuperset(of: ["v_Aperture", "v_Gamma", "v_Highlights"]) {
            return .bokeh
        }
        return nil
    }

    static func bokehBlurStage(inSource source: String) -> BokehBlurStage? {
        let declared = ["v_PixelSize", "v_TexCoord", "qualityNormalizer",
                        "v_Aperture", "v_Gamma", "v_Highlights"]
            .filter { source.contains("varying") && source.contains($0) }
        return bokehBlurStage(varyingNames: Set(declared))
    }

    /// `v_PixelSize` is the per-tap UV step (a few thousandths); a screen-UV fallback would send every disc tap across the frame.
    static func bokehBlurVaryingReconstructionLines(
        varyings: [WPEVaryingDecl],
        availableUniforms: Set<String>,
        comboValues: [String: Int]
    ) -> [String] {
        let names = Set(varyings.map(\.name))
        guard let stage = bokehBlurStage(varyingNames: names),
              hasUniforms("g_TexelSize", "g_Texture0Resolution", "u_ratio", "u_aperture", in: availableUniforms) else {
            return []
        }

        var lines: [String] = []
        lines.append("    // workshop 2798319181 depth-of-field vertex stage, reconstructed per-pixel (uniform-only).")
        lines.append("    {")
        lines.append("        float2 wpeDOF_ratio = g_TexelSize * g_Texture0Resolution.xy;")
        lines.append("        float wpeDOF_ratioYX = wpe_safe_ratio(wpeDOF_ratio.y, wpeDOF_ratio.x);")

        let aperture: String
        switch stage {
        case .gaussian:
            aperture = "u_aperture"
            if names.contains("qualityNormalizer") {
                // gaussian.vert folds the QUALITY combo, which is a compile-time constant.
                let quality = Double(comboValues["QUALITY"] ?? 2)
                lines.append("        qualityNormalizer = \((quality + 1.0) * 0.6);")
            }
        case .bokeh:
            // "Depth of field" (MODE 1) opens the aperture 5x over "Mask".
            lines.append("        v_Aperture = \(comboValues["MODE"] == 1 ? "15.0" : "3.0") * u_aperture;")
            aperture = "v_Aperture"
            if names.contains("v_Highlights"), availableUniforms.contains("u_lightFactor") {
                lines.append("        v_Highlights = float2(-0.999, 0.999) * u_lightFactor;")
            }
            if names.contains("v_Gamma"), availableUniforms.contains("u_gamma") {
                lines.append("        v_Gamma = float2(u_gamma, 1.0 / u_gamma);")
            }
        }

        // ANAMORPHIC squeezes the vertical step by the lens ratio instead of the aperture.
        let pixelSize = comboValues["ANAMORPHIC"] == 1
            ? "(g_TexelSize + g_TexelSize) * float2(wpeDOF_ratioYX, u_ratio) * \(aperture)"
            : "(g_TexelSize + g_TexelSize) * float2(wpeDOF_ratioYX * \(aperture), \(aperture))"
        lines.append("        v_PixelSize = \(pixelSize);")
        lines.append("    }")
        return lines
    }

    /// Whether every uniform the lens_distortion reconstruction reads is declared. A repack
    /// that renamed one keeps the old screen-UV fallback rather than silently reading zero.
    static func hasLensDistortionUniforms(_ availableUniforms: Set<String>) -> Bool {
        lensDistortionVertexUniforms.allSatisfy { availableUniforms.contains($0.name) }
    }

    /// Family key is the basename under `effects/` or `effect_*`. Paths outside `effects/` return nil so a shared basename does not inherit engine `.vert` semantics.
    static func texCoordZWFamilyName(shaderName: String) -> String? {
        let normalized = shaderName
            .lowercased()
            .replacingOccurrences(of: ".frag", with: "")
            .replacingOccurrences(of: ".vert", with: "")
        if normalized.hasPrefix("effect_") {
            return String(normalized.dropFirst("effect_".count))
        }
        guard let range = normalized.range(of: "effects/", options: .backwards) else { return nil }
        if range.lowerBound != normalized.startIndex,
           normalized[normalized.index(before: range.lowerBound)] != "/" {
            return nil
        }
        let family = String(normalized[range.upperBound...])
        guard !family.isEmpty, !family.contains("/") else { return nil }
        return family
    }
}
#endif
