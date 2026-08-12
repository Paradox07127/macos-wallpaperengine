#if !LITE_BUILD && DEBUG
import LiveWallpaperProWPE
import Metal

extension WPEMetalShaderDispatcher {
    struct BuiltinTraceMetadata: Equatable {
        let fragmentShaderName: String
        let textureSlots: [Int]
    }

    /// Static portion of the builtin trace contract. Tests pin total enum
    /// coverage so a newly added builtin cannot silently disappear from Mac
    /// oracle traces again.
    static func builtinTraceMetadata(
        for kind: WPEBuiltinShaderKind,
        passShader: String
    ) -> BuiltinTraceMetadata {
        if let effect = WPEEffectDispatchDescriptor.table[kind] {
            let slots = kind == .effectOpacity || kind == .effectWaterWaves ? [0, 1] : [0]
            return BuiltinTraceMetadata(
                fragmentShaderName: effect.fragmentName,
                textureSlots: slots
            )
        }
        switch kind {
        case .solidColor:
            return BuiltinTraceMetadata(fragmentShaderName: "wpe_solidcolor_fragment", textureSlots: [])
        case .solidLayer:
            return BuiltinTraceMetadata(fragmentShaderName: "wpe_solidlayer_fragment", textureSlots: [])
        case .copy:
            let fragment = passShader == "commands/copy"
                ? "wpe_copy_fragment"
                : "wpe_util_copy_fragment"
            return BuiltinTraceMetadata(fragmentShaderName: fragment, textureSlots: [0])
        case .blendComposite:
            return BuiltinTraceMetadata(fragmentShaderName: "wpe_blend_composite_fragment", textureSlots: [0, 4])
        case .compose:
            return BuiltinTraceMetadata(fragmentShaderName: "wpe_compose_fragment", textureSlots: [0, 1])
        case .genericImage2:
            return BuiltinTraceMetadata(fragmentShaderName: "wpe_genericimage2_fragment", textureSlots: [0])
        case .genericImage4:
            return BuiltinTraceMetadata(fragmentShaderName: "wpe_genericimage4_fragment", textureSlots: [0, 1])
        case .genericParticle:
            return BuiltinTraceMetadata(fragmentShaderName: "wpe_genericparticle_fragment", textureSlots: [0])
        case .effectColorBalance, .effectBlur, .effectVignette, .effectWater,
             .effectOpacity, .effectScroll, .effectPulse, .effectIris,
             .effectWaterWaves, .effectSpin, .effectTint, .effectFoliageSway,
             .effectWaterRipple, .effectBlend, .effectWaterFlow,
             .effectColorGrading, .effectShimmer, .effectShake:
            preconditionFailure("Every effect builtin must have a dispatch descriptor")
        }
    }

    func recordBuiltinTracePass(
        kind: WPEBuiltinShaderKind,
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState
    ) {
        let recorder = WPECanonicalTraceRecorder.shared
        guard recorder.isAccumulating else { return }

        var metadata = Self.builtinTraceMetadata(for: kind, passShader: pass.pass.shader)
        let firstReference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let singleTextureCompose = kind == .compose
            && isSceneCaptureUtilityLayer(layer)
            && isLayerCompositeTarget(pass.pass.target)
            && (isSceneAliasReference(firstReference)
                || isGroupCompositeSourceReference(firstReference, layer: layer))
        if singleTextureCompose {
            metadata = BuiltinTraceMetadata(
                fragmentShaderName: layer.groupCompositeSource == nil
                    && isSceneAliasReference(firstReference)
                    && executor.sceneCaptureUtilityOutputGeometry(for: layer) == .subregion
                        ? "wpe_local_scene_capture_fragment"
                        : "wpe_composelayer_fragment",
                textureSlots: [0]
            )
        }

        let usesObjectQuad: Bool
        if singleTextureCompose || kind == .genericParticle {
            usesObjectQuad = false
        } else if let effect = WPEEffectDispatchDescriptor.table[kind] {
            let parallax = effect.appliesCameraParallax ? frameState.cameraParallax : .neutral
            usesObjectQuad = effect.supportsObjectQuad
                && executor.usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: parallax)
        } else {
            usesObjectQuad = executor.usesObjectQuadGeometry(
                for: pass,
                layer: layer,
                cameraParallax: frameState.cameraParallax
            )
        }

        var primaryTexture: MTLTexture?
        var bindings: [WPECanonicalTraceRecorder.TextureBindingInput] = []
        for slot in metadata.textureSlots {
            let resolved = builtinTraceReference(
                for: kind,
                slot: slot,
                pass: pass,
                firstReference: firstReference
            )
            let texture = resolved.reference.flatMap {
                try? WPEMetalShaderInputs.resolve(
                    reference: $0,
                    textures: textures,
                    frameState: frameState,
                    currentTargetID: destination.id
                )
            } ?? (resolved.fallbackToPrimary ? primaryTexture : nil)
            if slot == 0 { primaryTexture = texture }
            bindings.append(WPECanonicalTraceRecorder.TextureBindingInput(
                slot: slot,
                name: "g_Texture\(slot)",
                reference: resolved.reference,
                texture: texture,
                fallbackToPrimary: resolved.fallbackToPrimary
            ))
        }

        recorder.recordBuiltinPass(
            pass: pass,
            layer: layer,
            destination: destination,
            builtinKind: kind.rawValue,
            vertexShaderName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
            fragmentShaderName: metadata.fragmentShaderName,
            textureBindings: bindings,
            usesObjectQuad: usesObjectQuad
        )
    }

    private func builtinTraceReference(
        for kind: WPEBuiltinShaderKind,
        slot: Int,
        pass: WPEPreparedRenderPass,
        firstReference: WPETextureReference
    ) -> (reference: WPETextureReference?, fallbackToPrimary: Bool) {
        switch (kind, slot) {
        case (.blendComposite, 4):
            return (pass.textureBindings[4] ?? pass.pass.textures[4], false)
        case (.compose, 1):
            let second = pass.textureBindings[1] ?? pass.pass.textures[1]
            return (second ?? firstReference, second == nil)
        case (.genericImage4, 1):
            let mask = pass.textureBindings[1] ?? pass.pass.textures[1]
            return (mask, mask == nil)
        case (.effectOpacity, 1), (.effectWaterWaves, 1):
            let mask = WPEEffectDispatchDescriptor.opacityMaskReference(for: pass)
            return (mask, mask == nil)
        default:
            return (firstReference, false)
        }
    }
}
#endif
