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
}

public enum WPEParityFrameComposer {
    /// `frameIndex` picks the side of each effect FBO swap pair, as in `WPEParitySceneFrameBuilder.build`.
    public static func compose(scene: WPEParitySceneDescription, post: WPEParityPostProcessConfig,
                               frameIndex: Int) throws(WPEParityFrameCompositionError) -> WPEParityFrame {
        guard scene.msaaSamples == post.msaaSampleCount else {
            throw .sampleCountMismatch(scene: scene.msaaSamples, post: post.msaaSampleCount)
        }
        let sceneBackbuffer = "\(scene.width)x\(scene.height) \(scene.backbufferFormat)"
        let postBackbuffer = "\(post.backbufferWidth)x\(post.backbufferHeight) \(post.backbufferFormat)"
        guard sceneBackbuffer == postBackbuffer else {
            throw .backbufferMismatch(scene: sceneBackbuffer, post: postBackbuffer)
        }
        return try merge(WPEParitySceneFrameBuilder.build(scene, frameIndex: frameIndex),
                         WPEParityPostProcessBuilder.build(post))
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
        var postDraws = postFrame.draws.makeIterator()
        for (index, operation) in operations.enumerated() {
            guard case .draw = operation.kind else { continue }
            if index < sceneFrame.operations.count {
                draws[index] = sceneFrame.draws[operation.pass].map(WPEParityFrameDraw.scene)
            } else {
                draws[index] = postDraws.next().map(WPEParityFrameDraw.post)
            }
        }
        return WPEParityFrame(operations: operations, resources: resources, draws: draws,
                              samplers: sceneFrame.samplers)
    }
}
