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
    /// Backbuffer size in pixels.
    let width: Int
    let height: Int
    /// The user alignment the camera crops the canvas with (R8 Q1).
    let alignment: WPEParityCameraAlignment
    /// Object and material state as loaded, hidden objects included.
    let state: WPEParitySceneState
    let post: WPEParityPostProcessConfig
    /// The program of every draw any effect set has, disabled effects included, as WPE loads them (R24 Q3).
    let programCache: [WPEParityProgramKey: Result<WPEParityProgram, WPEParityFrameSkip>]

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
        return programCache.values.compactMap { result in
            guard case let .success(program) = result, seen.insert(program.hlsl).inserted else { return nil }
            return program
        }
    }

    init(document: WPESceneDocument, assets: WPEParityProgramAssets, settings: WPEParityProgramSettings,
         width: Int, height: Int, alignment: WPEParityCameraAlignment = .noCrop) throws {
        let scene = WPEParityProgramScene(document: document, assets: assets, settings: settings)
        var post = scene.postProcess
        (post.backbufferWidth, post.backbufferHeight) = (width, height)
        var cache: [WPEParityProgramKey: Result<WPEParityProgram, WPEParityFrameSkip>] = [:]
        layout = try Self.layout(Self.sized(scene.scene, width: width, height: height), post: post, scene: scene,
                                 cache: &cache)
        // Every effect on, then every effect off, draws each material any effect set does.
        for enabled in [true, false] {
            let frame = try WPEParityFrameComposer.compose(
                scene: Self.sized(scene.scene(effectVisible: { _, _ in enabled }), width: width, height: height),
                post: post,
                frameIndex: 0
            )
            _ = Self.programs(frame, scene: scene, cache: &cache)
        }

        self.document = document
        self.scene = scene
        self.width = width
        self.height = height
        self.alignment = alignment
        self.post = post
        programCache = cache
        state = WPEParitySceneState(scene: scene, document: document)
    }

    /// The layout of the effects `state` shows.
    func layout(effects state: WPEParitySceneState) throws -> WPEParityFrameLayout {
        var cache = programCache
        return try Self.layout(Self.sized(Self.scene(scene, effects: state.effectVisibility, of: state.effects),
                                          width: width, height: height),
                               post: post, scene: scene, cache: &cache)
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
                scene: Self.sized(scene.scene(effectVisible: visible), width: width, height: height), post: post,
                frameIndex: 0
            )
            guard seen.insert(frame.operations.map(\.pass)).inserted else { return nil }
            return (frame, Self.programs(frame, scene: scene, cache: &cache).programs)
        }
    }

    private static func scene(_ scene: WPEParityProgramScene, effects visibility: [Bool],
                              of keys: [WPEParitySceneState.EffectKey]) -> WPEParitySceneDescription {
        let visible = Dictionary(zip(keys, visibility)) { first, _ in first }
        return scene.scene(effectVisible: { visible[WPEParitySceneState.EffectKey(objectID: $0, effectID: $1)] ?? true })
    }

    /// WPE loads hidden objects too; the renderer skips their operations while they stay hidden (R24 Q2).
    private static func sized(_ scene: WPEParitySceneDescription, width: Int,
                              height: Int) -> WPEParitySceneDescription {
        var description = scene
        for index in description.objects.indices {
            description.objects[index].visible = true
        }
        (description.width, description.height) = (width, height)
        return description
    }

    private static func layout(_ description: WPEParitySceneDescription, post: WPEParityPostProcessConfig,
                               scene: WPEParityProgramScene,
                               cache: inout [WPEParityProgramKey: Result<WPEParityProgram, WPEParityFrameSkip>])
        throws -> WPEParityFrameLayout {
        let even = try WPEParityFrameComposer.compose(scene: description, post: post, frameIndex: 0)
        let odd = try WPEParityFrameComposer.compose(scene: description, post: post, frameIndex: 1)
        let (programs, skipped) = Self.programs(even, scene: scene, cache: &cache)
        let frames = even == odd ? [even] : [even, odd]
        return WPEParityFrameLayout(frames: frames, programs: programs,
                                    bindings: frames.map { WPEParityProgramBuilder.bindings(frame: $0, scene: scene) },
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
