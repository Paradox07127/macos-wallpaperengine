public enum WPEParityFrameCompositionError: Error, Hashable, Sendable {
    /// Both parts declare this id with different properties.
    case conflictingResource(WPEResourceID)
    case sampleCountMismatch(scene: Int, post: Int)
    /// Each side reads `<width>x<height> <format>`.
    case backbufferMismatch(scene: String, post: String)
}

public enum WPEParityFrameDraw: Hashable, Sendable {
    case scene(WPEParitySceneDraw)
    case post(WPEParityPostProcessDraw)
}

/// One whole WPE frame: the scene loop followed by the post-object chain, ending at present.
public struct WPEParityFrame: Hashable, Sendable {
    public let operations: [WPERenderOperation]
    public let resources: [WPELogicalResource]
    /// Keyed by the index of the draw operation in `operations`.
    public let draws: [Int: WPEParityFrameDraw]
    /// Samplers of the scene's layer composites; see `WPEParitySceneFrame.samplers`.
    public let samplers: [WPEResourceID: WPEParitySceneSampler]
    /// The object each operation renders, keyed by operation index; scene-wide and post operations are absent.
    public let owners: [Int: String]
    public let particleBlocks: [WPEParityParticleBlock]
    /// Both parts' `logicalSizes`.
    public let logicalSizes: [WPEResourceID: SIMD2<Int>]
}

public enum WPEParityFrameComposer {
    /// Post is already configured for the physical backbuffer. Its pyramid/RV0/texel sizes are never scaled again.
    public static func compose(scene: WPEParitySceneDescription, post: WPEParityPostProcessConfig,
                               physicalBackbufferSize: SIMD2<Int>? = nil,
                               physicalCanvasSize: @escaping @Sendable (SIMD2<Int>) -> SIMD2<Int> = { $0 },
                               pixelScale: Double = 1) throws(WPEParityFrameCompositionError) -> WPEParityFrame {
        try compose(scene: scene, posts: [post], physicalBackbufferSize: physicalBackbufferSize,
                    physicalCanvasSize: physicalCanvasSize, pixelScale: pixelScale)[0]
    }

    /// One frame per post, in order; the scene frame is built once and merged with each.
    public static func compose(scene: WPEParitySceneDescription, posts: [WPEParityPostProcessConfig],
                               physicalBackbufferSize: SIMD2<Int>? = nil,
                               physicalCanvasSize: @escaping @Sendable (SIMD2<Int>) -> SIMD2<Int> = { $0 },
                               pixelScale: Double = 1) throws(WPEParityFrameCompositionError) -> [WPEParityFrame] {
        for post in posts where scene.msaaSamples != post.msaaSampleCount {
            throw .sampleCountMismatch(scene: scene.msaaSamples, post: post.msaaSampleCount)
        }
        guard !posts.isEmpty else { return [] }
        let sceneFrame = WPEParitySceneFrameBuilder.build(
            scene, physicalBackbufferSize: physicalBackbufferSize,
            physicalCanvasSize: physicalCanvasSize, pixelScale: pixelScale
        )
        let actual = sceneFrame.resources.first { $0.id == WPEParitySceneResource.backbuffer }
        let sceneBackbuffer = actual.map { "\($0.width)x\($0.height) \($0.format)" }
            ?? "missing backbuffer"
        var frames: [WPEParityFrame] = []
        frames.reserveCapacity(posts.count)
        for post in posts {
            let postBackbuffer = "\(post.backbufferWidth)x\(post.backbufferHeight) \(post.backbufferFormat)"
            guard sceneBackbuffer == postBackbuffer else {
                throw .backbufferMismatch(scene: sceneBackbuffer, post: postBackbuffer)
            }
            try frames.append(merge(sceneFrame, WPEParityPostProcessBuilder.build(post)))
        }
        return frames
    }

    static func merge(_ sceneFrame: WPEParitySceneFrame,
                      _ postFrame: WPEParityPostProcessFrame) throws(WPEParityFrameCompositionError) -> WPEParityFrame {
        var resources = sceneFrame.resources
        var byID = Dictionary(uniqueKeysWithValues: resources.map { ($0.id, $0) })
        for resource in postFrame.resources {
            if let existing = byID[resource.id] {
                guard existing == resource else { throw .conflictingResource(resource.id) }
                continue
            }
            byID[resource.id] = resource
            resources.append(resource)
        }

        let operations = sceneFrame.operations + postFrame.operations
        var draws: [Int: WPEParityFrameDraw] = [:]
        var owners: [Int: String] = [:]
        var postDraws = postFrame.draws.makeIterator()
        for (index, operation) in operations.enumerated() {
            if index < sceneFrame.operations.count {
                owners[index] = sceneFrame.owners[operation.pass]
            }
            guard case .draw = operation.kind else { continue }
            if index < sceneFrame.operations.count {
                draws[index] = sceneFrame.draws[operation.pass].map(WPEParityFrameDraw.scene)
            } else {
                draws[index] = postDraws.next().map(WPEParityFrameDraw.post)
            }
        }
        return WPEParityFrame(operations: operations, resources: resources, draws: draws,
                              samplers: sceneFrame.samplers, owners: owners, particleBlocks: sceneFrame.particleBlocks,
                              logicalSizes: sceneFrame.logicalSizes.merging(postFrame.logicalSizes) { scene, _ in scene })
    }
}
