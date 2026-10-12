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

/// A scene document turned into its parity frame and the WPE program of each draw; holds no Metal objects.
struct WPEParityFramePlan {
    let document: WPESceneDocument
    let scene: WPEParityProgramScene
    /// Frame `n` uses `frames[n % frames.count]`; a second entry exists only when FBO swap pairs alternate.
    let frames: [WPEParityFrame]
    /// Keyed by draw operation index; a draw without a program is in `skipped`.
    let programs: [Int: WPEParityProgram]
    /// One table per entry of `frames`, keyed like `programs`.
    let bindings: [[Int: WPEParityProgramBinding]]
    let skipped: [Int: WPEParityFrameSkip]
    /// Backbuffer size in pixels.
    let width: Int
    let height: Int
    /// The user alignment the camera crops the canvas with (R8 Q1).
    let alignment: WPEParityCameraAlignment
    /// Object and material state as loaded, hidden objects included.
    let state: WPEParitySceneState

    init(document: WPESceneDocument, assets: WPEParityProgramAssets, settings: WPEParityProgramSettings,
         width: Int, height: Int, alignment: WPEParityCameraAlignment = .noCrop) throws {
        let scene = WPEParityProgramScene(document: document, assets: assets, settings: settings)
        var description = scene.scene
        var post = scene.postProcess
        // WPE loads hidden objects too; the renderer skips their operations while they stay hidden (R24 Q2).
        for index in description.objects.indices {
            description.objects[index].visible = true
        }
        (description.width, description.height) = (width, height)
        (post.backbufferWidth, post.backbufferHeight) = (width, height)
        let even = try WPEParityFrameComposer.compose(scene: description, post: post, frameIndex: 0)
        let odd = try WPEParityFrameComposer.compose(scene: description, post: post, frameIndex: 1)

        var programs: [Int: WPEParityProgram] = [:]
        var skipped: [Int: WPEParityFrameSkip] = [:]
        for draw in WPEParityProgramBuilder.draws(frame: even, scene: scene) {
            let index = draw.operationIndex
            if case let .scene(sceneDraw)? = even.draws[index], sceneDraw.geometry == .modelMesh {
                skipped[index] = .modelMesh
                continue
            }
            guard let description = draw.description else {
                skipped[index] = .noMaterial
                continue
            }
            do {
                programs[index] = try WPEParityProgramResolver.resolve(description, sources: assets)
            } catch {
                skipped[index] = .program("\(description.material.shader): \(error)")
            }
        }

        self.document = document
        self.scene = scene
        frames = even == odd ? [even] : [even, odd]
        bindings = frames.map { WPEParityProgramBuilder.bindings(frame: $0, scene: scene) }
        self.programs = programs
        self.skipped = skipped
        self.width = width
        self.height = height
        self.alignment = alignment
        state = WPEParitySceneState(scene: scene, document: document)
    }
}
#endif
