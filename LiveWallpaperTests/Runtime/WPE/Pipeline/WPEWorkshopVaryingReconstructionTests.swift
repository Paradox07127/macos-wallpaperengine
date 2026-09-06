#if !LITE_BUILD
@testable import LiveWallpaper
import Testing

/// The transpile path is fragment-only: it never runs a workshop `.vert`, and rebuilds the
/// varyings that `.vert` would have written from a per-family table. A family with no entry
/// gets a screen-UV ramp, which the shader then uses as whatever the varying meant.
///
/// `lens_distortion` (workshop 2811235087) reads three of them, and the ramp made the
/// distortion strength EQUAL to the chromatic-aberration strength: the `amount - ca` tap
/// cancelled to an identity sample while the other two ran off the edge and clamped, so on
/// 3647999330 the post layer came out with red pinned to 171 (95% of pixels) and green to
/// 162 (92%) — the input's corner texel — over an untouched blue channel.
@Suite("WPE workshop varying reconstruction")
struct WPEWorkshopVaryingReconstructionTests {
    /// Mirrors the declarations and the reads of the real `lens_distortion.frag`.
    private static let lensSource = """
    uniform sampler2D g_Texture0;
    uniform float u_alpha;
    uniform float u_ratio;
    varying vec4 v_TexCoord;
    varying vec4 v_Distorsion;
    varying vec4 v_Transforms;
    void main() {
        vec2 coord = (v_TexCoord.xy + v_Transforms.xy) / v_TexCoord.zw;
        gl_FragColor = vec4(coord, v_Distorsion.x + v_Distorsion.z, v_Transforms.z);
    }
    """

    private func translate(
        shaderName: String,
        source: String = lensSource,
        comboValues: [String: Int] = ["CA": 0, "ANAMORPHIC": 0]
    ) throws -> String {
        try WPEShaderTranspiler.translateFragment(
            shaderName: shaderName,
            preprocessedSource: source,
            comboValues: comboValues
        ).mslSource
    }

    @Test("Distortion and centre come from the .vert formulas, not a screen-UV ramp")
    func reconstructsDistortionAndTransforms() throws {
        let msl = try translate(shaderName: "workshop/2811235087/effects/lens_distortion")

        #expect(!msl.contains("v_Distorsion = float4(in.uv, in.uv)"))
        #expect(!msl.contains("v_Transforms = float4(in.uv, in.uv)"))
        #expect(!msl.contains("varying 'v_Distorsion'"))
        #expect(!msl.contains("varying 'v_Transforms'"))
        // lens_distortion.vert:29 / :35 — the uniforms only the .vert declared, injected so
        // the reconstruction has real values instead of reading nothing.
        #expect(msl.contains("float2(u_distorsion1, u_distorsion2 + u_distorsion2) * -u_general"))
        #expect(msl.contains("(1.0 - u_center - 0.5) * u_general - 0.5"))
        // `.zw` is the aspect·size divisor, so the `.xy` downgrade must not apply here.
        #expect(msl.contains("v_TexCoord.zw"))
        #expect(msl.contains("max(1e-6, u_size * 4.0)"))
    }

    @Test("The CA combo decides whether the aberration split is authored or zero")
    func chromaticAberrationFollowsItsCombo() throws {
        // The uniform is declared either way (it is injected with the rest of the .vert's
        // set); what the combo decides is whether the `.zw` split reads it.
        let off = try translate(
            shaderName: "workshop/2811235087/effects/lens_distortion",
            comboValues: ["CA": 0, "ANAMORPHIC": 0]
        )
        #expect(!off.contains("u_aberration * 0.1"))

        // The .vert's own [COMBO] default is 1, so an unauthored CA aberrates.
        let on = try translate(
            shaderName: "workshop/2811235087/effects/lens_distortion",
            comboValues: ["ANAMORPHIC": 0]
        )
        #expect(on.contains("u_aberration * 0.1"))
    }

    /// Control: the rule is keyed on the effect family, so a shader that merely declares the
    /// same varyings keeps the old fallback AND the diagnostic that marks it as unreconstructed.
    @Test("A shader outside the family keeps the screen-UV fallback")
    func otherShadersKeepTheFallback() throws {
        let msl = try translate(shaderName: "workshop/9999999999/effects/something_else")
        #expect(msl.contains("v_Distorsion = float4(in.uv, in.uv)"))
        #expect(msl.contains("v_Transforms = float4(in.uv, in.uv)"))
        #expect(msl.contains("varying 'v_Distorsion'"))
        #expect(!msl.contains("u_distorsion1"))
    }

    // MARK: - workshop 2798319181 depth of field

    private static let gaussianSource = """
    uniform sampler2D g_Texture0;
    uniform float u_alpha;
    uniform float u_aperture;
    uniform float u_ratio;
    uniform vec2 g_TexelSize;
    varying vec2 v_TexCoord;
    varying vec2 v_PixelSize;
    varying float qualityNormalizer;
    void main() {
        gl_FragColor = texSample2D(g_Texture0, v_TexCoord + v_PixelSize * qualityNormalizer);
    }
    """

    private static let bokehSource = """
    uniform sampler2D g_Texture0;
    uniform float u_gamma;
    uniform float u_lightFactor;
    uniform float u_ratio;
    varying vec2 v_TexCoord;
    varying vec2 v_PixelSize;
    varying float v_Aperture;
    varying vec2 v_Gamma;
    varying vec2 v_Highlights;
    void main() {
        gl_FragColor = texSample2D(g_Texture0, v_TexCoord + v_PixelSize * v_Aperture)
            * vec4(v_Gamma, v_Highlights);
    }
    """

    /// `v_PixelSize` is the per-tap STEP in UV — a few thousandths. The screen-UV fallback
    /// made it a whole frame, so the 43-tap disc averaged the entire picture: on 3647999330
    /// the composite sat 30/255 off the pre-DOF frame with contrast crushed from 68 to 50.
    @Test("The depth-of-field step comes from g_TexelSize, not the screen UV")
    func reconstructsDepthOfFieldStep() throws {
        let gaussian = try translate(
            shaderName: "workshop/2798319181/effects/gaussian",
            source: Self.gaussianSource,
            comboValues: ["QUALITY": 1, "ANAMORPHIC": 0]
        )
        // The declaration keeps its default initializer; the reconstruction assigns over it.
        #expect(!gaussian.contains("varying 'v_PixelSize'"))
        #expect(gaussian.contains("v_PixelSize = (g_TexelSize + g_TexelSize)"))
        // gaussian.vert:20 `(QUALITY + 1.0) * 0.6`, folded because QUALITY is compile-time.
        #expect(gaussian.contains("qualityNormalizer = 1.2"))

        let bokeh = try translate(
            shaderName: "workshop/2798319181/effects/bokeh",
            source: Self.bokehSource,
            comboValues: ["ANAMORPHIC": 0]
        )
        #expect(bokeh.contains("v_Aperture = 3.0 * u_aperture"))
        #expect(bokeh.contains("v_Gamma = float2(u_gamma, 1.0 / u_gamma)"))
        #expect(bokeh.contains("v_Highlights = float2(-0.999, 0.999) * u_lightFactor"))
        // bokeh.frag declares neither, so both must be injected for the step to resolve.
        #expect(bokeh.contains("g_TexelSize"))
        #expect(bokeh.contains("g_Texture0Resolution"))

        // MODE 1 ("Depth of field") opens the aperture 5x over MODE 0 ("Mask").
        let depthOfField = try translate(
            shaderName: "workshop/2798319181/effects/bokeh",
            source: Self.bokehSource,
            comboValues: ["MODE": 1, "ANAMORPHIC": 0]
        )
        #expect(depthOfField.contains("v_Aperture = 15.0 * u_aperture"))
    }

    /// Control: the DOF rule is keyed on the varying signature, so a shader that only shares
    /// the `v_PixelSize` name keeps its fallback.
    @Test("A lone v_PixelSize does not claim the depth-of-field rule")
    func depthOfFieldNeedsItsFullSignature() throws {
        let msl = try translate(
            shaderName: "workshop/2798319181/effects/gaussian",
            source: """
            uniform sampler2D g_Texture0;
            varying vec2 v_TexCoord;
            varying vec2 v_PixelSize;
            void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord + v_PixelSize); }
            """
        )
        #expect(msl.contains("v_PixelSize = in.uv"))
        #expect(msl.contains("varying 'v_PixelSize'"))
    }

    // MARK: - fade (3124095265) and Simple_Audio_Bars (3082978660)

    /// fade's gradient coordinate carries its own offset/rotate/scale. It is only identity
    /// while those sit at their defaults — 3647999330's first fade layer authors scale 0.95.
    @Test("fade rebuilds its gradient coordinate from the authored transform")
    func reconstructsFadeCoordinate() throws {
        let msl = try translate(
            shaderName: "workshop/3124095265/effects/fade",
            source: """
            uniform sampler2D g_Texture0;
            uniform vec2 g_Offset;
            uniform vec2 g_Scale;
            uniform float g_Direction;
            varying vec2 v_TexCoord;
            varying vec2 p_TexCoord;
            void main() { gl_FragColor = texSample2D(g_Texture0, p_TexCoord + v_TexCoord); }
            """
        )
        #expect(!msl.contains("p_TexCoord = in.uv"))
        #expect(msl.contains("wpe_rotate_vec2(in.uv - g_Offset - 0.5, -g_Direction) * g_Scale + 0.5"))
    }

    /// Simple_Audio_Bars writes `p_TexCoord = a_TexCoord`, so its screen-UV default is exact
    /// and it deliberately has no rule — the diagnostic marker there is conservative, not a
    /// defect. Its `v_TexCoord` and `i_DCorrectingFactor` are NOT identity and do have rules.
    @Test("Audio bars rebuild the aspect factor and the transformed coordinate only")
    func reconstructsAudioBarsFactors() throws {
        let source = """
        uniform sampler2D g_Texture0;
        uniform vec2 g_Offset;
        uniform vec2 g_Scale;
        uniform float g_Direction;
        uniform vec4 g_Texture0Resolution;
        varying vec2 v_TexCoord;
        varying vec2 p_TexCoord;
        varying float i_DCorrectingFactor;
        void main() {
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord + p_TexCoord)
                * i_DCorrectingFactor;
        }
        """
        let name = "workshop/3082978660/effects/Simple_Audio_Bars"
        let transformed = try translate(shaderName: name, source: source, comboValues: ["TRANSFORM": 1])
        #expect(transformed.contains(
            "i_DCorrectingFactor = wpe_safe_ratio(g_Texture0Resolution.x, g_Texture0Resolution.y)"
        ))
        #expect(!transformed.contains("v_TexCoord = in.uv;"))
        // The documented exception: this one really is the raw texcoord.
        #expect(transformed.contains("p_TexCoord = in.uv;"))

        // Control: without TRANSFORM the .vert leaves v_TexCoord raw, so the default is exact.
        let plain = try translate(shaderName: name, source: source, comboValues: [:])
        #expect(plain.contains("v_TexCoord = in.uv;"))
    }

    // MARK: - frame_builder (workshop 3647393229)

    /// Everything frame_builder's `.vert` writes is in PIXELS, and `v_TexCoord.xy` is SIGNED
    /// around the layer centre — the fragment picks a corner by its sign. The 0…1 fallback
    /// collapsed the shape and sent every pixel down the same corner branch, which drew
    /// 3647999330's launcher panels as a diagonal wedge instead of a rounded frame.
    @Test("frame_builder rebuilds its pixel-space shape and keeps the raw UV in .zw")
    func reconstructsFrameBuilderShape() throws {
        let msl = try translate(
            shaderName: "workshop/3647393229/effects/frame_builder_by_gariam",
            source: """
            uniform sampler2D g_Texture0;
            uniform vec4 g_Texture0Resolution;
            uniform float u_Softness;
            uniform float u_NotchSize;
            uniform float u_Thickness;
            uniform float u_extrudeEdge;
            uniform float u_refResolution;
            uniform vec2 u_size;
            varying vec4 v_TexCoord;
            varying vec2 v_Size;
            varying vec3 v_Transform;
            void main() {
                vec4 pix = texSample2D(g_Texture0, v_TexCoord.zw);
                gl_FragColor = pix * vec4(v_TexCoord.xy, v_Size) * vec4(v_Transform, 1.0);
            }
            """,
            comboValues: ["REF_RES": 1, "FIXSCALE": 1, "TYPE": 0]
        )
        #expect(!msl.contains("varying 'v_Size'"))
        #expect(!msl.contains("varying 'v_Transform'"))
        #expect(msl.contains("v_Transform.y = u_Thickness * wpeFB_res.x * 0.05"))
        #expect(msl.contains("float2 wpeFB_res = float2(u_refResolution)"))
        #expect(msl.contains("length(g_LayerModelMatrix[0].xy)"))
        // TYPE 0 is a round shape, so the notch is measured on the diagonal.
        #expect(msl.contains("v_Transform.x = length(float2(v_Transform.x))"))
        // `.zw` is the framebuffer UV; the historical `.xy` downgrade must not run here,
        // so the fragment's own read still names `.zw` after the texture rewrite.
        #expect(msl.contains("g_Texture0.sample(wpeSampler0, v_TexCoord.zw)"))
    }
}
#endif
