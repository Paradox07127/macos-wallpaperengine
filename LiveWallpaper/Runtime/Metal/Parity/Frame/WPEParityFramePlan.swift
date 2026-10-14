#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// Why a draw operation of the frame is not encoded.
enum WPEParityFrameSkip: Error, Hashable, Sendable, CustomStringConvertible {
    case modelMesh
    case noMaterial
    case program(String)
    case noShader(String)
    case pipeline(String)
    case texture(String)
    /// The `.tex` holds a video stream this renderer does not play: no TEXI flag 0x20, or no payload behind it.
    case videoTexture(String)

    var category: String {
        switch self {
        case .modelMesh: "model mesh"
        case .noMaterial: "no material file"
        case .program: "program unresolved"
        case .noShader: "no compiled shader"
        case .pipeline: "pipeline failed"
        case .texture: "texture unresolved"
        case .videoTexture: "video texture"
        }
    }

    var description: String {
        switch self {
        case .modelMesh, .noMaterial: category
        case let .program(detail), let .noShader(detail), let .pipeline(detail), let .texture(detail),
             let .videoTexture(detail):
            "\(category): \(detail)"
        }
    }
}

/// The frames of one set of enabled effects, with the WPE program and binding of each draw.
struct WPEParityFrameLayout {
    /// Frame `n` uses `frames[n % frames.count]`; a second entry exists only when FBO swap pairs alternate.
    let frames: [WPEParityFrame]
    /// Keyed by draw operation index; a draw without a program is in `skipped`.
    let programs: [Int: WPEParityProgram]
    /// One table per entry of `frames`, keyed like `programs`.
    let bindings: [[Int: WPEParityProgramBinding]]
    let skipped: [Int: WPEParityFrameSkip]
}

/// What fixes a draw's program: a scene draw's material, or a post-process draw's material file and shader. Effect
/// sets change which draws a frame has, never the program of one (R24 Q3).
enum WPEParityProgramKey: Hashable {
    case scene(objectID: String, effectID: String?, source: WPEParitySceneMaterialSource?)
    case post(material: String, shader: String)

    init(_ draw: WPEParityFrameDraw) {
        switch draw {
        case let .scene(draw): self = .scene(objectID: draw.objectID, effectID: draw.effectID, source: draw.source)
        case let .post(draw): self = .post(material: draw.material, shader: draw.shader)
        }
    }
}

/// A scene document turned into its parity frame and the WPE program of each draw; holds no Metal objects.
struct WPEParityFramePlan {
    let document: WPESceneDocument
    let scene: WPEParityProgramScene
    /// The frames of the effects the document enables.
    let layout: WPEParityFrameLayout
    /// Unscaled client extent used by the camera, scripts and layer geometry.
    let width: Int
    let height: Int
    let physicalBackbufferSize: SIMD2<Int>
    private let pixelScale: Double
    private let physicalCanvasSize: @Sendable (SIMD2<Int>) -> SIMD2<Int>
    /// The user alignment the camera crops the canvas with (R8 Q1).
    let alignment: WPEParityCameraAlignment
    /// Object and material state as loaded, hidden objects included.
    let state: WPEParitySceneState
    let materialConstants: [WPEParityScriptEngine.ConstantKey: WPEParityScriptEngine.MaterialConstant]
    let post: WPEParityPostProcessConfig
    var requiredPresentationPass: String? {
        post.hdrEnabled ? (post.bloomEnabled ? "combine_hdr" : "combine_srgb") : nil
    }

    /// Both HDR combine paths write linear RGB; ccsimple and fade preserve that domain.
    var colorTransfer: WPEPresentColorTransfer {
        post.hdrEnabled ? .linear : .authored
    }

    /// The program of every draw any effect set has, disabled effects included, as WPE loads them (R24 Q3).
    let programCache: [WPEParityProgramKey: Result<WPEParityProgram, WPEParityFrameSkip>]
    let particleMaterials: [WPEParityParticleMaterialProbe]

    var frames: [WPEParityFrame] {
        layout.frames
    }

    var programs: [Int: WPEParityProgram] {
        layout.programs
    }

    var bindings: [[Int: WPEParityProgramBinding]] {
        layout.bindings
    }

    var skipped: [Int: WPEParityFrameSkip] {
        layout.skipped
    }

    /// Every program `programCache` resolved, each once.
    var loadPrograms: [WPEParityProgram] {
        var seen: Set<WPEHLSLProgram> = []
        let materialPrograms = particleMaterials.compactMap { probe -> WPEParityProgram? in
            if case let .ready(program, _) = probe.material {
                return program
            }
            return nil
        }
        let programs = programCache.values.compactMap { result -> WPEParityProgram? in
            guard case let .success(program) = result else { return nil }
            return program
        }
        return (programs + materialPrograms).filter { seen.insert($0.hlsl).inserted }
    }

    init(document: WPESceneDocument, assets: WPEParityProgramAssets, settings: WPEParityProgramSettings,
         width: Int, height: Int, alignment: WPEParityCameraAlignment = .noCrop,
         physicalBackbufferSize: SIMD2<Int>? = nil, pixelScale: Double = 1) throws {
        let physicalBackbufferSize = physicalBackbufferSize ?? SIMD2(width, height)
        let physicalCanvasSize: @Sendable (SIMD2<Int>) -> SIMD2<Int> = { size in
            guard pixelScale != 1 else { return size }
            let scaled = WPEMetalFXSpatialUpscaler.scaledCanvasSize(
                CGSize(width: size.x, height: size.y), pixelScale: pixelScale, minimumEdge: 1
            )
            return SIMD2(Int(scaled.width), Int(scaled.height))
        }
        let scene = WPEParityProgramScene(document: document, assets: assets, settings: settings)
        particleMaterials = WPEParityParticleScene.materialProbes(document: document, assets: assets,
                                                                  engineFlags: scene.engineFlags)
        var post = scene.postProcess
        (post.backbufferWidth, post.backbufferHeight) = (physicalBackbufferSize.x, physicalBackbufferSize.y)
        var cache: [WPEParityProgramKey: Result<WPEParityProgram, WPEParityFrameSkip>] = [:]
        layout = try Self.layout(Self.loaded(scene.scene(logicalViewport: SIMD2(width, height))), post: post, scene: scene,
                                 physicalBackbufferSize: physicalBackbufferSize,
                                 physicalCanvasSize: physicalCanvasSize, pixelScale: pixelScale,
                                 cache: &cache)
        var constantBindings = layout.bindings.flatMap(\.values)
        // Every effect on, then every effect off, draws each material any effect set does.
        for enabled in [true, false] {
            let frame = try WPEParityFrameComposer.compose(
                scene: Self.loaded(scene.scene(effectVisible: { _, _ in enabled },
                                               logicalViewport: SIMD2(width, height))),
                post: post,
                frameIndex: 0, physicalBackbufferSize: physicalBackbufferSize,
                physicalCanvasSize: physicalCanvasSize, pixelScale: pixelScale
            )
            _ = Self.programs(frame, scene: scene, cache: &cache)
            constantBindings += WPEParityProgramBuilder.bindings(frame: frame, scene: scene).values
        }

        // Empty text and later colour/depth/background changes still use programs compiled once at load.
        for object in scene.scene.objects {
            guard case .text = object.kind else { continue }
            for depth in [false, true] {
                let variants: [(WPEParitySceneMaterialSource, WPEParitySceneDraw.Geometry)] = [
                    (.textGlyphs(.mono, depth: depth), .textGlyphs(.mono)),
                    (.textGlyphs(.color, depth: depth), .textGlyphs(.color)),
                    (.textBackground(depth: depth), .textBackground),
                ]
                for (source, geometry) in variants {
                    let draw = WPEParityFrameDraw.scene(WPEParitySceneDraw(
                        pass: WPEPassIdentity("\(object.id)/text-prewarm"), objectID: object.id,
                        shader: geometry == .textBackground ? "flat" : "font", source: source, reads: [],
                        target: WPEParitySceneResource.backbuffer, blend: .translucent, writeMask: .rgba,
                        geometry: geometry, depthTest: depth
                    ))
                    guard let description = WPEParityProgramBuilder.description(of: draw, scene: scene) else { continue }
                    do {
                        cache[WPEParityProgramKey(draw)] = try .success(
                            WPEParityProgramResolver.resolve(description, sources: scene.assets)
                        )
                    } catch {
                        cache[WPEParityProgramKey(draw)] = .failure(.program("\(description.material.shader): \(error)"))
                    }
                }
            }
        }
        var metadata: [WPEParityScriptEngine.ConstantKey: WPEParityScriptEngine.MaterialConstant] = [:]
        var loadedState = WPEParitySceneState(scene: scene, document: document)
        for binding in constantBindings {
            guard let pass = binding.materialPass else { continue }
            for (stage, constants) in binding.materialConstants {
                for uniform in constants {
                    var vector = SIMD4<Float>.zero
                    switch binding.constants[stage]?[uniform.name] {
                    case let .float(value)?: vector.x = value
                    case let .vector(values)?:
                        for lane in 0 ..< min(4, values.count) {
                            vector[lane] = values[lane]
                        }
                    default: continue
                    }
                    metadata[.init(pass: pass, name: uniform.material)] = .init(
                        value: vector, components: uniform.components, angle: uniform.angle
                    )
                    loadedState.seedConstant(uniform.material, of: pass,
                                             value: .init(value: vector, count: uniform.components))
                }
            }
        }
        materialConstants = metadata

        self.document = document
        self.scene = scene
        self.width = width
        self.height = height
        self.physicalBackbufferSize = physicalBackbufferSize
        self.pixelScale = pixelScale
        self.physicalCanvasSize = physicalCanvasSize
        self.alignment = alignment
        self.post = post
        programCache = cache
        state = loadedState
    }

    /// The layout of the effects `state` shows.
    func layout(effects state: WPEParitySceneState, texts: [String: WPEParitySceneText] = [:],
                mipMappedFrameBufferRequested: Bool = false) throws
        -> WPEParityFrameLayout {
        var cache = programCache
        var post = post
        post.sceneMipMappedFrameBufferEnabled = mipMappedFrameBufferRequested
        let visible = Dictionary(zip(state.effects, state.effectVisibility)) { first, _ in first }
        var description = scene.scene(effectVisible: {
            visible[.init(objectID: $0, effectID: $1)] ?? true
        }, textSizes: texts.mapValues { $0.layout.fboSize }, logicalViewport: SIMD2(width, height))
        description.objects.removeAll { !state.isAlive($0.id) }
        for index in description.objects.indices {
            let previous = description.objects[index]
            guard let text = texts[previous.id] else { continue }
            var updated = WPEParitySceneObject.text(text, sortKey: previous.sortKey, visible: previous.visible,
                                                    parentID: previous.parentID, effects: previous.effects)
            updated.dependencyTarget = previous.dependencyTarget
            updated.materialFrameReads = previous.materialFrameReads
            description.objects[index] = updated
        }
        return try Self.layout(Self.loaded(description),
                               post: post, scene: scene, physicalBackbufferSize: physicalBackbufferSize,
                               physicalCanvasSize: physicalCanvasSize, pixelScale: pixelScale, cache: &cache)
    }

    /// Resolve a function's own declaration through the same physical sizing and identity rules as draws.
    /// This uses immutable plan metadata, so a host callback does not re-borrow the live SceneState inout.
    func materialFunctionResources(_ key: WPEParitySceneState.EffectKey, names: [String],
                                   texts: [String: WPEParitySceneText]) -> [WPEResourceID]? {
        let description = scene.scene(textSizes: texts.mapValues { $0.layout.fboSize },
                                      logicalViewport: SIMD2(width, height))
        guard var object = description.objects.first(where: { $0.id == key.objectID }),
              let index = object.effects.firstIndex(where: { $0.id == key.effectID }) else { return nil }
        for fbo in object.effects[index].fbos.indices {
            let declaration = object.effects[index].fbos[fbo]
            let size = declaration.sizing?.layerSize ?? SIMD2(object.width, object.height)
            object.effects[index].fbos[fbo] = declaration.resized(layerWidth: size.x, layerHeight: size.y,
                                                                physicalCanvasSize: physicalCanvasSize,
                                                                pixelScale: pixelScale)
        }
        let effect = object.effects[index]
        return names.map { WPEParitySceneResource.resolvedFBO(object: object, effect: effect, name: $0) }
    }

    /// Resolve requests before draw readiness: an undeclared target must not make its own reader disappear.
    /// All resident effect sets participate; optimized-out slots and failed programs request nothing.
    func requestsMipMappedFrameBuffer(
        in probes: [(frame: WPEParityFrame, programs: [Int: WPEParityProgram])],
        artifacts: [WPEHLSLProgram: Result<WPEParityShaderArtifact, WPEParityFrameSkip>]
    ) -> Bool {
        let mip = WPEResourceID("_rt_MipMappedFrameBuffer")
        for probe in probes {
            let bindings = WPEParityProgramBuilder.bindings(frame: probe.frame, scene: scene)
            for (index, program) in probe.programs {
                guard case .scene? = probe.frame.draws[index], let binding = bindings[index],
                      case let .success(artifact)? = artifacts[program.hlsl] else { continue }
                let resources = artifact.vertex.reflection.resources + artifact.fragment.reflection.resources
                if resources.contains(where: {
                    $0.kind == .texture && binding.textures[Int32($0.register)] == .resource(mip)
                }) {
                    return true
                }
            }
        }
        return false
    }

    /// Frame 0 of effect sets that between them put every effect pass in each place it can draw to: every effect
    /// on, every effect off, and for each position `m`, only effect `m` of each layer, with and without the layers
    /// that have children dropping theirs.
    func probeFrames() throws -> [(frame: WPEParityFrame, programs: [Int: WPEParityProgram])] {
        let parents = Set(scene.scene.objects.compactMap(\.parentID))
        let depth = scene.scene.objects.map(\.effects.count).max() ?? 0
        let positions = Dictionary(scene.scene.objects.map { object in
            (object.id, Dictionary(object.effects.enumerated().map { ($1.id, $0) }) { first, _ in first })
        }) { first, _ in first }
        var sets: [(String, String) -> Bool] = [{ _, _ in true }, { _, _ in false }]
        for position in 0 ..< depth {
            sets.append { positions[$0]?[$1] == position }
            sets.append { !parents.contains($0) && positions[$0]?[$1] == position }
        }
        var cache = programCache
        var seen: Set<[WPEPassIdentity]> = []
        return try sets.compactMap { visible in
            let frame = try WPEParityFrameComposer.compose(
                scene: Self.loaded(scene.scene(effectVisible: visible, logicalViewport: SIMD2(width, height))), post: post,
                frameIndex: 0, physicalBackbufferSize: physicalBackbufferSize,
                physicalCanvasSize: physicalCanvasSize, pixelScale: pixelScale
            )
            guard seen.insert(frame.operations.map(\.pass)).inserted else { return nil }
            return (frame, Self.programs(frame, scene: scene, cache: &cache).programs)
        }
    }

    /// WPE loads hidden objects too; the renderer skips their operations while they stay hidden (R24 Q2).
    private static func loaded(_ scene: WPEParitySceneDescription) -> WPEParitySceneDescription {
        var description = scene
        for index in description.objects.indices {
            description.objects[index].visible = true
        }
        return description
    }

    private static func layout(_ description: WPEParitySceneDescription, post: WPEParityPostProcessConfig,
                               scene: WPEParityProgramScene,
                               physicalBackbufferSize: SIMD2<Int>,
                               physicalCanvasSize: @escaping @Sendable (SIMD2<Int>) -> SIMD2<Int>,
                               pixelScale: Double,
                               cache: inout [WPEParityProgramKey: Result<WPEParityProgram, WPEParityFrameSkip>])
        throws -> WPEParityFrameLayout {
        let even = try WPEParityFrameComposer.compose(
            scene: description, post: post, frameIndex: 0, physicalBackbufferSize: physicalBackbufferSize,
            physicalCanvasSize: physicalCanvasSize, pixelScale: pixelScale
        )
        let odd = try WPEParityFrameComposer.compose(
            scene: description, post: post, frameIndex: 1, physicalBackbufferSize: physicalBackbufferSize,
            physicalCanvasSize: physicalCanvasSize, pixelScale: pixelScale
        )
        let (programs, skipped) = Self.programs(even, scene: scene, cache: &cache)
        let frames = even == odd ? [even] : [even, odd]
        return WPEParityFrameLayout(frames: frames, programs: programs,
                                    bindings: frames.map { WPEParityProgramBuilder.bindings(frame: $0, scene: scene, description: description) },
                                    skipped: skipped)
    }

    private static func programs(_ frame: WPEParityFrame, scene: WPEParityProgramScene,
                                 cache: inout [WPEParityProgramKey: Result<WPEParityProgram, WPEParityFrameSkip>])
        -> (programs: [Int: WPEParityProgram], skipped: [Int: WPEParityFrameSkip]) {
        var programs: [Int: WPEParityProgram] = [:]
        var skipped: [Int: WPEParityFrameSkip] = [:]
        for (index, draw) in frame.draws {
            let key = WPEParityProgramKey(draw)
            let result = cache[key] ?? {
                guard let description = WPEParityProgramBuilder.description(of: draw, scene: scene) else {
                    return .failure(.noMaterial)
                }
                do {
                    return try .success(WPEParityProgramResolver.resolve(description, sources: scene.assets))
                } catch {
                    return .failure(.program("\(description.material.shader): \(error)"))
                }
            }()
            cache[key] = result
            switch result {
            case let .success(program): programs[index] = program
            case let .failure(skip): skipped[index] = skip
            }
        }
        return (programs, skipped)
    }
}
#endif
