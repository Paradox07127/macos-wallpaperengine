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
    /// The `.tex` holds a video stream, which this renderer does not decode.
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
    let materials: [Int: WPEParityProgramMaterial]
    let skipped: [Int: WPEParityFrameSkip]
    /// Every effect FBO name the scene declares; a material texture with one of these names samples an FBO.
    let fboNames: Set<String>

    init(document: WPESceneDocument, sceneDirectory: URL, assetRoots: [URL], settings: WPEParityProgramSettings,
         width: Int, height: Int) throws {
        let assets = WPEParityProgramAssets(sceneDirectory: sceneDirectory, assetRoots: assetRoots)
        let scene = WPEParityProgramScene(document: document, assets: assets, settings: settings)
        var description = scene.scene
        var post = scene.postProcess
        (description.width, description.height) = (width, height)
        (post.backbufferWidth, post.backbufferHeight) = (width, height)
        let even = try WPEParityFrameComposer.compose(scene: description, post: post, frameIndex: 0)
        let odd = try WPEParityFrameComposer.compose(scene: description, post: post, frameIndex: 1)

        var programs: [Int: WPEParityProgram] = [:]
        var materials: [Int: WPEParityProgramMaterial] = [:]
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
            materials[index] = description.material
            do {
                programs[index] = try WPEParityProgramResolver.resolve(description, sources: assets)
            } catch {
                skipped[index] = .program("\(description.material.shader): \(error)")
            }
        }

        var fboNames: Set<String> = []
        for effect in document.imageObjects.flatMap(\.effects) {
            guard case let .array(fbos)? = assets.json(effect.fileRelativePath)?["fbos"] else { continue }
            for fbo in fbos {
                if case let .string(name)? = fbo["name"] {
                    fboNames.insert(name)
                }
            }
        }

        self.document = document
        self.scene = scene
        frames = even == odd ? [even] : [even, odd]
        self.programs = programs
        self.materials = materials
        self.skipped = skipped
        self.fboNames = fboNames
    }
}
#endif
