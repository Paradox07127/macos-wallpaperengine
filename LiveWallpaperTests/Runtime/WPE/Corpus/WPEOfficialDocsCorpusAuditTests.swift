#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

/// Opt-in, path-redacted inventory used by the official-document parity audit.
/// It deliberately uses the shipping PKGV index and scene parser instead of a
/// second reverse-engineered package reader.
@Suite("WPE official-doc corpus audit")
struct WPEOfficialDocsCorpusAuditTests {
    private struct Config: Codable {
        let corpusRoot: String
        let output: String
    }

    private static let officialDocumentationCommit = "b26412295cbfd0ee5cdceff67e2c95069527aa1b"
    private static let allowedContractStatuses = Set(["implemented", "partial", "missing"])
    private static let allowedEvidenceLevels = Set(["L0.5", "L1_REQUIRED"])

    private static func shaderContract(
        _ name: String,
        type: String,
        scope: String,
        updateFrequency: String,
        status: String,
        evidence: String,
        producer: String,
        limitation: String = ""
    ) -> [String: String] {
        [
            "name": name,
            "type": type,
            "scope": scope,
            "updateFrequency": updateFrequency,
            "status": status,
            "evidence": evidence,
            "producer": producer,
            "limitation": limitation
        ]
    }

    private static var shaderGlobalContracts: [[String: String]] {
        var contracts: [[String: String]] = [
            shaderContract("g_Time", type: "float", scope: "frame", updateFrequency: "logicalFrame", status: "implemented", evidence: "L0.5", producer: "WPEMetalRuntimeUniforms.time"),
            shaderContract("g_Daytime", type: "float", scope: "frame", updateFrequency: "logicalFrame", status: "implemented", evidence: "L0.5", producer: "WPEMetalRuntimeUniforms.daytime"),
            shaderContract("g_Frametime", type: "float", scope: "frame", updateFrequency: "logicalFrame", status: "implemented", evidence: "L1_REQUIRED", producer: "WPEMetalRenderExecutor.advanceShaderFrameTime", limitation: "First-frame and rewind timing policy is host-defined until Windows capture."),
            shaderContract("g_PointerPosition", type: "vec2", scope: "frame", updateFrequency: "logicalFrame", status: "implemented", evidence: "L1_REQUIRED", producer: "WPEMetalPointerSampler", limitation: "Coordinate warp has scene-specific L1 evidence, not a complete WPE version contract."),
            shaderContract("g_PointerPositionLast", type: "vec2", scope: "frame", updateFrequency: "logicalFrame", status: "implemented", evidence: "L1_REQUIRED", producer: "WPEMetalPointerSampler"),
            shaderContract("g_TexelSize", type: "vec2", scope: "sceneRenderTarget", updateFrequency: "drawableOrScaleChange", status: "implemented", evidence: "L1_REQUIRED", producer: "WPEMetalRenderExecutor.texelSizeValue", limitation: "Uses the FBO-chain head resolution from current RenderDoc evidence."),
            shaderContract("g_TexelSizeHalf", type: "vec2", scope: "sceneRenderTarget", updateFrequency: "drawableOrScaleChange", status: "implemented", evidence: "L0.5", producer: "WPEMetalRenderExecutor.texelSizeHalfValue"),
            shaderContract("g_Screen", type: "vec3", scope: "sceneRenderTarget", updateFrequency: "drawableOrScaleChange", status: "implemented", evidence: "L0.5", producer: "WPEMetalRenderExecutor.screenValue"),
            shaderContract("g_Alpha", type: "float", scope: "draw", updateFrequency: "draw", status: "partial", evidence: "L1_REQUIRED", producer: "pass constants plus generic-image alpha path", limitation: "Not a single canonical producer for every translated object domain."),
            shaderContract("g_Color", type: "vec3", scope: "draw", updateFrequency: "draw", status: "partial", evidence: "L1_REQUIRED", producer: "material/pass constants plus layer tint", limitation: "Color-space and object-domain rules are only characterized for current image paths."),
            shaderContract("g_Color4", type: "vec4", scope: "draw", updateFrequency: "draw", status: "partial", evidence: "L1_REQUIRED", producer: "generic-image layer tint specialization", limitation: "Not wired as a universal translated-pass global."),
            shaderContract("g_ParallaxPosition", type: "vec2", scope: "layerFrame", updateFrequency: "logicalFrame", status: "implemented", evidence: "L1_REQUIRED", producer: "WPEMetalRuntimeUniforms.parallaxPosition"),

            shaderContract("g_EyePosition", type: "vec3", scope: "cameraFrame", updateFrequency: "logicalFrame", status: "implemented", evidence: "L1_REQUIRED", producer: "WPEMetalCameraUniforms.sceneCamera.eye", limitation: "Current renderer camera model is narrower than WPE's documented 3D camera selection/path behavior."),
            shaderContract("g_ViewForward", type: "vec3", scope: "cameraFrame", updateFrequency: "logicalFrame", status: "partial", evidence: "L1_REQUIRED", producer: "WPEMetalCameraUniforms identity-view basis", limitation: "Correct for the current identity-view renderer; arbitrary camera orientation is not implemented."),
            shaderContract("g_ViewRight", type: "vec3", scope: "cameraFrame", updateFrequency: "logicalFrame", status: "partial", evidence: "L1_REQUIRED", producer: "WPEMetalCameraUniforms identity-view basis", limitation: "Correct for the current identity-view renderer; arbitrary camera orientation is not implemented."),
            shaderContract("g_ViewUp", type: "vec3", scope: "cameraFrame", updateFrequency: "logicalFrame", status: "partial", evidence: "L1_REQUIRED", producer: "WPEMetalCameraUniforms identity-view basis", limitation: "Correct for the current identity-view renderer; arbitrary camera orientation is not implemented."),
            shaderContract("g_OrientationForward", type: "vec3", scope: "particleObject", updateFrequency: "drawOrInstance", status: "missing", evidence: "L1_REQUIRED", producer: "none", limitation: "Emitter, particle, billboard, trail, and rope basis/update frequency are not interchangeable."),
            shaderContract("g_OrientationRight", type: "vec3", scope: "particleObject", updateFrequency: "drawOrInstance", status: "missing", evidence: "L1_REQUIRED", producer: "none", limitation: "Particle built-in draw path bypasses translated-pass uniform packing."),
            shaderContract("g_OrientationUp", type: "vec3", scope: "particleObject", updateFrequency: "drawOrInstance", status: "missing", evidence: "L1_REQUIRED", producer: "none", limitation: "X/Y particle rotation and official orientation basis are not implemented."),
            shaderContract("g_ModelMatrix", type: "mat4x4", scope: "object", updateFrequency: "objectTransformChange", status: "implemented", evidence: "L1_REQUIRED", producer: "WPEMetalObjectUniforms.modelMatrix"),
            shaderContract("g_ModelMatrixInverse", type: "mat4x4", scope: "object", updateFrequency: "objectTransformChange", status: "implemented", evidence: "L1_REQUIRED", producer: "WPEMetalObjectUniforms.safeInverse"),
            shaderContract("g_ViewProjectionMatrix", type: "mat4x4", scope: "cameraFrame", updateFrequency: "logicalFrame", status: "implemented", evidence: "L1_REQUIRED", producer: "WPEMetalCameraUniforms.viewProjectionMatrix"),
            shaderContract("g_ModelViewProjectionMatrix", type: "mat4x4", scope: "objectCameraFrame", updateFrequency: "logicalFrame", status: "implemented", evidence: "L1_REQUIRED", producer: "WPEMetalObjectUniforms.cameraComposedValue"),
            shaderContract("g_ModelViewProjectionMatrixInverse", type: "mat4x4", scope: "objectCameraFrame", updateFrequency: "logicalFrame", status: "implemented", evidence: "L1_REQUIRED", producer: "WPEMetalObjectUniforms.cameraComposedValue"),

            shaderContract("g_EffectModelMatrix", type: "mat4x4", scope: "effectPass", updateFrequency: "pass", status: "missing", evidence: "L1_REQUIRED", producer: "none", limitation: "Effect space cannot be substituted with layer model space."),
            shaderContract("g_EffectModelViewProjectionMatrix", type: "mat4x4", scope: "effectPass", updateFrequency: "pass", status: "missing", evidence: "L1_REQUIRED", producer: "none"),
            shaderContract("g_EffectModelViewProjectionMatrixInverse", type: "mat4x4", scope: "effectPass", updateFrequency: "pass", status: "missing", evidence: "L1_REQUIRED", producer: "none"),
            shaderContract("g_EffectTextureProjectionMatrix", type: "mat4x4", scope: "effectTexturePass", updateFrequency: "passOrTargetResize", status: "missing", evidence: "L1_REQUIRED", producer: "none", limitation: "Official contract includes texture-resolution scaling."),
            shaderContract("g_EffectTextureProjectionMatrixInverse", type: "mat4x4", scope: "effectTexturePass", updateFrequency: "passOrTargetResize", status: "missing", evidence: "L1_REQUIRED", producer: "none"),
            shaderContract("g_LayerModelMatrix", type: "mat4x4", scope: "layer", updateFrequency: "layerTransformChange", status: "implemented", evidence: "L1_REQUIRED", producer: "WPEMetalObjectUniforms.modelMatrix", limitation: "General custom vertex-shader execution is still missing."),

            shaderContract("g_AudioSpectrum16Left", type: "float[16]", scope: "frame", updateFrequency: "audioFrame", status: "implemented", evidence: "L1_REQUIRED", producer: "WPEMetalRuntimeUniforms.audioSpectrumLeft"),
            shaderContract("g_AudioSpectrum16Right", type: "float[16]", scope: "frame", updateFrequency: "audioFrame", status: "implemented", evidence: "L1_REQUIRED", producer: "WPEMetalRuntimeUniforms.audioSpectrumRight"),
            shaderContract("g_AudioSpectrum32Left", type: "float[32]", scope: "frame", updateFrequency: "audioFrame", status: "implemented", evidence: "L1_REQUIRED", producer: "WPEMetalRuntimeUniforms.audioSpectrumLeft"),
            shaderContract("g_AudioSpectrum32Right", type: "float[32]", scope: "frame", updateFrequency: "audioFrame", status: "implemented", evidence: "L1_REQUIRED", producer: "WPEMetalRuntimeUniforms.audioSpectrumRight"),
            shaderContract("g_AudioSpectrum64Left", type: "float[64]", scope: "frame", updateFrequency: "audioFrame", status: "implemented", evidence: "L1_REQUIRED", producer: "WPEMetalRuntimeUniforms.audioSpectrumLeft"),
            shaderContract("g_AudioSpectrum64Right", type: "float[64]", scope: "frame", updateFrequency: "audioFrame", status: "implemented", evidence: "L1_REQUIRED", producer: "WPEMetalRuntimeUniforms.audioSpectrumRight")
        ]

        for slot in 0...7 {
            contracts.append(shaderContract("g_Texture\(slot)Resolution", type: "vec4", scope: "textureSlot", updateFrequency: "passBinding", status: "implemented", evidence: "L1_REQUIRED", producer: "WPEMetalTextureMetadataRegistry.resolution"))
            contracts.append(shaderContract("g_Texture\(slot)Rotation", type: "vec4", scope: "spriteSheetTextureSlot", updateFrequency: "spriteFrame", status: "implemented", evidence: "L0.5", producer: "WPETexSpriteSamplingDescriptor through WPEMetalTextureSlotTable", limitation: "Cross-axis TEXS is verified by a synthetic fixture because the current Workshop corpus contains no nonzero widthY/heightX frame."))
            contracts.append(shaderContract("g_Texture\(slot)Translation", type: "vec2", scope: "spriteSheetTextureSlot", updateFrequency: "spriteFrame", status: "implemented", evidence: "L0.5", producer: "WPETexSpriteSamplingDescriptor through WPEMetalTextureSlotTable", limitation: "Missing auxiliary-slot fallback semantics remain deliberately unguessed; a descriptor is produced only for an authored TEXS binding."))
        }
        return contracts
    }

    private static let sceneScriptEventContracts: [[String: String]] = [
        ["name": "init", "status": "partial", "evidence": "L1_REQUIRED", "producer": "property-script runtimes", "limitation": "Layer visible/alpha init argument differs from the general property path."],
        ["name": "update", "status": "implemented", "evidence": "L0.5", "producer": "SceneScript tick and current-value chain", "limitation": ""],
        ["name": "destroy", "status": "implemented", "evidence": "L1_REQUIRED", "producer": "renderer teardown one-shot fence", "limitation": "GPU/media-relative teardown order still needs Windows evidence."],
        ["name": "resizeScreen", "status": "implemented", "evidence": "L1_REQUIRED", "producer": "changed drawable-size dispatch", "limitation": "DPI/multi-display timing still needs Windows evidence."],
        ["name": "applyUserProperties", "status": "partial", "evidence": "L0.5", "producer": "initial effective bag plus changed-key live patch", "limitation": "Not every property/effect/transform script domain receives the event."],
        ["name": "applyGeneralSettings", "status": "implemented", "evidence": "L0.5", "producer": "AppLanguagePreference plus renderer actor FIFO", "limitation": "The app exposes four localized UI languages; unsupported system localizations follow the app's English development fallback."],
        ["name": "cursor", "status": "partial", "evidence": "L1_REQUIRED", "producer": "renderer input dispatch", "limitation": "AABB hit test and broadcast down/up do not implement solid/z-order/capture semantics."],
        ["name": "media", "status": "implemented", "evidence": "L0.5", "producer": "WPESceneMediaEventDispatcher + MonitorNowPlayingCoordinator", "limitation": "Playback, properties, thumbnail palette, and timeline handlers are demand-gated; unsupported player fields remain empty and timeline delivery is omitted when the player exposes no position/duration."],
    ]

    private static let particleComponentContracts: [[String: String]] = [
        ["name": "general", "parseStatus": "parsedLossless", "runtimeStatus": "partial", "evidence": "L1_REQUIRED", "storage": "WPEParticleDefinition.sourceJSON", "limitation": "Worldspace, perspective, override gates, and exact pre-simulation/RNG remain incomplete."],
        ["name": "emitter", "parseStatus": "parsedLossless", "runtimeStatus": "partial", "evidence": "L1_REQUIRED", "storage": "WPEParticleRawComponentBag.emitters", "limitation": "Only the first typed emitter is executed; layer image and several scheduling modes are missing."],
        ["name": "renderer", "parseStatus": "parsedLossless", "runtimeStatus": "partial", "evidence": "L1_REQUIRED", "storage": "WPEParticleRawComponentBag.renderers", "limitation": "Authored Sprite Trail minlength is consumed; its missing/null default plus orientation/worldspace/UV/segments/smoothing/scroll remain incomplete."],
        ["name": "initializer", "parseStatus": "parsedLossless", "runtimeStatus": "partial", "evidence": "L1_REQUIRED", "storage": "WPEParticleRawComponentBag.initializers", "limitation": "CP around/between, remap, event inheritance, and exact distributions are incomplete."],
        ["name": "operator", "parseStatus": "parsedLossless", "runtimeStatus": "partial", "evidence": "L1_REQUIRED", "storage": "WPEParticleRawComponentBag.operators", "limitation": "Collision, boids, cap, remap, vortex, and event operators are missing."],
        ["name": "children", "parseStatus": "parsedLossless", "runtimeStatus": "partial", "evidence": "L1_REQUIRED", "storage": "WPEParticleRawComponentBag.children + WPEParticleChildReference", "limitation": "Scale and reference-backed legacy event-follow are consumed; maxcount, angles, CP injection, event spawn/death, and inheritance remain metadata-only or missing."],
        ["name": "controlpoint", "parseStatus": "parsedLossless", "runtimeStatus": "partial", "evidence": "L1_REQUIRED", "storage": "WPEParticleRawComponentBag.controlPoints + WPEParticleControlPoint", "limitation": "Flags and angles are typed, but only the local/pointer/injected subset is consumed; hierarchy/worldspace/copy-parent/raw semantics remain incomplete."]
    ]

    private static func pageContract(
        _ name: String,
        status: String,
        evidence: String,
        producer: String,
        limitation: String,
        sourcePath: String
    ) -> [String: String] {
        [
            "name": name,
            "status": status,
            "evidence": evidence,
            "producer": producer,
            "limitation": limitation,
            "sourcePath": sourcePath
        ]
    }

    private static let cameraContracts: [[String: String]] = [
        pageContract(
            "camera",
            status: "partial",
            evidence: "L1_REQUIRED",
            producer: "WPESceneDocumentParser.parseCamera/runtimeCameraObjectOverride + WPEMetalCameraUniforms",
            limitation: "Static center/eye/up/FOV projection and bottom-most visible authored-camera selection exist; authored camera angles, camera paths, path ordering, and path playback modes remain unimplemented.",
            sourcePath: "docs/en/scene/models/camera.md"
        )
    ]

    private static let timelineContracts: [[String: String]] = [
        pageContract(
            "animationevents",
            status: "partial",
            evidence: "L1_REQUIRED",
            producer: "WPEValueParser + WPESceneNumericAnimation.events (metadata-only)",
            limitation: "Authored event name/frame entries are typed and ordered, but no timeline or puppet frame-crossing scheduler dispatches the documented animationEvent(event, value) SceneScript callback.",
            sourcePath: "docs/en/scene/timeline/animationevents.md"
        ),
        pageContract(
            "combined",
            status: "partial",
            evidence: "L1_REQUIRED",
            producer: "WPEValueParser + WPESceneAnimatedValue",
            limitation: "Animated value envelopes and authored names are typed, but named playback identity/start state and editor-equivalent combined settings across arbitrary properties are not consumed.",
            sourcePath: "docs/en/scene/timeline/combined.md"
        ),
        pageContract(
            "introduction",
            status: "partial",
            evidence: "L1_REQUIRED",
            producer: "WPEValueParser + WPESceneNumericAnimation + renderer animated-value consumers",
            limitation: "Numeric tracks reach selected transform/effect consumers; Bezier handles, names, start-paused state, and events are typed losslessly, but Bezier interpolation, playback-state/event scheduling, frame/second parity, and complete property-domain coverage remain absent.",
            sourcePath: "docs/en/scene/timeline/introduction.md"
        ),
        pageContract(
            "modes",
            status: "partial",
            evidence: "L1_REQUIRED",
            producer: "WPESceneNumericAnimation Mirror sampler + WPEPuppetAnimationEvaluator",
            limitation: "Single/loop/mirror playback is consumed, including equal-duration forward/reverse Mirror phases, but effect/particle property-domain parity remains incomplete.",
            sourcePath: "docs/en/scene/timeline/modes.md"
        )
    ]

    private static let puppetContracts: [[String: String]] = [
        pageContract(
            "animationmixing",
            status: "partial",
            evidence: "L1_REQUIRED",
            producer: "WPESceneAnimationLayer + WPEPuppetAnimationEvaluator",
            limitation: "Base plus additive layers consume rate/blend, but the full editor mixing model and non-additive multi-animation precedence are not established.",
            sourcePath: "docs/en/scene/puppet-warp/animationmixing.md"
        ),
        pageContract(
            "attachments",
            status: "partial",
            evidence: "L1_REQUIRED",
            producer: "WPEMdlParser MDAT + WPERenderGraphBuilder attachment transforms",
            limitation: "Named child-layer attachment transforms are consumed, but attachment binding for every documented effect/particle point-property domain is not complete.",
            sourcePath: "docs/en/scene/puppet-warp/attachments.md"
        ),
        pageContract(
            "blendrules",
            status: "missing",
            evidence: "L1_REQUIRED",
            producer: "none",
            limitation: "Bone parent blend rules, multiple weighted alternate parents, and timeline-driven rule weights have no parser/runtime model.",
            sourcePath: "docs/en/scene/puppet-warp/blendrules.md"
        ),
        pageContract(
            "blendshapes",
            status: "missing",
            evidence: "L1_REQUIRED",
            producer: "none",
            limitation: "Locked-geometry blend shapes, expression composition, and animated expression weights are not parsed or rendered.",
            sourcePath: "docs/en/scene/puppet-warp/blendshapes.md"
        ),
        pageContract(
            "boneconstraints",
            status: "missing",
            evidence: "L1_REQUIRED",
            producer: "none",
            limitation: "Spring, rigid, kinematic-chain, rope, gravity/wind, inertia/friction, and limit simulation are not implemented.",
            sourcePath: "docs/en/scene/puppet-warp/boneconstraints.md"
        ),
        pageContract(
            "charactersheet",
            status: "partial",
            evidence: "L1_REQUIRED",
            producer: "WPEMdlParser character-sheet generations + WPEPuppetAnimationEvaluator",
            limitation: "Exploded bind poses can assemble and skin, but authoring geometry/weights/depth islands and later editor reassembly workflows are outside the runtime.",
            sourcePath: "docs/en/scene/puppet-warp/charactersheet.md"
        ),
        pageContract(
            "clippingmasks",
            status: "partial",
            evidence: "L1_REQUIRED",
            producer: "WPEMdlParser clipGroups + WPERenderGraphBuilder/WPEMetalRenderExecutor puppet clip passes",
            limitation: "Authored clip groups render through mask targets, but nested-mask ordering, cycle rejection, self-shadow behavior, and all animated limb cases lack full parity evidence.",
            sourcePath: "docs/en/scene/puppet-warp/clippingmasks.md"
        ),
        pageContract(
            "extending",
            status: "missing",
            evidence: "L1_REQUIRED",
            producer: "none",
            limitation: "The playback app has no editor workflow to extend/reimport a puppet texture while preserving geometry, bones, and weights.",
            sourcePath: "docs/en/scene/puppet-warp/extending.md"
        ),
        pageContract(
            "interactive",
            status: "missing",
            evidence: "L1_REQUIRED",
            producer: "none",
            limitation: "Puppet layer SceneScript does not expose getBoneIndex, getBoneTransform, or setBoneTransform, so post-animation cursor-driven bone overrides cannot run.",
            sourcePath: "docs/en/scene/puppet-warp/interactive.md"
        ),
        pageContract(
            "introduction",
            status: "partial",
            evidence: "L1_REQUIRED",
            producer: "WPEMdlParser + WPEPuppetAnimationEvaluator + Metal puppet skinning",
            limitation: "Mesh topology, bones, skin weights, and keyframed deformation are played back, but the documented editor geometry/skeleton/weight authoring process is not reproduced.",
            sourcePath: "docs/en/scene/puppet-warp/introduction.md"
        ),
        pageContract(
            "inversekinematics",
            status: "missing",
            evidence: "L1_REQUIRED",
            producer: "none",
            limitation: "IK terminal bones, target/orientation controllers, forward positions, and joint limits have no runtime solver.",
            sourcePath: "docs/en/scene/puppet-warp/inversekinematics.md"
        ),
        pageContract(
            "perspective",
            status: "missing",
            evidence: "L1_REQUIRED",
            producer: "none",
            limitation: "Puppet depth-map extrusion, X/Y bone-angle perspective deformation, and its culling rules are not implemented.",
            sourcePath: "docs/en/scene/puppet-warp/perspective.md"
        ),
        pageContract(
            "texturechannels",
            status: "missing",
            evidence: "L1_REQUIRED",
            producer: "none",
            limitation: "Additional same-resolution texture channels, alpha writing, changed-region storage, and timeline channel-opacity blending are not modeled.",
            sourcePath: "docs/en/scene/puppet-warp/texturechannels.md"
        )
    ]

    private static let webContracts: [[String: String]] = [
        pageContract(
            "api/icue",
            status: "missing",
            evidence: "L1_REQUIRED",
            producer: "none",
            limitation: "window.cue protocol/device/LED enumeration and write APIs are not injected into WKWebView.",
            sourcePath: "docs/en/web/api/icue.md"
        ),
        pageContract(
            "api/propertylistener",
            status: "partial",
            evidence: "L1_REQUIRED",
            producer: "WallpaperEngineWebPropertyBridge + HTMLWallpaperRuntimeScript lifecycle/general-properties bridge",
            limitation: "applyUserProperties, applyGeneralProperties({fps}), and setPaused are delivered, but fetchall directory added/changed/removed callbacks are absent.",
            sourcePath: "docs/en/web/api/propertylistener.md"
        ),
        pageContract(
            "api/rgb",
            status: "missing",
            evidence: "L1_REQUIRED",
            producer: "none",
            limitation: "window.wallpaperPluginListener and window.wpPlugins.led.setAllDevicesByImageData are not provided.",
            sourcePath: "docs/en/web/api/rgb.md"
        ),
        pageContract(
            "audio/media",
            status: "missing",
            evidence: "L1_REQUIRED",
            producer: "none",
            limitation: "There is no platform now-playing bridge for media status, properties, thumbnail, playback, or timeline listener registration APIs.",
            sourcePath: "docs/en/web/audio/media.md"
        ),
        pageContract(
            "audio/visualizer",
            status: "missing",
            evidence: "L1_REQUIRED",
            producer: "none",
            limitation: "window.wallpaperRegisterAudioListener and its 128-value approximately-30-Hz audio array are not exposed to web wallpapers.",
            sourcePath: "docs/en/web/audio/visualizer.md"
        ),
        pageContract(
            "customization/displaycondition",
            status: "partial",
            evidence: "L1_REQUIRED",
            producer: "WallpaperEngineProjectPropertySchema.ConditionEvaluator + ProjectPresentation",
            limitation: "Inspector visibility conditions are evaluated for the supported expression subset, but complete Wallpaper Engine condition grammar/editor behavior is not established.",
            sourcePath: "docs/en/web/customization/displaycondition.md"
        ),
        pageContract(
            "customization/localization",
            status: "partial",
            evidence: "L1_REQUIRED",
            producer: "WallpaperEngineProjectPropertySchema.Localization",
            limitation: "Localized property labels/options are selected from project.json, but parity with Wallpaper Engine's full locale-code inventory and fallback order is not proven.",
            sourcePath: "docs/en/web/customization/localization.md"
        ),
        pageContract(
            "customization/properties",
            status: "partial",
            evidence: "L1_REQUIRED",
            producer: "WallpaperEngineProjectPropertySchema + WallpaperEngineWebPropertyBridge",
            limitation: "Core value types and changed-key callbacks are supported; file access is project-sandboxed and ondemand/fetchall directory request/event APIs are not implemented.",
            sourcePath: "docs/en/web/customization/properties.md"
        ),
        pageContract(
            "debug/debug",
            status: "missing",
            evidence: "L1_REQUIRED",
            producer: "none",
            limitation: "The documented CEF remote-debugging port workflow is not available in the WKWebView host.",
            sourcePath: "docs/en/web/debug/debug.md"
        ),
        pageContract(
            "first/gettingstarted",
            status: "partial",
            evidence: "L1_REQUIRED",
            producer: "HTMLWallpaperView + FolderURLSchemeHandler",
            limitation: "Local bundled HTML projects can play offline, but Wallpaper Engine's editor import/copy flow and project.json authoring workflow are not reproduced.",
            sourcePath: "docs/en/web/first/gettingstarted.md"
        ),
        pageContract(
            "overview",
            status: "partial",
            evidence: "L1_REQUIRED",
            producer: "HTMLWallpaperView WKWebView host",
            limitation: "HTML/CSS/JavaScript wallpapers run, but several Wallpaper Engine-specific customization, audio/media, RGB, directory, debugging, and codec contracts remain absent.",
            sourcePath: "docs/en/web/overview.md"
        ),
        pageContract(
            "performance/fps",
            status: "partial",
            evidence: "L1_REQUIRED",
            producer: "HTMLFramePacingPolicy + HTMLWallpaperRuntimeScript.wallpaperEngineGeneralProperties",
            limitation: "The host delivers fps and gates requestAnimationFrame, but exact callback timing and page-authored limiter behavior still need Wallpaper Engine capture parity.",
            sourcePath: "docs/en/web/performance/fps.md"
        )
    ]

    private static var configURL: URL? {
        if let path = ProcessInfo.processInfo.environment["WPE_DOC_CORPUS_AUDIT_CONFIG"],
           !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let temporaryURL = URL(fileURLWithPath: "/private/tmp/livewallpaper-wpe-doc-corpus-audit.json")
        return FileManager.default.fileExists(atPath: temporaryURL.path) ? temporaryURL : nil
    }

    @Test(
        "Inventory real Workshop JSON keys, hierarchy, package entries, and parser diagnostics",
        .enabled(if: configURL != nil)
    )
    func inventoryCorpus() throws {
        let configURL = try #require(Self.configURL)
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))
        let root = URL(fileURLWithPath: config.corpusRoot, isDirectory: true)
        let output = URL(fileURLWithPath: config.output)
        let folders = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var projectCount = 0
        var sceneCount = 0
        var packageCount = 0
        var packageJSONCount = 0
        var packageEntryExtensions: [String: Int] = [:]
        var projectKeyPaths: [String: Int] = [:]
        var sceneKeyPaths: [String: Int] = [:]
        var parserSourceKeyPaths: [String: Int] = [:]
        var packageJSONKeyPaths: [String: Int] = [:]
        var packageJSONPathFamilies: [String: Int] = [:]
        var packageJSONBasenames: [String: Int] = [:]
        var packageJSONDocumentKinds: [String: Int] = [:]
        var packageJSONRootSignatures: [String: Int] = [:]
        var particleDefinitionDocuments = 0
        var particleMultiEmitterDocuments = 0
        var particleJSONKeyPaths: [String: Int] = [:]
        var particleParserSourceJSONKeyPaths: [String: Int] = [:]
        var particleSourcePreservationMismatches: [String] = []
        var objectTypes: [String: Int] = [:]
        var propertyTypes: [String: Int] = [:]
        var directoryModes: [String: Int] = [:]
        var diagnostics: [String: Int] = [:]
        var parseFailures: [String] = []
        var sourcePreservationMismatches: [String] = []
        var hierarchyEdges = 0
        var hierarchyUnresolvedParents = 0
        var hierarchyCycles = 0
        var maximumHierarchyDepth = 0

        for folder in folders {
            let workshopID = folder.lastPathComponent
            let projectURL = folder.appendingPathComponent("project.json")
            guard let projectData = try? Data(contentsOf: projectURL),
                  let projectRoot = try? JSONSerialization.jsonObject(with: projectData) as? [String: Any] else {
                parseFailures.append("\(workshopID):project.json")
                continue
            }
            projectCount += 1
            Self.recordJSONShape(projectRoot, into: &projectKeyPaths)
            Self.recordProjectProperties(
                projectRoot,
                propertyTypes: &propertyTypes,
                directoryModes: &directoryModes
            )

            guard (projectRoot["type"] as? String)?.lowercased() == "scene" else { continue }
            sceneCount += 1
            let entryFile = (projectRoot["file"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedEntry = (entryFile?.isEmpty == false ? entryFile : nil) ?? "scene.json"
            let packageURL = folder.appendingPathComponent("scene.pkg")

            let sceneData: Data?
            if FileManager.default.fileExists(atPath: packageURL.path) {
                do {
                    let handle = try FileHandle(forReadingFrom: packageURL)
                    defer { try? handle.close() }
                    let package = try WallpaperEnginePackage.parseIndex(streamingFrom: handle)
                    packageCount += 1
                    for entry in package.entries {
                        let ext = (entry.name as NSString).pathExtension.lowercased()
                        packageEntryExtensions[ext.isEmpty ? "<none>" : ext, default: 0] += 1
                        guard ext == "json", entry.dataSize <= 32 * 1_024 * 1_024 else { continue }
                        if let data = try Self.read(entry: entry, package: package, handle: handle),
                           let json = try? JSONSerialization.jsonObject(with: data) {
                            packageJSONCount += 1
                            Self.recordJSONShape(json, into: &packageJSONKeyPaths)
                            let canonicalEntryName = entry.name.replacingOccurrences(of: "\\", with: "/")
                            let pathFamily = canonicalEntryName.split(separator: "/").first
                                .map { String($0).lowercased() } ?? "<root>"
                            packageJSONPathFamilies[pathFamily, default: 0] += 1
                            packageJSONBasenames[
                                (canonicalEntryName as NSString).lastPathComponent.lowercased(),
                                default: 0
                            ] += 1
                            if let root = json as? [String: Any] {
                                packageJSONDocumentKinds[
                                    Self.packageJSONDocumentKind(entryName: canonicalEntryName, root: root),
                                    default: 0
                                ] += 1
                                let signature = root.keys.sorted().joined(separator: "|")
                                packageJSONRootSignatures[signature.isEmpty ? "<empty>" : signature, default: 0] += 1
                            }
                            if let particleRoot = json as? [String: Any],
                               Self.isParticleDefinition(particleRoot) {
                                particleDefinitionDocuments += 1
                                var rawParticleKeyPaths: [String: Int] = [:]
                                Self.recordJSONShape(particleRoot, into: &rawParticleKeyPaths)
                                Self.merge(rawParticleKeyPaths, into: &particleJSONKeyPaths)

                                var particleDiagnostics: [WPESceneDiagnostic] = []
                                let definition = WPEParticleDefinitionParser.parse(
                                    dictionary: particleRoot,
                                    diagnostics: &particleDiagnostics
                                )
                                var preservedParticleKeyPaths: [String: Int] = [:]
                                Self.recordJSONShape(
                                    definition.sourceJSON,
                                    into: &preservedParticleKeyPaths
                                )
                                Self.merge(
                                    preservedParticleKeyPaths,
                                    into: &particleParserSourceJSONKeyPaths
                                )
                                if definition.rawComponents.emitters.count > 1 {
                                    particleMultiEmitterDocuments += 1
                                }
                                if preservedParticleKeyPaths != rawParticleKeyPaths {
                                    particleSourcePreservationMismatches.append(
                                        "\(workshopID):\(entry.name)"
                                    )
                                }
                            }
                        }
                    }
                    sceneData = try Self.read(
                        named: requestedEntry,
                        package: package,
                        handle: handle
                    )
                } catch {
                    parseFailures.append("\(workshopID):package:\(type(of: error))")
                    continue
                }
            } else {
                sceneData = try? Data(contentsOf: folder.appendingPathComponent(requestedEntry))
            }

            guard let sceneData,
                  let rawScene = try? JSONSerialization.jsonObject(with: sceneData) as? [String: Any] else {
                parseFailures.append("\(workshopID):\(requestedEntry)")
                continue
            }
            var rawSceneKeyPaths: [String: Int] = [:]
            Self.recordJSONShape(rawScene, into: &rawSceneKeyPaths)
            Self.merge(rawSceneKeyPaths, into: &sceneKeyPaths)
            let hierarchy = Self.recordSceneObjects(rawScene, objectTypes: &objectTypes)
            hierarchyEdges += hierarchy.edges
            hierarchyUnresolvedParents += hierarchy.unresolved
            hierarchyCycles += hierarchy.cycles
            maximumHierarchyDepth = max(maximumHierarchyDepth, hierarchy.maximumDepth)

            do {
                let document = try WPESceneDocumentParser.parse(data: sceneData)
                var preservedKeyPaths: [String: Int] = [:]
                Self.recordJSONShape(document.sourceJSON, into: &preservedKeyPaths)
                Self.merge(preservedKeyPaths, into: &parserSourceKeyPaths)
                if preservedKeyPaths != rawSceneKeyPaths {
                    sourcePreservationMismatches.append(workshopID)
                }
                for diagnostic in document.diagnostics {
                    let key = "\(diagnostic.severity):\(Self.normalizedDiagnostic(diagnostic.message))"
                    diagnostics[key, default: 0] += 1
                }
            } catch {
                parseFailures.append("\(workshopID):scene-parser:\(type(of: error))")
            }
        }

        let result: [String: Any] = [
            "schema": "wpe.official-doc-corpus-audit.v3",
            "officialContracts": [
                "source": [
                    "documentationCommit": Self.officialDocumentationCommit,
                    "englishPagesAudited": 192,
                    "shaderVariablesPage": "docs/en/scene/shader/variables.md",
                    "sceneScriptEventDirectory": "docs/en/scene/scenescript/reference/event",
                    "particleComponentDirectory": "docs/en/scene/particles/component",
                    "cameraPage": "docs/en/scene/models/camera.md",
                    "timelineDirectory": "docs/en/scene/timeline",
                    "puppetDirectory": "docs/en/scene/puppet-warp",
                    "webDirectory": "docs/en/web"
                ] as [String: Any],
                "shaderGlobals": Self.shaderGlobalContracts,
                "sceneScriptEvents": Self.sceneScriptEventContracts,
                "particleComponents": Self.particleComponentContracts,
                "camera": Self.cameraContracts,
                "timeline": Self.timelineContracts,
                "puppet": Self.puppetContracts,
                "web": Self.webContracts
            ] as [String: Any],
            "corpus": [
                "directories": folders.count,
                "projects": projectCount,
                "scenes": sceneCount,
                "packages": packageCount,
                "packageJSONDocuments": packageJSONCount
            ],
            "hierarchy": [
                "edges": hierarchyEdges,
                "unresolvedParents": hierarchyUnresolvedParents,
                "cycles": hierarchyCycles,
                "maximumDepth": maximumHierarchyDepth
            ],
            "objectTypes": objectTypes,
            "propertyTypes": propertyTypes,
            "directoryModes": directoryModes,
            "packageEntryExtensions": packageEntryExtensions,
            "projectJSONKeyPaths": projectKeyPaths,
            "sceneJSONKeyPaths": sceneKeyPaths,
            "parserSourceJSONKeyPaths": parserSourceKeyPaths,
            "packageJSONKeyPaths": packageJSONKeyPaths,
            "packageJSONPathFamilies": packageJSONPathFamilies,
            "packageJSONBasenames": packageJSONBasenames,
            "packageJSONDocumentKinds": packageJSONDocumentKinds,
            "packageJSONRootSignatures": packageJSONRootSignatures,
            "particleDefinitions": [
                "documents": particleDefinitionDocuments,
                "multiEmitterDocuments": particleMultiEmitterDocuments,
                "sourceJSONKeyPaths": particleJSONKeyPaths,
                "parserSourceJSONKeyPaths": particleParserSourceJSONKeyPaths,
                "sourcePreservationMismatches": particleSourcePreservationMismatches
            ],
            "parserDiagnostics": diagnostics,
            "parseFailures": parseFailures,
            "sourcePreservationMismatches": sourcePreservationMismatches
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output, options: .atomic)

        #expect(projectCount > 0)
        #expect(sceneCount > 0)
        #expect(packageCount > 0)
        #expect(packageJSONCount > 0)
        #expect(
            packageJSONDocumentKinds.values.reduce(0, +) == packageJSONCount,
            "Every package JSON root must receive a structural document kind"
        )
        #expect(
            packageJSONPathFamilies.values.reduce(0, +) == packageJSONCount,
            "Every package JSON must receive exactly one path family"
        )
        #expect(
            packageJSONRootSignatures.values.reduce(0, +) == packageJSONCount,
            "Every package JSON root must receive a key signature"
        )
        #expect(parseFailures.isEmpty, "Corpus audit parse failures: \(parseFailures)")
        #expect(
            sourcePreservationMismatches.isEmpty,
            "Shipping parser dropped authored JSON paths: \(sourcePreservationMismatches)"
        )
        #expect(particleDefinitionDocuments > 0)
        #expect(
            particleSourcePreservationMismatches.isEmpty,
            "Particle parser dropped authored JSON paths: \(particleSourcePreservationMismatches)"
        )
    }

    @Test("Official contract manifest covers every documented shader global, SceneScript event, particle domain, and selected page group")
    func officialContractManifestCoverage() {
        let shaderContracts = Self.shaderGlobalContracts
        let shaderNames = shaderContracts.compactMap { $0["name"] }
        #expect(shaderContracts.count == 60)
        #expect(Set(shaderNames).count == shaderContracts.count, "Shader contract names must be unique")
        #expect(shaderContracts.allSatisfy { Self.allowedContractStatuses.contains($0["status"] ?? "") })
        #expect(shaderContracts.allSatisfy { Self.allowedEvidenceLevels.contains($0["evidence"] ?? "") })
        #expect(shaderContracts.allSatisfy {
            !($0["type"] ?? "").isEmpty
                && !($0["scope"] ?? "").isEmpty
                && !($0["updateFrequency"] ?? "").isEmpty
                && !($0["producer"] ?? "").isEmpty
        })

        let expectedTextureNames = Set((0...7).flatMap { slot in
            [
                "g_Texture\(slot)Resolution",
                "g_Texture\(slot)Rotation",
                "g_Texture\(slot)Translation"
            ]
        })
        let expectedNonTextureNames = Set([
            "g_Time", "g_Daytime", "g_Frametime", "g_PointerPosition", "g_PointerPositionLast",
            "g_TexelSize", "g_TexelSizeHalf", "g_Screen", "g_Alpha", "g_Color", "g_Color4",
            "g_ParallaxPosition", "g_EyePosition", "g_ViewForward", "g_ViewRight", "g_ViewUp",
            "g_OrientationForward", "g_OrientationRight", "g_OrientationUp", "g_ModelMatrix",
            "g_ModelMatrixInverse", "g_ViewProjectionMatrix", "g_ModelViewProjectionMatrix",
            "g_ModelViewProjectionMatrixInverse", "g_EffectModelMatrix",
            "g_EffectModelViewProjectionMatrix", "g_EffectModelViewProjectionMatrixInverse",
            "g_EffectTextureProjectionMatrix", "g_EffectTextureProjectionMatrixInverse", "g_LayerModelMatrix",
            "g_AudioSpectrum16Left", "g_AudioSpectrum16Right", "g_AudioSpectrum32Left",
            "g_AudioSpectrum32Right", "g_AudioSpectrum64Left", "g_AudioSpectrum64Right"
        ])
        #expect(Set(shaderNames) == expectedNonTextureNames.union(expectedTextureNames))

        let expectedEventNames = Set([
            "applyGeneralSettings", "applyUserProperties", "cursor", "destroy",
            "init", "media", "resizeScreen", "update"
        ])
        let eventNames = Self.sceneScriptEventContracts.compactMap { $0["name"] }
        #expect(Set(eventNames) == expectedEventNames)
        #expect(Set(eventNames).count == Self.sceneScriptEventContracts.count)
        #expect(Self.sceneScriptEventContracts.allSatisfy {
            Self.allowedContractStatuses.contains($0["status"] ?? "")
                && Self.allowedEvidenceLevels.contains($0["evidence"] ?? "")
                && !($0["producer"] ?? "").isEmpty
        })

        let expectedParticleDomains = Set([
            "general", "emitter", "renderer", "initializer", "operator", "children", "controlpoint"
        ])
        let particleNames = Self.particleComponentContracts.compactMap { $0["name"] }
        #expect(Set(particleNames) == expectedParticleDomains)
        #expect(Set(particleNames).count == Self.particleComponentContracts.count)
        #expect(Self.particleComponentContracts.allSatisfy {
            $0["parseStatus"] == "parsedLossless"
                && Self.allowedContractStatuses.contains($0["runtimeStatus"] ?? "")
                && Self.allowedEvidenceLevels.contains($0["evidence"] ?? "")
                && !($0["storage"] ?? "").isEmpty
        })

        let expectedPageGroups: [(contracts: [[String: String]], pathsByName: [String: String])] = [
            (
                Self.cameraContracts,
                ["camera": "docs/en/scene/models/camera.md"]
            ),
            (
                Self.timelineContracts,
                Dictionary(uniqueKeysWithValues: [
                    "animationevents", "combined", "introduction", "modes"
                ].map { ($0, "docs/en/scene/timeline/\($0).md") })
            ),
            (
                Self.puppetContracts,
                Dictionary(uniqueKeysWithValues: [
                    "animationmixing", "attachments", "blendrules", "blendshapes", "boneconstraints",
                    "charactersheet", "clippingmasks", "extending", "interactive", "introduction",
                    "inversekinematics", "perspective", "texturechannels"
                ].map { ($0, "docs/en/scene/puppet-warp/\($0).md") })
            ),
            (
                Self.webContracts,
                Dictionary(uniqueKeysWithValues: [
                    "api/icue", "api/propertylistener", "api/rgb", "audio/media", "audio/visualizer",
                    "customization/displaycondition", "customization/localization", "customization/properties",
                    "debug/debug", "first/gettingstarted", "overview", "performance/fps"
                ].map { ($0, "docs/en/web/\($0).md") })
            )
        ]
        for pageGroup in expectedPageGroups {
            let names = pageGroup.contracts.compactMap { $0["name"] }
            #expect(!pageGroup.contracts.isEmpty, "Every selected official page group must be nonempty")
            #expect(Set(names) == Set(pageGroup.pathsByName.keys), "Official page group must be an exact set")
            #expect(Set(names).count == pageGroup.contracts.count, "Official page contract names must be unique within their group")
            #expect(pageGroup.contracts.allSatisfy { contract in
                ["name", "status", "evidence", "producer", "limitation", "sourcePath"].allSatisfy {
                    !(contract[$0] ?? "").isEmpty
                }
            }, "Every official page contract field must be nonempty")
            #expect(pageGroup.contracts.allSatisfy {
                Self.allowedContractStatuses.contains($0["status"] ?? "")
                    && Self.allowedEvidenceLevels.contains($0["evidence"] ?? "")
            })
            #expect(pageGroup.contracts.allSatisfy {
                pageGroup.pathsByName[$0["name"] ?? ""] == $0["sourcePath"]
            }, "Every official page contract must retain its exact source path")
        }
    }

    private static func read(
        named name: String,
        package: WallpaperEnginePackage,
        handle: FileHandle
    ) throws -> Data? {
        guard let entry = package.nameIndex[name.lowercased()] else { return nil }
        return try read(entry: entry, package: package, handle: handle)
    }

    private static func read(
        entry: WallpaperEnginePackage.Entry,
        package: WallpaperEnginePackage,
        handle: FileHandle
    ) throws -> Data? {
        guard entry.dataSize <= UInt64(Int.max) else { return nil }
        try handle.seek(toOffset: package.dataStart + entry.dataOffset)
        guard let data = try handle.read(upToCount: Int(entry.dataSize)),
              data.count == Int(entry.dataSize) else { return nil }
        return data
    }

    private static func recordJSONShape(
        _ value: Any,
        path: String = "",
        into counts: inout [String: Int]
    ) {
        if let object = value as? [String: Any] {
            for key in object.keys.sorted() {
                let next = path.isEmpty ? key : "\(path).\(key)"
                counts[next, default: 0] += 1
                recordJSONShape(object[key] as Any, path: next, into: &counts)
            }
        } else if let array = value as? [Any] {
            let next = "\(path)[]"
            counts[next, default: 0] += 1
            for element in array {
                recordJSONShape(element, path: next, into: &counts)
            }
        }
    }

    private static func isParticleDefinition(_ root: [String: Any]) -> Bool {
        let componentKeys = WPEParticleComponentArrayKind.allCases.map(\.rawValue)
        let hasComponentArray = componentKeys.contains { root[$0] is [Any] }
        return hasComponentArray && (root["material"] != nil || root["maxcount"] != nil)
    }

    private static func packageJSONDocumentKind(
        entryName: String,
        root: [String: Any]
    ) -> String {
        if isParticleDefinition(root) { return "particleDefinition" }
        if root["objects"] is [Any] { return "sceneDocument" }
        if let passes = root["passes"] as? [[String: Any]] {
            if passes.contains(where: { $0["shader"] != nil }) { return "material" }
            if root["fbos"] != nil || passes.contains(where: {
                $0["material"] != nil || $0["command"] != nil
            }) {
                return "effect"
            }
            return "unclassifiedPassDocument"
        }
        if root["material"] != nil { return "modelDescriptor" }
        let family = entryName.split(separator: "/").first
            .map { String($0).lowercased() } ?? "<root>"
        return "other:\(family)"
    }

    private static func recordJSONShape(
        _ value: WPESceneJSONValue,
        path: String = "",
        into counts: inout [String: Int]
    ) {
        switch value {
        case .object(let object):
            for key in object.keys.sorted() {
                let next = path.isEmpty ? key : "\(path).\(key)"
                counts[next, default: 0] += 1
                if let child = object[key] {
                    recordJSONShape(child, path: next, into: &counts)
                }
            }
        case .array(let values):
            let next = "\(path)[]"
            counts[next, default: 0] += 1
            for child in values {
                recordJSONShape(child, path: next, into: &counts)
            }
        case .string, .number, .bool, .null:
            break
        }
    }

    private static func merge(
        _ additions: [String: Int],
        into counts: inout [String: Int]
    ) {
        for (key, count) in additions {
            counts[key, default: 0] += count
        }
    }

    private static func recordProjectProperties(
        _ root: [String: Any],
        propertyTypes: inout [String: Int],
        directoryModes: inout [String: Int]
    ) {
        guard let general = root["general"] as? [String: Any],
              let properties = general["properties"] as? [String: Any] else { return }
        for raw in properties.values {
            guard let property = raw as? [String: Any] else { continue }
            let type = (property["type"] as? String)?.lowercased() ?? "<missing>"
            propertyTypes[type, default: 0] += 1
            if type == "directory" {
                let mode = (property["mode"] as? String)?.lowercased() ?? "<missing>"
                directoryModes[mode, default: 0] += 1
            }
        }
    }

    private static func recordSceneObjects(
        _ root: [String: Any],
        objectTypes: inout [String: Int]
    ) -> (edges: Int, unresolved: Int, cycles: Int, maximumDepth: Int) {
        guard let objects = root["objects"] as? [[String: Any]] else { return (0, 0, 0, 0) }
        var parentByID: [String: String] = [:]
        var ids = Set<String>()
        for object in objects {
            let type = (object["type"] as? String)?.lowercased() ?? Self.inferredObjectType(object)
            objectTypes[type, default: 0] += 1
            guard let id = Self.flexibleString(object["id"]) else { continue }
            ids.insert(id)
            if let parent = Self.flexibleString(object["parent"]) { parentByID[id] = parent }
        }
        var unresolved = 0
        var cycles = 0
        var maximumDepth = 0
        for id in ids {
            var cursor = id
            var visited = Set<String>()
            var depth = 0
            while let parent = parentByID[cursor] {
                if !ids.contains(parent) { unresolved += 1; break }
                if !visited.insert(parent).inserted { cycles += 1; break }
                depth += 1
                cursor = parent
            }
            maximumDepth = max(maximumDepth, depth)
        }
        return (parentByID.count, unresolved, cycles, maximumDepth)
    }

    private static func inferredObjectType(_ object: [String: Any]) -> String {
        for candidate in ["image", "particle", "text", "sound", "light"] where object[candidate] != nil {
            return candidate
        }
        return "<unknown>"
    }

    private static func flexibleString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func normalizedDiagnostic(_ message: String) -> String {
        message.replacingOccurrences(of: #"\b[0-9]{2,}\b"#, with: "<n>", options: .regularExpression)
    }
}
#endif
