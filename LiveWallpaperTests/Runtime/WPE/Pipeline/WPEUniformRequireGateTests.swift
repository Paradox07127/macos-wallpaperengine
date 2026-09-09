@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

/// `require` is parsed for DIAGNOSTICS ONLY. It must never gate uniform resolution.
///
/// Measured, not assumed — Windows capture of 3437487219 ordinal 2
/// (`.notes/oracle-runs/3437487219-…/windows.json`): `effects/lightshafts` runs with
/// `DIRECTDRAW: 1` while `g_Point0..3` are annotated `require {"DIRECTDRAW": 0}`, and WPE
/// binds them anyway — `g_Point0 = [6.83764, -3.17560]` with `usedByShader: true`, and the
/// same values appear again as the draw's vertex TEXCOORDs. So `require` decides only
/// whether the EDITOR exposes the field; the authored constant stays live regardless.
///
/// A gate was briefly wired here on the assumption those constants were stale leftovers.
/// It withheld values WPE was actively using and made the frame worse. The parse stays
/// (the diagnostic it feeds is what located the real geometry divergence); the gating does
/// not come back without a capture showing WPE dropping such a value.
@Suite("WPE uniform require gate")
struct WPEUniformRequireGateTests {
    /// Verbatim from assets/effects/lightshafts/shaders/effects/lightshafts.vert.
    private static let pointDeclaration = """
    uniform vec2 g_Point0; // {"material":"point0","label":"p0","default":"0.67728 0.01297","require":{"DIRECTDRAW":0}}
    """

    /// Verbatim from the same shader — no `require`, so it stays authorable either way.
    private static let radiusDeclaration = """
    uniform float g_Radius; // {"material":"rayradius","label":"ui_editor_properties_radius","default":0.2,"range":[0.0, 1.0]}
    """

    @Test("A require map is parsed off the annotation")
    func requireIsParsed() throws {
        let point = try #require(WPEUniformDecl.parse(line: Self.pointDeclaration))
        #expect(point.materialName == "point0")
        #expect(point.requiredCombos == ["DIRECTDRAW": 0])

        let radius = try #require(WPEUniformDecl.parse(line: Self.radiusDeclaration))
        #expect(radius.materialName == "rayradius")
        #expect(radius.requiredCombos.isEmpty, "no require annotation must mean unconditional")
    }

    @Test("Authorability follows the pass's combo values")
    func authorabilityFollowsCombos() throws {
        let point = try #require(WPEUniformDecl.parse(line: Self.pointDeclaration))
        let slot = WPEUniformSlot(
            name: point.name,
            glslType: point.type,
            slot: 0,
            slotCount: 1,
            materialName: point.materialName,
            defaultValue: point.defaultValue,
            requiredCombos: point.requiredCombos
        )
        // Editor authorability is false; runtime binding is tested separately below.
        #expect(!slot.isAuthorable(under: ["DIRECTDRAW": 1]))
        // Editor authorability is true for the requested combo.
        #expect(slot.isAuthorable(under: ["DIRECTDRAW": 0]))
        // A combo the pass never declares reads as 0, matching how combos default.
        #expect(slot.isAuthorable(under: [:]))
        // An unrelated combo must not disturb the decision.
        #expect(slot.isAuthorable(under: ["RAYMODE": 1]))
    }

    /// Every listed combo has to match, not just one.
    @Test("A multi-combo require needs all of them")
    func multiComboRequire() {
        let slot = WPEUniformSlot(
            name: "g_Thing",
            glslType: "float",
            slot: 0,
            slotCount: 1,
            materialName: "thing",
            requiredCombos: ["A": 1, "B": 2]
        )
        #expect(slot.isAuthorable(under: ["A": 1, "B": 2]))
        #expect(!slot.isAuthorable(under: ["A": 1, "B": 3]))
        #expect(!slot.isAuthorable(under: ["A": 0, "B": 2]))
    }

    /// An unconditional uniform must be unaffected — the gate has to be inert for the
    /// overwhelming majority of uniforms, which carry no `require` at all.
    @Test("Uniforms without a require stay authorable under any combos")
    func noRequireIsAlwaysAuthorable() throws {
        let radius = try #require(WPEUniformDecl.parse(line: Self.radiusDeclaration))
        let slot = WPEUniformSlot(
            name: radius.name,
            glslType: radius.type,
            slot: 0,
            slotCount: 1,
            materialName: radius.materialName,
            requiredCombos: radius.requiredCombos
        )
        #expect(slot.isAuthorable(under: ["DIRECTDRAW": 1]))
        #expect(slot.isAuthorable(under: [:]))
    }

    private func runtimePass(
        _ values: [String: WPESceneShaderConstantValue]
    ) -> WPEPreparedRenderPass {
        let shader = "effects/lightshafts"
        return WPEPreparedRenderPass(
            pass: WPERenderPass(
                id: "require-runtime", phase: .effect(file: "effects/lightshafts/effect.json"),
                shader: shader, source: .asset("unused"), target: .scene,
                textures: [:], binds: [:], constants: [:], combos: ["DIRECTDRAW": 1],
                blending: "premultiplied", cullMode: "nocull",
                depthTest: "disabled", depthWrite: "disabled"
            ),
            shader: WPEShaderProgram(name: shader, vertexSource: "", fragmentSource: "", isBuiltin: false),
            textureBindings: [:], comboValues: ["DIRECTDRAW": 1], uniformValues: values
        )
    }

    @Test("Unmet editor require keeps live authored values in runtime packing", arguments: [false, true])
    func unmetRequireDoesNotGateRuntimeValue(directPacking: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        executor.derivedUniformPackingEnabled = directPacking
        let declaration = try #require(WPEUniformDecl.parse(line: Self.pointDeclaration))
        let slot = WPEUniformSlot(
            name: declaration.name, glslType: declaration.type, slot: 0, slotCount: 1,
            materialName: declaration.materialName, defaultValue: declaration.defaultValue,
            requiredCombos: declaration.requiredCombos
        )
        // The first value is the existing Windows evidence; the second proves live updates.
        for point in [[6.83764, -3.17560], [0.25, 0.75]] {
            let pass = runtimePass(["g_Point0": .vector(point)])
            #expect(!slot.isAuthorable(under: pass.pass.combos))
            #expect(executor.uniformPlans(for: pass, layout: [slot])[0].directPacking == nil)
            let packed = executor.packTranslatedUniforms(for: pass, layout: [slot])
            #expect(packed == [SIMD4<Float>(Float(point[0]), Float(point[1]), 0, 0)])
        }
        #expect(executor.uniformPlanCompileCount == 1)
    }

    @Test("Unmet editor require preserves live texture-derived precedence", arguments: [false, true])
    func unmetRequireDoesNotGateDerivedValue(directPacking: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        executor.derivedUniformPackingEnabled = directPacking
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 8, height: 4, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let table = WPEMetalTextureSlotTable()
        table.set(
            texture: texture, samplingDescriptor: nil,
            resolution: WPEMetalTextureMetadataRegistry.shared.resolution(for: texture), at: 0
        )
        let slot = WPEUniformSlot(
            name: "g_Texture0Resolution", glslType: "vec4", slot: 0, slotCount: 1,
            materialName: "textureSize", defaultValue: .vector([91, 92, 93, 94]),
            requiredCombos: ["DIRECTDRAW": 0]
        )
        let sentinel: [Double] = [71, 72, 73, 74]
        let pass = runtimePass(["g_Texture0Resolution": .vector(sentinel)])
        #expect(!slot.isAuthorable(under: pass.pass.combos))
        #expect(executor.uniformPlans(for: pass, layout: [slot])[0].directPacking == .textureResolution(0))
        #expect(executor.packTranslatedUniforms(for: pass, layout: [slot], texturesBySlot: table)
            == [SIMD4<Float>(8, 4, 8, 4)])
        // No GPU sampling is needed: this tests the live binding's resolution metadata.
        table.reset()
        #expect(executor.packTranslatedUniforms(for: pass, layout: [slot], texturesBySlot: table)
            == [SIMD4<Float>(71, 72, 73, 74)])
        #expect(executor.uniformPlanCompileCount == 1)
    }
}
