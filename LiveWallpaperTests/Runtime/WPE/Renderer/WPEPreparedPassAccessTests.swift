#if !LITE_BUILD
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Testing

@Suite("Prepared pass access facts")
struct WPEPreparedPassAccessTests {
    @Test("Raw previous survives normalized chain-input binding with its slot provenance")
    func rawAndPreparedOriginsStayDistinct() {
        let raw = makePass(
            source: .fbo("chain-input"),
            textures: [2: .asset("mask")],
            binds: [0: .previous]
        )
        let prepared = prepare(raw, bindings: [0: .fbo("chain-input"), 7: .image("aux")])
        let access = prepared.access
        #expect(access.source == .fbo("chain-input"))
        #expect(access.rawTextures[2] == .asset("mask"))
        #expect(access.rawBinds[0] == .previous)
        #expect(access.preparedBindings[0] == .fbo("chain-input"))
        #expect(Array(access.references(in: .rawBinds)) == [.previous])
        #expect(access.references(in: .preparedBindings).contains(.fbo("chain-input")))
        #expect(access.hasPreviousReference)
        #expect(access.hasNamedFBOReference)
        #expect(!access.hasSceneAliasReference)
        #expect(access.fboNames == ["chain-input", "chain-input"], "do not silently deduplicate raw/prepared references")
        #expect(prepared.textureReferences.count == 5)
    }

    @Test("Scene aliases and named FBOs are distinct; assets with similar names stay external")
    func sceneAndNamedClassification() {
        let sceneOnly = prepare(makePass(source: .fbo("_rt_FullFrameBuffer")))
        #expect(sceneOnly.access.hasSceneAliasReference)
        #expect(!sceneOnly.access.hasNamedFBOReference)
        #expect(!sceneOnly.access.hasPreviousReference)
        let named = prepare(makePass(source: .fbo("scratch"), textures: [1: .fbo("_rt_Mip4")]))
        #expect(named.access.hasSceneAliasReference && named.access.hasNamedFBOReference)
        let external = prepare(makePass(source: .asset("_rt_FullFrameBuffer")))
        #expect(external.access.fboNames.isEmpty)
        #expect(!external.access.hasSceneAliasReference && !external.access.hasNamedFBOReference)
    }

    @Test("Value-only rebuilds share immutable access; callers cannot mutate cached reference storage")
    func sharingAndCopyOnWrite() {
        let original = prepare(makePass(textures: [0: .image("base")]), bindings: [1: .asset("mask")])
        let valueOnly = WPEPreparedRenderPass(
            pass: original.pass.replacingBlending("additive"), shader: nil,
            textureBindings: original.textureBindings, comboValues: ["TEST": 1],
            uniformValues: ["g_Alpha": .number(0.5)], reusingAccess: original.access
        )
        #expect(valueOnly.access === original.access)
        var references = valueOnly.textureReferences
        references[0] = .previous
        #expect(original.textureReferences[0] == .image("source"))
        #expect(!original.access.hasPreviousReference)
        var bindings = original.textureBindings
        bindings[1] = .fbo("changed")
        #expect(original.access.preparedBindings[1] == .asset("mask"))
    }

    @Test("Every reference origin and target invalidate reuse; unrelated pass values do not")
    func reuseValidation() {
        let original = prepare(makePass(textures: [0: .image("raw")], binds: [2: .asset("bind")]), bindings: [3: .asset("prepared")])
        let variants: [WPERenderPass] = [
            makePass(source: .previous, textures: original.pass.textures, binds: original.pass.binds),
            makePass(textures: [0: .fbo("changed-raw")], binds: original.pass.binds),
            makePass(textures: original.pass.textures, binds: [2: .previous]),
            original.pass.replacingTarget(.fbo(name: "other-target")),
        ]
        for raw in variants {
            let changed = prepare(raw, bindings: original.textureBindings, reusing: original.access)
            #expect(changed.access !== original.access)
            #expect(changed.access.matches(pass: raw, textureBindings: original.textureBindings))
        }
        let changedPrepared = prepare(original.pass, bindings: [3: .previous], reusing: original.access)
        #expect(changedPrepared.access !== original.access)
        #expect(changedPrepared.access.hasPreviousReference)
    }

    @Test("Cache identity and dictionary enumeration order do not change pass equality")
    func equalityKeepsValueSemantics() {
        var forward: [Int: WPETextureReference] = [:]
        var reverse: [Int: WPETextureReference] = [:]
        for slot in 0 ..< 12 {
            forward[slot] = .fbo("target-\(slot)")
        }
        for slot in (0 ..< 12).reversed() {
            reverse[slot] = .fbo("target-\(slot)")
        }
        let first = prepare(makePass(textures: forward), bindings: forward)
        let second = prepare(makePass(textures: reverse), bindings: reverse)
        #expect(first.access !== second.access)
        #expect(first.access == second.access)
        #expect(first == second)
        #expect(prepare(makePass()).access.references(in: .preparedBindings).isEmpty)
    }

    private func prepare(
        _ pass: WPERenderPass,
        bindings: [Int: WPETextureReference] = [:],
        reusing: WPEPreparedPassAccess? = nil
    ) -> WPEPreparedRenderPass {
        WPEPreparedRenderPass(
            pass: pass, shader: nil, textureBindings: bindings, comboValues: [:],
            uniformValues: [:], reusingAccess: reusing
        )
    }

    private func makePass(
        source: WPETextureReference = .image("source"),
        textures: [Int: WPETextureReference] = [:],
        binds: [Int: WPETextureReference] = [:]
    ) -> WPERenderPass {
        WPERenderPass(
            id: "pass", phase: .material, shader: "copy", source: source, target: .scene,
            textures: textures, binds: binds, constants: [:], combos: [:],
            blending: "normal", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
        )
    }
}
#endif
