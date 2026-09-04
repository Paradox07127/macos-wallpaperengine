#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

/// Characterization of the CURRENT uniform resolution semantics, written before
/// the dense uniform ABI replaces `packTranslatedUniforms`. Every case here
/// describes what the renderer does today — not what Wallpaper Engine does, and
/// not what a cleaner design would do. Section numbers refer to
/// `.notes/research/2026-08-24-uniform-abi-spec.md`.
///
/// The complementary suite `WPEUniformResolutionPlanTests` proves the compiled
/// plan equals the legacy candidate walk; this suite pins the individual rules
/// that walk implements, so a rewrite that drops one is named by the failure.
@Suite("WPE uniform precedence characterization")
struct WPEUniformPrecedenceCharacterizationTests {

    // MARK: - A. The precedence chain (§2.2)

    /// §2.2 rows 3a/3b: within ONE candidate the frame global is probed first.
    @Test("An exact frame global beats the pass value of the same name")
    func exactFrameGlobalBeatsPassValueOfTheSameName() throws {
        let executor = try makeExecutor()
        let pass = makePass(id: "a1", uniformValues: ["g_Time": .number(999)])
        let layout = [WPEUniformSlot(name: "g_Time", glslType: "float", slot: 0, slotCount: 1)]

        #expect(planSteps(layout, pass: pass, on: executor) == [
            [.frameGlobal("g_Time"), .passValue("g_Time")]
        ])
        #expect(pack(layout, pass: pass, on: executor, frame: makeFrame())[0].x == 2.5)
        // Control: with no frame context the authored value is what lands, so
        // the 2.5 above really came from the frame tier.
        #expect(pack(layout, pass: pass, on: executor)[0].x == 999)
    }

    /// §2.2 "Candidate priority dominates source priority within the frame/pass
    /// tiers": an EARLIER candidate's pass value beats a LATER candidate's
    /// frame-global. A rewrite that grouped by source (all frame globals first)
    /// would return the runtime clock here instead of the authored 7.
    @Test("An earlier candidate's pass value beats a later candidate's frame global")
    func earlierCandidatePassValueBeatsLaterCandidateFrameGlobal() throws {
        let executor = try makeExecutor()
        let pass = makePass(id: "a2", uniformValues: ["u_Custom": .number(7)])
        let layout = [
            WPEUniformSlot(
                name: "u_Custom", glslType: "float", slot: 0, slotCount: 1,
                materialName: "g_Time"
            )
        ]

        #expect(planSteps(layout, pass: pass, on: executor) == [
            [.passValue("u_Custom"), .frameGlobal("g_Time")]
        ])
        #expect(pack(layout, pass: pass, on: executor, frame: makeFrame())[0].x == 7)
    }

    /// §2.2 "Every frame/pass case-insensitive hit beats every raw constant,
    /// including an exact raw constant." This is the counter-intuitive rule the
    /// dense ABI is most likely to "clean up" into exact-first ordering, which
    /// would silently swap 0.8 for -1 here.
    @Test("A lowercased pass-value hit beats an EXACT raw constant")
    func lowercasedPassValueBeatsExactRawConstant() throws {
        let executor = try makeExecutor()
        let pass = makePass(
            id: "a3",
            constants: ["u_Ratio": .number(-1)],
            uniformValues: ["RATIO": .number(0.8)]
        )
        let layout = [WPEUniformSlot(name: "u_Ratio", glslType: "float", slot: 0, slotCount: 1)]

        #expect(planSteps(layout, pass: pass, on: executor) == [
            [.passValue("RATIO"), .passConstant("u_Ratio")]
        ])
        #expect(pack(layout, pass: pass, on: executor)[0].x == 0.8)
        // Control: remove the case-variant key and the exact constant does win,
        // so the assertion above is about ORDER, not about constants being dead.
        let withoutCaseVariant = makePass(id: "a3b", constants: ["u_Ratio": .number(-1)])
        #expect(pack(layout, pass: withoutCaseVariant, on: executor)[0].x == -1)
    }

    /// §2.2 rows 4a vs 5, the frame-global half of the same reversal.
    @Test("A lowercased frame-global hit beats an EXACT raw constant")
    func lowercasedFrameGlobalBeatsExactRawConstant() throws {
        let executor = try makeExecutor()
        let pass = makePass(id: "a4", constants: ["g_daytime": .number(-1)])
        let layout = [WPEUniformSlot(name: "g_daytime", glslType: "float", slot: 0, slotCount: 1)]

        #expect(planSteps(layout, pass: pass, on: executor) == [
            [.frameGlobal("g_Daytime"), .passConstant("g_daytime")]
        ])
        #expect(pack(layout, pass: pass, on: executor, frame: makeFrame())[0].x == 0.75)
        #expect(pack(layout, pass: pass, on: executor)[0].x == -1)
    }

    /// §2.2 rows 5 and 6: exact constants precede lowercased constants, and the
    /// whole constants tier precedes the slot default.
    @Test("Exact constants beat lowercased constants, and both beat the slot default")
    func constantsTierOrder() throws {
        let executor = try makeExecutor()
        let pass = makePass(
            id: "a5",
            constants: ["u_Ratio": .number(1), "RATIO": .number(2)]
        )
        let layout = [
            WPEUniformSlot(
                name: "u_Ratio", glslType: "float", slot: 0, slotCount: 1,
                defaultValue: .number(3)
            )
        ]
        #expect(pack(layout, pass: pass, on: executor)[0].x == 1)

        let loweredOnly = makePass(id: "a5b", constants: ["RATIO": .number(2)])
        #expect(planSteps(layout, pass: loweredOnly, on: executor) == [[.passConstant("RATIO")]])
        #expect(pack(layout, pass: loweredOnly, on: executor)[0].x == 2)

        let empty = makePass(id: "a5c")
        #expect(planSteps(layout, pass: empty, on: executor)[0].isEmpty)
        #expect(pack(layout, pass: empty, on: executor)[0].x == 3)
    }

    /// §2.2 row 2 / §2.3: the `g_Texture<N>Resolution` derived probe is TERMINAL
    /// and sits above every named source. An unbound slot falls through.
    @Test("A bound g_TextureNResolution outranks pass values and constants; unbound falls through")
    func textureResolutionProbeOutranksNamedSources() throws {
        let executor = try makeExecutor()
        let device = try #require(MTLCreateSystemDefaultDevice())
        let textures = WPEMetalTextureSlotTable()
        textures[0] = try makeTexture(device: device, width: 24, height: 6)

        let pass = makePass(
            id: "a6",
            constants: ["g_Texture5Resolution": .vector([5, 5, 5, 5])],
            uniformValues: ["g_Texture0Resolution": .vector([1, 2, 3, 4])]
        )
        let layout = [
            WPEUniformSlot(name: "g_Texture0Resolution", glslType: "vec4", slot: 0, slotCount: 1),
            WPEUniformSlot(name: "g_Texture5Resolution", glslType: "vec4", slot: 1, slotCount: 1)
        ]
        let plans = executor.uniformPlans(for: pass, layout: layout)
        #expect(plans[0].textureResolutionSlot == 0)
        #expect(plans[1].textureResolutionSlot == 5)

        let slots = pack(layout, pass: pass, on: executor, textures: textures)
        // Unregistered texture ⇒ physical size in all four components (§2.3).
        #expect(slots[0] == SIMD4<Float>(24, 6, 24, 6))
        // Slot 5 is unbound, so the ordinary chain resumes at the raw constant.
        #expect(slots[1] == SIMD4<Float>(5, 5, 5, 5))
    }

    @Test("Bound TEXS sampling descriptors outrank authored sentinels; missing descriptors fall through")
    func textureSamplingDescriptorProbeHasBindingScopedPrecedence() throws {
        let executor = try makeExecutor()
        let device = try #require(MTLCreateSystemDefaultDevice())
        let table = WPEMetalTextureSlotTable()
        let descriptor = WPETexSpriteSamplingDescriptor(
            rotation: SIMD4<Float>(0.5, 0.125, -0.25, 0.75),
            translation: SIMD2<Float>(0.375, 0.625)
        )
        table.set(
            texture: try makeTexture(device: device, width: 8, height: 4),
            samplingDescriptor: descriptor,
            at: 0
        )
        table[7] = try makeTexture(device: device, width: 2, height: 2)

        let pass = makePass(
            id: "a6.sampling",
            constants: ["g_Texture7Translation": .vector([7, 7])],
            uniformValues: ["g_Texture0Rotation": .vector([-1, -1, -1, -1])]
        )
        let layout = [
            WPEUniformSlot(name: "g_Texture0Rotation", glslType: "vec4", slot: 0, slotCount: 1),
            WPEUniformSlot(name: "g_Texture0Translation", glslType: "vec2", slot: 1, slotCount: 1),
            WPEUniformSlot(name: "g_Texture7Translation", glslType: "vec2", slot: 2, slotCount: 1)
        ]
        let plans = executor.uniformPlans(for: pass, layout: layout)
        #expect(plans[0].textureRotationSlot == 0)
        #expect(plans[1].textureTranslationSlot == 0)
        #expect(plans[2].textureTranslationSlot == 7)

        let slots = pack(layout, pass: pass, on: executor, textures: table)
        #expect(slots[0] == descriptor.rotation)
        #expect(slots[1] == SIMD4<Float>(descriptor.translation.x, descriptor.translation.y, 0, 0))
        // Slot 7 has a texture but no TEXS descriptor, so the ordinary authored
        // chain remains authoritative; no identity/zero fallback is invented.
        #expect(slots[2] == SIMD4<Float>(7, 7, 0, 0))
    }

    /// §2.3: recognition of the derived names is exact and case-sensitive.
    @Test("Derived-probe name recognition is exact and case-sensitive")
    func derivedProbeNameRecognition() {
        #expect(WPEMetalRenderExecutor.textureResolutionSlotIndex(for: "g_Texture0Resolution") == 0)
        #expect(WPEMetalRenderExecutor.textureResolutionSlotIndex(for: "g_Texture12Resolution") == 12)
        #expect(WPEMetalRenderExecutor.textureResolutionSlotIndex(for: "g_texture0Resolution") == nil)
        #expect(WPEMetalRenderExecutor.textureResolutionSlotIndex(for: "g_Texture0resolution") == nil)
        #expect(WPEMetalRenderExecutor.textureResolutionSlotIndex(for: "g_TextureResolution") == nil)
        #expect(WPEMetalRenderExecutor.textureResolutionSlotIndex(for: "g_TextureXResolution") == nil)

        #expect(WPEMetalRenderExecutor.textureRotationSlotIndex(for: "g_Texture0Rotation") == 0)
        #expect(WPEMetalRenderExecutor.textureRotationSlotIndex(for: "g_Texture7Rotation") == 7)
        #expect(WPEMetalRenderExecutor.textureRotationSlotIndex(for: "g_Texture8Rotation") == nil)
        #expect(WPEMetalRenderExecutor.textureRotationSlotIndex(for: "g_texture0Rotation") == nil)
        #expect(WPEMetalRenderExecutor.textureRotationSlotIndex(for: "g_Texture0rotation") == nil)
        #expect(WPEMetalRenderExecutor.textureTranslationSlotIndex(for: "g_Texture0Translation") == 0)
        #expect(WPEMetalRenderExecutor.textureTranslationSlotIndex(for: "g_Texture7Translation") == 7)
        #expect(WPEMetalRenderExecutor.textureTranslationSlotIndex(for: "g_Texture8Translation") == nil)
        #expect(WPEMetalRenderExecutor.textureTranslationSlotIndex(for: "g_Texture0TranslationNext") == nil)

        #expect(WPEMetalRenderExecutor.texelSizeValue(named: "g_texelsize", sceneSize: CGSize(width: 4, height: 2)) == nil)
        #expect(WPEMetalRenderExecutor.texelSizeValue(named: "g_TexelSize", sceneSize: CGSize(width: 4, height: 2))
            == .vector([0.25, 0.5]))
        #expect(WPEMetalRenderExecutor.texelSizeHalfValue(named: "g_texelsizehalf", sceneSize: CGSize(width: 4, height: 2)) == nil)
        #expect(WPEMetalRenderExecutor.texelSizeHalfValue(named: "g_TexelSizeHalf", sceneSize: CGSize(width: 4, height: 2))
            == .vector([0.125, 0.25]))
        #expect(WPEMetalRenderExecutor.screenValue(named: "g_screen", sceneSize: CGSize(width: 4, height: 2)) == nil)
        #expect(WPEMetalRenderExecutor.screenValue(named: "g_Screen", sceneSize: CGSize(width: 4, height: 2))
            == .vector([4, 2, 2]))
    }

    /// §2.2 row 1: a degenerate scene size makes the `g_TexelSize` probe
    /// non-terminal, so ordinary lookup resumes. A freshly constructed executor
    /// has `currentScenePixelSize == .zero`, which is exactly that state.
    @Test("A degenerate scene size lets g_TexelSize fall through to the authored value")
    func degenerateTexelSizeFallsThrough() throws {
        let executor = try makeExecutor()
        let pass = makePass(id: "a7", uniformValues: ["g_TexelSize": .vector([0.5, 0.25])])
        let layout = [WPEUniformSlot(name: "g_TexelSize", glslType: "vec2", slot: 0, slotCount: 1)]

        let plans = executor.uniformPlans(for: pass, layout: layout)
        #expect(plans[0].isTexelSize)
        #expect(plans[0].steps == [.passValue("g_TexelSize")])
        #expect(pack(layout, pass: pass, on: executor)[0] == SIMD4<Float>(0.5, 0.25, 0, 0))
    }

    // MARK: - B. Hit-is-terminal happens BEFORE conversion (§2.6) — and the
    //            builtin path deliberately does the opposite (§2.5)

    /// §2.6 "Type mismatch and fallback": a translated slot's dictionary hit ends
    /// the search even when the value cannot convert; it packs as zero rather
    /// than letting the next source win. This is a DELIBERATE path difference
    /// from `WPEMetalShaderInputs.floatScalar` — see the paired test below.
    @Test("A wrong-type pass value ends translated resolution and packs zero")
    func wrongTypePassValueIsTerminalForTranslatedSlots() throws {
        let executor = try makeExecutor()
        let pass = makePass(
            id: "b1",
            constants: ["u_Wrong": .vector([1, 2, 3, 4])],
            uniformValues: ["u_Wrong": .string("not-a-number")]
        )
        let layout = [WPEUniformSlot(name: "u_Wrong", glslType: "vec4", slot: 0, slotCount: 1)]

        // Both steps are compiled — the constant is still a fallback if the key
        // vanishes — but the string hit stops the walk before it is reached.
        #expect(planSteps(layout, pass: pass, on: executor) == [
            [.passValue("u_Wrong"), .passConstant("u_Wrong")]
        ])
        #expect(pack(layout, pass: pass, on: executor)[0] == SIMD4<Float>(0, 0, 0, 0))

        // Control: drop the unconvertible value and the constant does land, so
        // the zero above is terminal-on-hit, not a missing constants tier.
        let constantOnly = makePass(id: "b1b", constants: ["u_Wrong": .vector([1, 2, 3, 4])])
        #expect(pack(layout, pass: constantOnly, on: executor)[0] == SIMD4<Float>(1, 2, 3, 4))
    }

    /// §2.5 "Generic builtin scalar rule": the builtin helper converts DURING
    /// lookup, so an unconvertible value is skipped and a later name or the raw
    /// constant wins. Deliberately opposite to the translated path above; the
    /// dense ABI must not unify the two.
    @Test("A wrong-type pass value falls through in the builtin scalar chain")
    func wrongTypePassValueFallsThroughForBuiltins() {
        let pass = makePass(
            id: "b2",
            constants: ["u_Wrong": .number(3)],
            uniformValues: ["u_Wrong": .string("not-a-number")]
        )
        #expect(WPEMetalShaderInputs.floatScalar(named: "u_Wrong", in: pass, default: -5) == 3)

        // The same skip applies across candidate NAMES within the dictionary tier.
        let twoNames = makePass(
            id: "b2b",
            uniformValues: ["u_First": .string("nope"), "u_Second": .number(2)]
        )
        #expect(WPEMetalShaderInputs.floatScalar(
            named: ["u_First", "u_Second"], in: twoNames, default: -5
        ) == 2)

        // And a parseable string is NOT a miss — it converts and terminates.
        let parseable = makePass(
            id: "b2c",
            constants: ["u_Wrong": .number(3)],
            uniformValues: ["u_Wrong": .string("1.5")]
        )
        #expect(WPEMetalShaderInputs.floatScalar(named: "u_Wrong", in: parseable, default: -5) == 1.5)
    }

    /// §2.5: the frame-aware builtin overload probes `frame ?? uniformValues`
    /// per candidate, then all raw constants — so runtime `g_Time` wins over an
    /// authored one, but a raw constant still beats a later candidate name.
    @Test("The frame-aware builtin chain probes frame, then pass values, then all constants")
    func frameAwareBuiltinChainOrder() {
        let pass = makePass(
            id: "b3",
            constants: ["g_Time": .number(-1)],
            uniformValues: ["g_Time": .number(999)]
        )
        #expect(WPEMetalShaderInputs.floatScalar(
            named: "g_Time", in: pass, frame: makeFrame(), default: -5
        ) == 2.5)
        #expect(WPEMetalShaderInputs.floatScalar(
            named: "g_Time", in: pass, frame: .empty, default: -5
        ) == 999)

        // Constants are a separate, later tier: the second name's constant beats
        // nothing in the dictionary tier, but it does beat the default.
        let constantsOnly = makePass(id: "b3b", constants: ["u_Second": .number(4)])
        #expect(WPEMetalShaderInputs.floatScalar(
            named: ["u_First", "u_Second"], in: constantsOnly, frame: .empty, default: -5
        ) == 4)

        // The tier split is what makes the two loops observable: EVERY candidate
        // is probed in frame/uniformValues before ANY constant is read, so the
        // later name's pass value beats the earlier name's constant. An
        // implementation that interleaved the two sources per candidate —
        // `frame ?? uniformValues ?? constants`, one name at a time — returns 1.
        let splitSources = makePass(
            id: "b3c",
            constants: ["u_First": .number(1)],
            uniformValues: ["u_Second": .number(2)]
        )
        #expect(WPEMetalShaderInputs.floatScalar(
            named: ["u_First", "u_Second"], in: splitSources, frame: .empty, default: -5
        ) == 2)
    }

    // MARK: - C. Candidate generation and the lowercase index (§2.4, §2.8)

    @Test("Exact candidate generation follows the documented four rules")
    func candidateGeneration() throws {
        let executor = try makeExecutor()
        func names(_ slot: WPEUniformSlot) -> [String] {
            executor.memoizedUniformNameCandidates(for: slot).names
        }
        func slot(_ name: String, material: String? = nil) -> WPEUniformSlot {
            WPEUniformSlot(name: name, glslType: "float", slot: 0, slotCount: 1, materialName: material)
        }

        #expect(names(slot("g_Multiply")) == ["g_Multiply"])
        #expect(names(slot("g_Multiply", material: "multiply1")) == ["g_Multiply", "multiply1"])
        // `u_` stripped, then the stripped name with its first letter uppercased.
        #expect(names(slot("u_ratio")) == ["u_ratio", "ratio", "Ratio"])
        // Already capitalized ⇒ the two stripped spellings collapse to one.
        #expect(names(slot("u_Ratio")) == ["u_Ratio", "Ratio"])
        // Uppercase `U_` is NOT stripped (§2.4).
        #expect(names(slot("U_Ratio")) == ["U_Ratio"])
        // An empty base after stripping adds nothing.
        #expect(names(slot("u_")) == ["u_"])
        // An empty material name is skipped, not appended.
        #expect(names(slot("u_x", material: "")) == ["u_x", "x", "X"])
        // Duplicates are removed keeping first occurrence.
        #expect(names(slot("u_Ratio", material: "Ratio")) == ["u_Ratio", "Ratio"])

        // The lowercased list is positionally parallel to the exact list.
        let candidates = executor.memoizedUniformNameCandidates(for: slot("u_ratio", material: "MiXeD"))
        #expect(candidates.names == ["u_ratio", "MiXeD", "ratio", "Ratio"])
        #expect(candidates.lowercasedNames == ["u_ratio", "mixed", "ratio", "ratio"])
    }

    /// §2.8 item 2 — ACCIDENTAL behavior, pinned only so a rewrite that changes
    /// it is visible. Swift dictionary iteration order picks the winner among
    /// case-variant keys; nothing establishes that winner is correct. What IS
    /// checkable is that the index and the resolved value agree, and that the
    /// choice is frozen for the life of the cached index.
    @Test("A case-variant key collision resolves to whichever spelling the index froze")
    func caseVariantCollisionIsResolvedConsistently() throws {
        let executor = try makeExecutor()
        let pass = makePass(
            id: "c2",
            uniformValues: ["Foo": .number(1), "FOO": .number(2)]
        )
        let index = executor.uniformKeyIndex(for: pass)
        let chosen = try #require(index.uniformKeys["foo"])
        #expect(chosen == "Foo" || chosen == "FOO")

        // `u_FOo` is spelled so that NO exact candidate (`u_FOo`, `FOo`) hits the
        // dictionary — only the lowercased round can, which is what puts the
        // collision on the resolution path at all.
        let layout = [WPEUniformSlot(name: "u_FOo", glslType: "float", slot: 0, slotCount: 1)]
        #expect(planSteps(layout, pass: pass, on: executor) == [[.passValue(chosen)]])
        // The packed value is the CHOSEN key's value, never a merge of the two.
        let expected = try #require(pass.uniformValues[chosen]?.numberValue)
        #expect(pack(layout, pass: pass, on: executor)[0].x == Float(expected))

        // Frozen: a second lookup returns the same spelling and does not rebuild.
        #expect(executor.uniformKeyIndex(for: pass).uniformKeys["foo"] == chosen)
        #expect(executor.uniformKeyIndexBuildCount == 1)
    }

    // MARK: - D. The six deliberate compatibility exceptions (§2.5)

    /// §2.5 "Scroll speed" — `WPEMetalEffectDispatchTable.swift:89`. The
    /// lowercase `speed` key is consulted in raw constants ONLY. Deliberate
    /// legacy chain, kept as a pixel invariant; do not fold into the generic one.
    @Test("scroll speed reads lowercase `speed` from constants only, never from uniformValues")
    func scrollSpeedException() {
        // The one asymmetry: `uniformValues["speed"]` is invisible…
        #expect(WPEEffectDispatchDescriptor.scrollSpeed(
            for: makePass(id: "d1a", shader: "effects/scroll", uniformValues: ["speed": .vector([9, 9])])
        ) == SIMD2<Float>(0.1, 0))
        // …while `constants["speed"]` is honoured.
        #expect(WPEEffectDispatchDescriptor.scrollSpeed(
            for: makePass(id: "d1b", shader: "effects/scroll", constants: ["speed": .vector([9, 8])])
        ) == SIMD2<Float>(9, 8))
        // Neither a case variant nor a `u_`-stripped spelling participates.
        #expect(WPEEffectDispatchDescriptor.scrollSpeed(
            for: makePass(
                id: "d1c",
                shader: "effects/scroll",
                constants: ["Speed": .vector([9, 9]), "U_SPEED": .vector([7, 7])],
                uniformValues: ["Speed": .vector([6, 6])]
            )
        ) == SIMD2<Float>(0.1, 0))
    }

    /// §2.5 "Water flow direction" — `WPEMetalEffectDispatchTable.swift:77`.
    /// Exact `u_Direction` only: no `direction` alias, no case fallback, no
    /// scalar conversion, no frame lookup. Deliberate legacy chain.
    @Test("water flow direction accepts only the exact u_Direction key")
    func waterFlowDirectionException() {
        #expect(WPEEffectDispatchDescriptor.waterFlowDirection(
            for: makePass(
                id: "d2a",
                shader: "effects/waterflow",
                constants: ["direction": .vector([1, 1]), "U_DIRECTION": .vector([2, 2])],
                uniformValues: ["Direction": .vector([3, 3]), "g_Direction": .vector([4, 4])]
            )
        ) == SIMD2<Float>(0, 0.1))
        // A scalar `.number` is not a vector, so it does not satisfy the chain.
        #expect(WPEEffectDispatchDescriptor.waterFlowDirection(
            for: makePass(id: "d2b", shader: "effects/waterflow", uniformValues: ["u_Direction": .number(5)])
        ) == SIMD2<Float>(0, 0.1))
        // Control: the exact key with a vector value does land, uniformValues
        // ahead of constants.
        #expect(WPEEffectDispatchDescriptor.waterFlowDirection(
            for: makePass(
                id: "d2c",
                shader: "effects/waterflow",
                constants: ["u_Direction": .vector([1, 1])],
                uniformValues: ["u_Direction": .vector([0.25, 0.75])]
            )
        ) == SIMD2<Float>(0.25, 0.75))
    }

    /// §2.5 "Color grading" / §2.8 item 3 — `WPEMetalEffectDispatchTable.swift:149`.
    /// Raw constants are never probed. Production calls this a known gap and
    /// preserves it; an ABI-only refactor must preserve it too.
    @Test("color grading never reads raw constants")
    func colorGradingException() {
        let constantsOnly = WPEEffectDispatchDescriptor.colorGradingUniforms(
            for: makePass(
                id: "d3a",
                shader: "effects/colorgrading",
                constants: [
                    "u_Lift": .vector([0.5, 0.5, 0.5, 0.5]),
                    "u_Gamma": .vector([2, 2, 2, 2]),
                    "u_Gain": .vector([3, 3, 3, 3])
                ]
            )
        )
        #expect(constantsOnly.lift == SIMD4<Float>(0, 0, 0, 0))
        #expect(constantsOnly.gamma == SIMD4<Float>(1, 1, 1, 1))
        #expect(constantsOnly.gain == SIMD4<Float>(1, 1, 1, 1))

        // Control: the same keys in `uniformValues` are read, so the ignore
        // above is about the SOURCE, not about the keys being wrong.
        let runtime = WPEEffectDispatchDescriptor.colorGradingUniforms(
            for: makePass(
                id: "d3b",
                shader: "effects/colorgrading",
                uniformValues: ["u_Lift": .vector([0.5, 0.5, 0.5, 0.5])]
            )
        )
        #expect(runtime.lift == SIMD4<Float>(0.5, 0.5, 0.5, 0.5))
        // No case fallback either.
        let caseVariant = WPEEffectDispatchDescriptor.colorGradingUniforms(
            for: makePass(id: "d3c", shader: "effects/colorgrading", uniformValues: ["u_GAIN": .vector([3, 3, 3, 3])])
        )
        #expect(caseVariant.gain == SIMD4<Float>(1, 1, 1, 1))
    }

    /// §2.5 "Water-waves/opacity mask slot" — `WPEMetalEffectDispatchTable.swift:103`.
    /// `textureBindings[1] ?? textures[1] ?? binds[1]`: raw `binds` come LAST
    /// here, the reverse of the translated custom-texture slot chain, which
    /// prefers `binds` over `textures`.
    @Test("the opacity/waterwaves mask slot puts raw binds LAST")
    func opacityMaskSlotOrderException() {
        // textures beats binds — the inversion vs the translated slot chain.
        #expect(WPEEffectDispatchDescriptor.opacityMaskReference(
            for: makePass(
                id: "d4a",
                shader: "effects/waterwaves",
                textures: [1: .asset("masks/textures.tex")],
                binds: [1: .asset("masks/binds.tex")]
            )
        ) == .asset("masks/textures.tex"))
        // The normalized binding table still outranks both.
        #expect(WPEEffectDispatchDescriptor.opacityMaskReference(
            for: makePass(
                id: "d4b",
                shader: "effects/waterwaves",
                textures: [1: .asset("masks/textures.tex")],
                binds: [1: .asset("masks/binds.tex")],
                bindings: [1: .asset("masks/bindings.tex")]
            )
        ) == .asset("masks/bindings.tex"))
        // Only slot 1 participates; slot 0 is the effect input.
        #expect(WPEEffectDispatchDescriptor.opacityMaskReference(
            for: makePass(id: "d4c", shader: "effects/waterwaves", binds: [0: .asset("masks/zero.tex")])
        ) == nil)
    }

    /// §2.5 "Generic model shaders". Tint / tint alpha / emissive / brightness
    /// read RAW CONSTANTS ONLY, while ambient and skylight read frame → pass
    /// values with no constants fallback. Two opposite gaps in one function.
    @Test("generic model tint reads raw constants only; ambient reads frame/pass only")
    func genericModelSplitSources() throws {
        let executor = try makeExecutor()
        let layer = makeLayer(objectID: "MODEL")

        // Tint: the authored constant wins and the runtime dictionary is unread.
        let tintPass = makePass(
            id: "d5a",
            shader: "models/generic4",
            constants: ["color": .vector([0.2, 0.3, 0.4]), "brightness": .number(0.5)],
            uniformValues: ["color": .vector([9, 9, 9]), "brightness": .number(9)]
        )
        let tint = executor.sceneModelGenericUniforms(for: tintPass, layer: layer, hasComponentMap: false)
        #expect(tint.tintColorAlpha == SIMD4<Float>(0.2, 0.3, 0.4, 1))
        #expect(tint.brightnessFlags.x == 0.5)

        // Tint from `uniformValues` alone resolves to the DEFAULT, proving the
        // dictionary is genuinely not a source here.
        let dictionaryOnly = makePass(
            id: "d5b",
            shader: "models/generic4",
            uniformValues: ["color": .vector([0.2, 0.3, 0.4])]
        )
        let defaulted = executor.sceneModelGenericUniforms(for: dictionaryOnly, layer: layer, hasComponentMap: false)
        #expect(defaulted.tintColorAlpha == SIMD4<Float>(1, 1, 1, 1))

        // Tint ALPHA and the emissive pair take the same constants-only route.
        // Authored red / runtime green (and 0.25 vs 0.9) so that a switch to
        // `uniformValues` cannot coincide with the authored answer.
        let emissivePass = makePass(
            id: "d5a2",
            shader: "models/generic4",
            constants: [
                "alpha": .number(0.25),
                "emissivecolor": .vector([1, 0, 0]),
                "emissivebrightness": .number(0.5)
            ],
            uniformValues: [
                "alpha": .number(0.9),
                "emissivecolor": .vector([0, 1, 0]),
                "emissivebrightness": .number(0.75)
            ]
        )
        let emissive = executor.sceneModelGenericUniforms(
            for: emissivePass, layer: layer, hasComponentMap: false
        )
        #expect(emissive.emissive == SIMD4<Float>(1, 0, 0, 0.5))
        // Layer alpha is 1 in the fixture, so this is the raw constant.
        #expect(emissive.tintColorAlpha.w == 0.25)

        // Same control as the tint RGB above, for both added paths: fed only
        // through the dictionary they resolve to the DEFAULTS, so the values
        // asserted above genuinely came from the constants tier.
        let emissiveDictionaryOnly = makePass(
            id: "d5b2",
            shader: "models/generic4",
            uniformValues: [
                "alpha": .number(0.25),
                "emissivecolor": .vector([1, 0, 0]),
                "emissivebrightness": .number(0.5)
            ]
        )
        let emissiveDefaulted = executor.sceneModelGenericUniforms(
            for: emissiveDictionaryOnly, layer: layer, hasComponentMap: false
        )
        #expect(emissiveDefaulted.emissive == SIMD4<Float>(1, 1, 1, 1))
        #expect(emissiveDefaulted.tintColorAlpha.w == 1)

        // Ambient/skylight: the mirror image — raw constants are ignored.
        let lightPass = makePass(
            id: "d5c",
            shader: "models/generic4",
            constants: ["g_LightAmbientColor": .vector([0, 0, 0]), "g_LightSkylightColor": .vector([0, 0, 0])],
            uniformValues: [
                "g_LightAmbientColor": .vector([0.5, 0.5, 0.5]),
                "g_LightSkylightColor": .vector([0.5, 0.5, 0.5])
            ]
        )
        let lit = executor.sceneModelGenericUniforms(for: lightPass, layer: layer, hasComponentMap: false)
        #expect(lit.ambientLighting == SIMD4<Float>(0.5, 0.5, 0.5, 1))

        let constantsOnlyLight = makePass(
            id: "d5d",
            shader: "models/generic4",
            constants: ["g_LightAmbientColor": .vector([0, 0, 0]), "g_LightSkylightColor": .vector([0, 0, 0])]
        )
        let unlit = executor.sceneModelGenericUniforms(
            for: constantsOnlyLight, layer: layer, hasComponentMap: false
        )
        #expect(unlit.ambientLighting == SIMD4<Float>(1, 1, 1, 1))
    }

    /// §2.5 "effects/skew". MODE=1 vertex params use a THIRD chain: exact
    /// `uniformValues[name] ?? constants[name]` interleaved PER CANDIDATE, so a
    /// constant on an earlier candidate beats a pass value on a later one —
    /// which neither the translated chain nor the builtin scalar helper does.
    @Test("skew MODE=1 interleaves uniformValues and constants per candidate")
    func skewInterleavedChain() throws {
        let executor = try makeExecutor()

        // Candidate order is ["top", "g_Top"]. The constant on `top` wins over
        // the pass value on `g_Top`.
        let interleaved = makePass(
            id: "d6a",
            shader: "effects/skew",
            constants: ["top": .number(0.5)],
            uniformValues: ["g_Top": .number(0.25)]
        )
        #expect(executor.vertexSkewParams(for: interleaved).topBottomLeftRight.x == 0.5)

        // Control: the translated chain given the SAME pass prefers `g_Top`,
        // because it exhausts every candidate's pass value before any constant.
        let layout = [
            WPEUniformSlot(
                name: "top", glslType: "float", slot: 0, slotCount: 1, materialName: "g_Top"
            )
        ]
        #expect(pack(layout, pass: interleaved, on: executor)[0].x == 0.25)

        // Phase 2/3: all case-insensitive uniformValues, then all
        // case-insensitive constants.
        let caseVariant = makePass(
            id: "d6b",
            shader: "effects/skew",
            constants: ["G_TOP": .number(0.5)],
            uniformValues: ["TOP": .number(0.25)]
        )
        #expect(executor.vertexSkewParams(for: caseVariant).topBottomLeftRight.x == 0.25)

        // The reduction scale multiplies all four corners and defaults to 1.
        let scaled = makePass(
            id: "d6c",
            shader: "effects/skew",
            constants: ["textureReductionScale": .number(0.5), "left": .number(0.4)]
        )
        #expect(executor.vertexSkewParams(for: scaled).topBottomLeftRight == SIMD4<Float>(0, 0, 0.2, 0))
    }

    // MARK: - E. Frame-global sub-precedence (§2.2)

    /// §2.2 "Frame-global sub-order": object (for THIS pass id) → runtime →
    /// camera. The three key sets are disjoint in production, so this is latent;
    /// it is tested by direct construction because a rewrite must keep it
    /// representable.
    @Test("Frame globals resolve object, then runtime, then camera")
    func frameGlobalSubOrder() {
        let context = WPEFrameUniformContext(
            runtimeUniformValues: ["g_Shared": .number(2), "g_RuntimeOnly": .number(20)],
            cameraUniformValues: ["g_Shared": .number(3), "g_CameraOnly": .number(30)],
            objectUniformValuesByPassID: ["pass.a": ["g_Shared": .number(1)]]
        )
        #expect(context.value(named: "g_Shared", passID: "pass.a") == .number(1))
        // A different pass id has no object entry, so runtime wins.
        #expect(context.value(named: "g_Shared", passID: "pass.b") == .number(2))
        // Camera is last: it is only reached when runtime lacks the name.
        #expect(context.value(named: "g_CameraOnly", passID: "pass.a") == .number(30))
        #expect(context.value(named: "g_RuntimeOnly", passID: "pass.a") == .number(20))
        #expect(context.value(named: "g_Absent", passID: "pass.a") == nil)

        // `frameValue` deliberately skips the object tier (runtime → camera).
        #expect(context.frameValue(named: "g_Shared") == .number(2))

        // The lowercased entry point maps back to a canonical spelling first and
        // returns nil for a name that is not a frame global at all.
        #expect(context.value(lowercasedName: "g_shared", passID: "pass.a") == nil)
        let canonical = WPEFrameUniformContext(
            runtimeUniformValues: ["g_Daytime": .number(0.75)],
            cameraUniformValues: [:],
            objectUniformValuesByPassID: [:]
        )
        #expect(canonical.value(lowercasedName: "g_daytime", passID: "p") == .number(0.75))
    }

    /// §2.2 "Canonical frame-global names": the index is derived from the
    /// producers, so this pins that the three producer families are all in it.
    @Test("The canonical frame-global name set covers runtime, camera and object producers")
    func canonicalFrameGlobalNames() {
        let names = WPEFrameUniformContext.canonicalNames
        for expected in [
            "g_Time", "g_Daytime", "g_Frametime", "g_Brightness", "g_PointerPosition", "g_ParallaxPosition",
            "g_PointerPositionLast", "g_PointerClickPosition", "g_PointerDown", "g_PointerRightDown",
            "g_AudioSpectrum16Left", "g_AudioSpectrum16Right",
            "g_AudioSpectrum32Left", "g_AudioSpectrum32Right",
            "g_AudioSpectrum64Left", "g_AudioSpectrum64Right",
            "g_RenderVar0", "g_RenderVar1", "g_RenderVar2", "g_RenderVar3", "g_HDRParams",
            "g_EyePosition", "g_ViewForward", "g_ViewRight", "g_ViewUp",
            "g_ViewProjectionMatrix", "g_LightAmbientColor", "g_LightSkylightColor", "g_SceneHDREnabled",
            "g_ModelMatrix", "g_ModelMatrixInverse", "g_ModelViewProjectionMatrix",
            "g_ModelViewProjectionMatrixInverse", "g_LayerModelMatrix", "g_NormalModelMatrix"
        ] {
            #expect(names.contains(expected), "missing canonical frame global \(expected)")
            #expect(WPEFrameUniformContext.canonicalNameByLowercased[expected.lowercased()] == expected)
        }
        // The derived probes are NOT frame globals (§2.2).
        #expect(!names.contains("g_TexelSize"))
        #expect(!names.contains("g_TexelSizeHalf"))
        #expect(!names.contains("g_Screen"))
        #expect(!names.contains("g_Texture0Resolution"))
        #expect(!names.contains("g_OrientationForward"))
        #expect(!names.contains("g_OrientationRight"))
        #expect(!names.contains("g_OrientationUp"))
    }

    // MARK: - F. Type and packing rules (§2.6)

    @Test("Matrices occupy consecutive slots in the documented layout")
    func matrixPacking() throws {
        let executor = try makeExecutor()
        let pass = makePass(
            id: "f1",
            uniformValues: [
                "u_M2": .vector([1, 2, 3, 4]),
                "u_M3": .vector([1, 2, 3, 4, 5, 6, 7, 8, 9]),
                "u_M4": .vector((1...16).map(Double.init))
            ]
        )
        let layout = [
            WPEUniformSlot(name: "u_M2", glslType: "mat2", slot: 0, slotCount: 2),
            WPEUniformSlot(name: "u_M3", glslType: "mat3", slot: 2, slotCount: 3),
            WPEUniformSlot(name: "u_M4", glslType: "mat4", slot: 5, slotCount: 4)
        ]
        let slots = pack(layout, pass: pass, on: executor)
        #expect(slots.count == 9)
        #expect(slots[0] == SIMD4<Float>(1, 2, 0, 0))
        #expect(slots[1] == SIMD4<Float>(3, 4, 0, 0))
        #expect(slots[2] == SIMD4<Float>(1, 2, 3, 0))
        #expect(slots[3] == SIMD4<Float>(4, 5, 6, 0))
        #expect(slots[4] == SIMD4<Float>(7, 8, 9, 0))
        #expect(slots[5] == SIMD4<Float>(1, 2, 3, 4))
        #expect(slots[6] == SIMD4<Float>(5, 6, 7, 8))
        #expect(slots[7] == SIMD4<Float>(9, 10, 11, 12))
        #expect(slots[8] == SIMD4<Float>(13, 14, 15, 16))
    }

    @Test("Arrays take one slot per element, with the element components in the low lanes")
    func arrayPacking() throws {
        let executor = try makeExecutor()
        let pass = makePass(
            id: "f2",
            uniformValues: [
                "u_V2": .vector([1, 2, 3, 4, 5, 6]),
                "u_V3": .vector([1, 2, 3, 4, 5, 6]),
                "u_V4": .vector((1...8).map(Double.init)),
                "u_F": .vector([1, 2, 3])
            ]
        )
        let layout = [
            WPEUniformSlot(name: "u_V2", glslType: "vec2", slot: 0, slotCount: 3, arrayLength: 3),
            WPEUniformSlot(name: "u_V3", glslType: "vec3", slot: 3, slotCount: 2, arrayLength: 2),
            WPEUniformSlot(name: "u_V4", glslType: "vec4", slot: 5, slotCount: 2, arrayLength: 2),
            WPEUniformSlot(name: "u_F", glslType: "float", slot: 7, slotCount: 3, arrayLength: 3)
        ]
        let slots = pack(layout, pass: pass, on: executor)
        #expect(Array(slots[0...2]) == [
            SIMD4<Float>(1, 2, 0, 0), SIMD4<Float>(3, 4, 0, 0), SIMD4<Float>(5, 6, 0, 0)
        ])
        #expect(Array(slots[3...4]) == [SIMD4<Float>(1, 2, 3, 0), SIMD4<Float>(4, 5, 6, 0)])
        #expect(Array(slots[5...6]) == [SIMD4<Float>(1, 2, 3, 4), SIMD4<Float>(5, 6, 7, 8)])
        #expect(Array(slots[7...9]) == [
            SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(2, 0, 0, 0), SIMD4<Float>(3, 0, 0, 0)
        ])
    }

    /// §2.8 item 4 — ACCIDENTAL: only `vec2`/`vec3`/`vec4` element types get
    /// multiple components. `ivec2[]`/`bvec2[]` collapse to one component per
    /// element, which is unsupported-type fallout rather than a designed ABI.
    @Test("Integer and boolean vector arrays collapse to one component per element")
    func integerVectorArraysCollapse() throws {
        let executor = try makeExecutor()
        let pass = makePass(id: "f3", uniformValues: ["u_IV2": .vector([1, 2, 3, 4])])
        let layout = [
            WPEUniformSlot(name: "u_IV2", glslType: "ivec2", slot: 0, slotCount: 2, arrayLength: 2)
        ]
        let slots = pack(layout, pass: pass, on: executor)
        #expect(slots[0] == SIMD4<Float>(1, 0, 0, 0))
        #expect(slots[1] == SIMD4<Float>(2, 0, 0, 0))
    }

    @Test("Short vectors zero-pad and the scalar/vector conversion table holds")
    func conversionAndZeroPadding() throws {
        let executor = try makeExecutor()
        let pass = makePass(
            id: "f4",
            uniformValues: [
                "u_Short": .vector([1]),
                "u_Bool": .bool(true),
                "u_BoolFalse": .bool(false),
                "u_NumberIntoVector": .number(5),
                "u_ParseableString": .string("2.5"),
                "u_BadString": .string("nope"),
                "u_BoolIntoVector": .bool(true)
            ]
        )
        let layout = [
            WPEUniformSlot(name: "u_Short", glslType: "vec3", slot: 0, slotCount: 1),
            WPEUniformSlot(name: "u_Bool", glslType: "float", slot: 1, slotCount: 1),
            WPEUniformSlot(name: "u_BoolFalse", glslType: "float", slot: 2, slotCount: 1),
            WPEUniformSlot(name: "u_NumberIntoVector", glslType: "vec3", slot: 3, slotCount: 1),
            WPEUniformSlot(name: "u_ParseableString", glslType: "float", slot: 4, slotCount: 1),
            WPEUniformSlot(name: "u_BadString", glslType: "float", slot: 5, slotCount: 1),
            // `.bool` has no vector conversion at all — it packs as all zero.
            WPEUniformSlot(name: "u_BoolIntoVector", glslType: "vec2", slot: 6, slotCount: 1)
        ]
        let slots = pack(layout, pass: pass, on: executor)
        #expect(slots[0] == SIMD4<Float>(1, 0, 0, 0))
        #expect(slots[1].x == 1)
        #expect(slots[2].x == 0)
        #expect(slots[3] == SIMD4<Float>(5, 0, 0, 0))
        #expect(slots[4].x == 2.5)
        #expect(slots[5].x == 0)
        #expect(slots[6] == SIMD4<Float>(0, 0, 0, 0))
    }

    /// §2.6 "Slot allocation" plus the MSL side of the same contract: the
    /// transpiler's slot arithmetic and the emitted accessors must agree with
    /// what `packTranslatedUniforms` writes, including `int(...)` truncation and
    /// the `> 0.5` boolean threshold.
    @Test("Transpiler slot allocation and the emitted MSL accessors match the packer")
    func transpilerSlotAllocationAndAccessors() throws {
        let source = """
        // stage: fragment
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform mat2 g_M2;
        uniform mat3 g_M3;
        uniform mat4 g_M4;
        uniform float g_F;
        uniform int g_I;
        uniform bool g_B;
        uniform ivec2 g_IV2;
        uniform bvec3 g_BV3;
        uniform vec2 g_A[3];
        uniform bool g_BA[2];
        in vec2 v_TexCoord;
        void main() {
            gl_FragColor = texture(g_Texture0, v_TexCoord) * g_F;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "characterization_layout",
            preprocessedSource: source
        )

        #expect(result.uniformLayout.map { "\($0.name)@\($0.slot)+\($0.slotCount)" } == [
            "g_M2@0+2",
            "g_M3@2+3",
            "g_M4@5+4",
            "g_F@9+1",
            "g_I@10+1",
            "g_B@11+1",
            "g_IV2@12+1",
            "g_BV3@13+1",
            "g_A@14+3",
            "g_BA@17+2"
        ])
        #expect(result.totalSlots == 19)

        let msl = result.mslSource
        #expect(msl.contains("float2x2 g_M2 = float2x2(u.vals[0].xy, u.vals[1].xy);"))
        #expect(msl.contains("float3x3 g_M3 = float3x3(u.vals[2].xyz, u.vals[3].xyz, u.vals[4].xyz);"))
        #expect(msl.contains("float4x4 g_M4 = float4x4(u.vals[5], u.vals[6], u.vals[7], u.vals[8]);"))
        #expect(msl.contains("float g_F = u.vals[9].x;"))
        // `int` truncates the float lane; `bool` uses the 0.5 threshold (§2.6).
        #expect(msl.contains("int g_I = int(u.vals[10].x);"))
        #expect(msl.contains("bool g_B = u.vals[11].x > 0.5;"))
        #expect(msl.contains("int2 g_IV2 = int2(u.vals[12].xy);"))
        #expect(msl.contains("bool3 g_BV3 = u.vals[13].xyz > float3(0.5);"))
        // Array elements read one slot each, in the element's low lanes.
        #expect(msl.contains("g_A[0] = u.vals[14].xy;"))
        #expect(msl.contains("g_A[2] = u.vals[16].xy;"))
        #expect(msl.contains("g_BA[0] = u.vals[17].x > 0.5;"))
        #expect(msl.contains("g_BA[1] = u.vals[18].x > 0.5;"))
    }

    // MARK: - G. Invalidation inputs (§2.7)

    /// §2.7 "Texture rebinding": the same slot resolves differently when the
    /// bound texture changes, and falls back to the named sources when unbound.
    @Test("g_TextureNResolution tracks the bound texture across frames")
    func textureResolutionTracksBinding() throws {
        let executor = try makeExecutor()
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pass = makePass(id: "g1", constants: ["g_Texture0Resolution": .vector([7, 7, 7, 7])])
        let layout = [
            WPEUniformSlot(name: "g_Texture0Resolution", glslType: "vec4", slot: 0, slotCount: 1)
        ]
        let textures = WPEMetalTextureSlotTable()

        #expect(pack(layout, pass: pass, on: executor, textures: textures)[0]
            == SIMD4<Float>(7, 7, 7, 7))

        textures[0] = try makeTexture(device: device, width: 16, height: 8)
        #expect(pack(layout, pass: pass, on: executor, textures: textures)[0]
            == SIMD4<Float>(16, 8, 16, 8))

        textures[0] = try makeTexture(device: device, width: 4, height: 2)
        #expect(pack(layout, pass: pass, on: executor, textures: textures)[0]
            == SIMD4<Float>(4, 2, 4, 2))

        textures.reset()
        #expect(pack(layout, pass: pass, on: executor, textures: textures)[0]
            == SIMD4<Float>(7, 7, 7, 7))
    }

    /// §2.7 "Render-pixel scale or scene pixel size" and §2.2 priority 1: the
    /// packer derives `g_TexelSize` from the scene's PIXEL size — the FBO chain
    /// head under render scaling — and that derived value OVERRIDES an authored
    /// one. Packed end to end (not helper-composed) because the two failures
    /// worth catching both live in `resolvedUniformValue`: sourcing the world
    /// size instead of the pixel size, and losing the override.
    @Test("g_TexelSize packs 1/scene-pixel-size and overrides an authored value")
    func texelSizeTracksRenderScale() throws {
        let executor = try makeExecutor()
        let world = CGSize(width: 3840, height: 2160)
        let half = WPEMetalFXSpatialUpscaler.scaledCanvasSize(world, pixelScale: 0.5)
        #expect(WPEMetalFXSpatialUpscaler.scaledCanvasSize(world, pixelScale: 1) == world)
        #expect(half == CGSize(width: 1920, height: 1080))

        func texel(_ width: Double, _ height: Double) -> SIMD4<Float> {
            SIMD4<Float>(Float(1 / width), Float(1 / height), 0, 0)
        }
        let layout = [WPEUniformSlot(name: "g_TexelSize", glslType: "vec2", slot: 0, slotCount: 1)]
        // The authored value is the control AND the override probe: it is a
        // legal pass value for this exact name, so anything but the derived
        // reciprocal below means the derived probe stopped winning.
        let pass = makePass(id: "g2", uniformValues: ["g_TexelSize": .vector([-1, -1])])

        executor.setCurrentScenePixelSizeForTesting(world)
        #expect(pack(layout, pass: pass, on: executor)[0] == texel(3840, 2160))

        // Half render scale ⇒ the texel doubles. A packer reading the WORLD size
        // would leave this at 1/3840 — the blur-kernel-width regression.
        executor.setCurrentScenePixelSizeForTesting(half)
        #expect(pack(layout, pass: pass, on: executor)[0] == texel(1920, 1080))

        // Degenerate dimensions make the probe non-terminal (§2.2 row 1), and
        // that fallback is what proves the -1 was reachable all along.
        executor.setCurrentScenePixelSizeForTesting(.zero)
        #expect(pack(layout, pass: pass, on: executor)[0] == SIMD4<Float>(-1, -1, 0, 0))
        executor.setCurrentScenePixelSizeForTesting(CGSize(width: 100, height: 0))
        #expect(pack(layout, pass: pass, on: executor)[0] == SIMD4<Float>(-1, -1, 0, 0))

        // Only this one name is derived; every other uniform keeps the chain.
        executor.setCurrentScenePixelSizeForTesting(half)
        let otherName = [WPEUniformSlot(name: "g_TexelSize2", glslType: "vec2", slot: 0, slotCount: 1)]
        let otherPass = makePass(id: "g2b", uniformValues: ["g_TexelSize2": .vector([-1, -1])])
        #expect(pack(otherName, pass: otherPass, on: executor)[0] == SIMD4<Float>(-1, -1, 0, 0))
    }

    /// Official docs define these from the same screen pixel dimensions as
    /// `g_TexelSize`. They are terminal derived probes so authored values cannot
    /// become stale when render scale changes.
    @Test("g_TexelSizeHalf and g_Screen derive from render-pixel size")
    func halfTexelAndScreenTrackRenderScale() throws {
        let executor = try makeExecutor()
        let layout = [
            WPEUniformSlot(name: "g_TexelSizeHalf", glslType: "vec2", slot: 0, slotCount: 1),
            WPEUniformSlot(name: "g_Screen", glslType: "vec3", slot: 1, slotCount: 1)
        ]
        let pass = makePass(
            id: "g2c",
            uniformValues: [
                "g_TexelSizeHalf": .vector([-1, -1]),
                "g_Screen": .vector([-1, -1, -1])
            ]
        )

        let plans = executor.uniformPlans(for: pass, layout: layout)
        #expect(plans[0].isTexelSizeHalf)
        #expect(plans[1].isScreen)

        executor.setCurrentScenePixelSizeForTesting(CGSize(width: 1920, height: 1080))
        let full = pack(layout, pass: pass, on: executor)
        #expect(abs(full[0].x - Float(0.5 / 1920.0)) < 0.0000001)
        #expect(abs(full[0].y - Float(0.5 / 1080.0)) < 0.0000001)
        #expect(full[1] == SIMD4<Float>(1920, 1080, Float(1920.0 / 1080.0), 0))

        executor.setCurrentScenePixelSizeForTesting(CGSize(width: 960, height: 540))
        let half = pack(layout, pass: pass, on: executor)
        #expect(abs(half[0].x - Float(0.5 / 960.0)) < 0.0000001)
        #expect(half[1] == SIMD4<Float>(960, 540, Float(960.0 / 540.0), 0))

        executor.setCurrentScenePixelSizeForTesting(.zero)
        let fallback = pack(layout, pass: pass, on: executor)
        #expect(fallback[0] == SIMD4<Float>(-1, -1, 0, 0))
        #expect(fallback[1] == SIMD4<Float>(-1, -1, -1, 0))
    }

    @Test("g_Frametime is fed from logical runtime deltas and survives same-frame re-encode")
    func shaderFrametimeTracksLogicalFrames() throws {
        let executor = try makeExecutor()
        let layout = [WPEUniformSlot(name: "g_Frametime", glslType: "float", slot: 0, slotCount: 1)]
        let pass = makePass(id: "g2d", uniformValues: ["g_Frametime": .number(-1)])

        func frame(_ delta: Double) -> WPEFrameUniformContext {
            var runtime = characterizationRuntime
            runtime.frameTime = delta
            return WPEFrameUniformContext(
                runtimeUniformValues: runtime.uniformValues,
                cameraUniformValues: [:],
                objectUniformValuesByPassID: [:]
            )
        }

        #expect(executor.advanceShaderFrameTime(runtimeTime: 10) == 0)
        #expect(pack(layout, pass: pass, on: executor, frame: frame(executor.currentShaderFrameTime))[0].x == 0)

        let delta = executor.advanceShaderFrameTime(runtimeTime: 10.025)
        #expect(abs(delta - 0.025) < 0.0000001)
        #expect(abs(pack(layout, pass: pass, on: executor, frame: frame(delta))[0].x - 0.025) < 0.000001)

        // Fail-close may encode twice at one timestamp; both encodes are one
        // logical frame and must receive the same shader delta.
        #expect(executor.advanceShaderFrameTime(runtimeTime: 10.025) == delta)

        #expect(executor.advanceShaderFrameTime(runtimeTime: 2) == 0)
        executor.resetShaderFrameTime()
        #expect(executor.advanceShaderFrameTime(runtimeTime: 5) == 0)
    }

    /// §2.7 "Elapsed animation time": the per-frame prepare resolves `.animated`
    /// values at the frame clock before the packer runs, so the same slot moves
    /// across frames. An `.animated` value that reaches the packer unresolved is
    /// sampled at time ZERO instead (§2.6).
    @Test("Animated values move with the frame clock; an unresolved one samples at time zero")
    func animatedValuesTrackTime() throws {
        let executor = try makeExecutor()
        let animated = try #require(makeAnimatedConstant())
        let layout = [WPEUniformSlot(name: "u_Anim", glslType: "float", slot: 0, slotCount: 1)]

        // The fixture is one track, fps 30, keyframes frame 0 → 0 and frame 60 → 1,
        // mode "single" with no wraploop. `WPESceneNumericAnimation` therefore
        // clamps rather than wraps, and interpolates linearly between the two
        // keys, so the closed form is `min(time * 30, 60) / 60`. Exact values,
        // not a monotonic trend: sampling at `time * 0.5` still rises.
        let expectations: [(time: Double, value: Float)] = [
            (0, 0),        // at the first key
            (0.5, 0.25),   // frame 15 of 60
            (1.0, 0.5),
            (1.5, 0.75),
            (3.0, 1)       // frame 90 clamps to the last key, it does not wrap to 0.5
        ]
        for (index, expectation) in expectations.enumerated() {
            // Mirrors `WPERenderPipeline`'s per-frame `mapValues { $0.resolved(at:) }`.
            let pass = makePass(
                id: "g3.\(index)",
                uniformValues: ["u_Anim": animated.resolved(at: expectation.time)]
            )
            #expect(
                pack(layout, pass: pass, on: executor)[0].x == expectation.value,
                "t=\(expectation.time)"
            )
        }

        // Unresolved: the packer samples the animation at time zero regardless
        // of the frame clock, which is why the prepare step must resolve first.
        // The frame clock here is 2.5s, which would read 1 if it were honoured.
        let unresolved = makePass(id: "g3.raw", uniformValues: ["u_Anim": animated])
        #expect(pack(layout, pass: unresolved, on: executor, frame: makeFrame())[0].x == 0)
    }
}

// MARK: - Fixtures

private enum CharacterizationFixtureError: Error {
    case noMetalDevice
    case textureAllocationFailed
}

private func makeExecutor() throws -> WPEMetalRenderExecutor {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw CharacterizationFixtureError.noMetalDevice
    }
    return try WPEMetalRenderExecutor(device: device)
}

private func makePass(
    id: String,
    shader: String = "effects/characterization",
    constants: [String: WPESceneShaderConstantValue] = [:],
    uniformValues: [String: WPESceneShaderConstantValue] = [:],
    materialUniformNames: [String: String] = [:],
    textures: [Int: WPETextureReference] = [:],
    binds: [Int: WPETextureReference] = [:],
    bindings: [Int: WPETextureReference] = [:]
) -> WPEPreparedRenderPass {
    WPEPreparedRenderPass(
        pass: WPERenderPass(
            id: id,
            phase: .effect(file: "effects/characterization/effect.json"),
            shader: shader,
            source: .previous,
            target: .scene,
            textures: textures,
            binds: binds,
            constants: constants,
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        ),
        shader: WPEShaderProgram(name: shader, vertexSource: "", fragmentSource: "", isBuiltin: false),
        textureBindings: bindings,
        comboValues: [:],
        uniformValues: uniformValues,
        materialUniformNames: materialUniformNames
    )
}

private func makeLayer(objectID: String) -> WPERenderLayer {
    WPERenderLayer(
        objectID: objectID,
        objectName: "Layer \(objectID)",
        imagePath: "materials/base.png",
        materialPath: nil,
        geometry: WPERenderLayerGeometry(
            origin: SIMD3<Double>(0, 0, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0),
            alignment: .center,
            size: CGSize(width: 64, height: 64),
            alpha: 1,
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1
        ),
        compositeA: "a",
        compositeB: "b",
        localFBOs: [],
        passes: []
    )
}

private let characterizationRuntime = WPEMetalRuntimeUniforms(
    time: 2.5,
    daytime: 0.75,
    brightness: 0.6,
    pointerPosition: SIMD2<Double>(0.1, 0.9)
)

private func makeFrame() -> WPEFrameUniformContext {
    WPEFrameUniformContext(
        runtimeUniformValues: characterizationRuntime.uniformValues,
        cameraUniformValues: WPEMetalCameraUniforms.identity.uniformValues,
        objectUniformValuesByPassID: [:]
    )
}

private func makeTexture(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: width,
        height: height,
        mipmapped: false
    )
    descriptor.usage = [.shaderRead]
    guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw CharacterizationFixtureError.textureAllocationFailed
    }
    return texture
}

private func makeAnimatedConstant() -> WPESceneShaderConstantValue? {
    let raw: [String: Any] = [
        "value": 0.0,
        "animation": [
            "c0": [
                ["frame": 0, "value": 0.0],
                ["frame": 60, "value": 1.0]
            ],
            "options": ["fps": 30, "length": 60, "mode": "single"]
        ] as [String: Any]
    ]
    return WPEValueParser.shaderConstant(raw)
}

private func pack(
    _ layout: [WPEUniformSlot],
    pass: WPEPreparedRenderPass,
    on executor: WPEMetalRenderExecutor,
    frame: WPEFrameUniformContext = .empty,
    textures: WPEMetalTextureSlotTable? = nil
) -> [SIMD4<Float>] {
    executor.frameUniformContext = frame
    defer { executor.frameUniformContext = .empty }
    return executor.packTranslatedUniforms(for: pass, layout: layout, texturesBySlot: textures)
}

private func planSteps(
    _ layout: [WPEUniformSlot],
    pass: WPEPreparedRenderPass,
    on executor: WPEMetalRenderExecutor
) -> [[WPEMetalRenderExecutor.UniformResolutionStep]] {
    executor.uniformPlans(for: pass, layout: layout).map(\.steps)
}
#endif
