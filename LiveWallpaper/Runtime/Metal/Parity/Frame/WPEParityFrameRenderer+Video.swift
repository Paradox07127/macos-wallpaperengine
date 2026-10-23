#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal

extension WPEParityFrameRenderer {
    struct VideoAdmission {
        let id: UUID
        let streams: [WPEParityVideoTextures.Stream]
    }

    struct PendingVideoLayout {
        let request: VideoAdmission
        var planner: WPEParityFrameDrawPlanner
        let layout: Layout
        let stamp: [Int]
        let cachePrevious: Bool
    }

    struct DeferredVideoFrame {
        let uniforms: WPEParityUniformFrame
        let camera: WPEParityCamera
        let fadeAlpha: Float
    }

    private var videoLayoutStamp: [Int] {
        [state.membershipGeneration, state.effectVisibilityGeneration, plannerRevision]
    }

    var pendingVideoAdmission: VideoAdmission? {
        guard let pending = pendingVideoLayout else { return nil }
        guard pending.stamp == videoLayoutStamp else {
            pendingVideoLayout = nil
            deferredVideoFrame = nil
            return nil
        }
        return pending.request
    }

    func cancelVideoAdmission() {
        pendingVideoLayout = nil
        deferredVideoFrame = nil
    }

    /// Movie/export resumes the already-stepped frame rather than dispatching its scripts twice.
    func resumeVideoFrame(completion: (@Sendable (MTLCommandBuffer) -> Void)? = nil) throws -> WPEParityGraphExecutor.Submission {
        guard let deferred = deferredVideoFrame else { return .skipped }
        // Admission can have held this timestamp's ordered text cohort. Re-prepare it without
        // dispatching scripts/animations or advancing the scene clock for a second time.
        if pendingVideoAdmission == nil, try !replanRelaidTexts() {
            try requestTextVideoAdmission()
        }
        guard try selectGraphs() else { return .skipped }
        deferredVideoFrame = nil
        return try encodeSelectedFrame(uniforms: deferred.uniforms, renderCamera: deferred.camera,
                                       fadeAlpha: deferred.fadeAlpha, completion: completion)
    }

    nonisolated(nonsending) func prepareVideos(_ request: VideoAdmission) async throws -> WPEParityVideoTextures {
        try await WPEParityVideoTextures(streams: request.streams, workshopID: videoWorkshopID, device: device, queue: queue)
    }

    /// Preparation owns only new players. All fallible work precedes ownership and graph publication.
    func acceptVideos(_ prepared: WPEParityVideoTextures, for request: VideoAdmission) throws -> Bool {
        guard pendingVideoAdmission?.id == request.id, var pending = pendingVideoLayout else { return false }
        // Visibility, post settings and model buffers can keep changing while disk admission suspends.
        // Re-plan their current versions using the candidate's already discovered video identities.
        let candidateLayers = plan.modelDataTransforms(state: state, existing: layers)
        pending.planner.adoptModelDataTransforms(candidateLayers)
        let planned = try plan.layout(effects: state, texts: pending.planner.texts,
                                      mipMappedFrameBufferRequested: mipMappedFrameBufferRequested)
        let layout = try Self.makeLayout(planned, effects: state.effectVisibility, artifacts: artifacts,
                                         planner: &pending.planner, encoder: drawEncoder,
                                         state: state, reusing: pending.layout)
        guard pending.planner.videos.allSatisfy({ videos.contains($0.texture) || prepared.contains($0.texture) }) else {
            // A legal ModelData material replacement can reveal another stream while preparation suspends.
            // Keep the latest candidate private and requeue its full stream set; the old temporary pool retires.
            let streams = pending.planner.videos.filter { !videos.contains($0.texture) }
            pendingVideoLayout = PendingVideoLayout(request: VideoAdmission(id: UUID(), streams: streams),
                                                    planner: pending.planner, layout: layout,
                                                    stamp: videoLayoutStamp, cachePrevious: pending.cachePrevious)
            deferredVideoFrame = nil
            return false
        }
        let graphs = try prepareGraphs(layout)
        try Self.clear(prepared.textures, queue: queue)
        _ = pending.planner.takeVideoStreams()
        let previous = self.graphs.layout
        videos.adopt(prepared)
        pendingVideoLayout = nil
        planner = pending.planner
        layers = candidateLayers
        layersMoved = true
        publishGraphs(graphs, cachePrevious: pending.cachePrevious)
        retireRemovedObjects(from: previous.planned)
        packedConstants.removeAll()
        fadeConstants.removeAll()
        seenMembership = state.membershipGeneration
        seenModelData = state.modelDataGeneration
        seenVisibility = state.visibilityGeneration
        seenEffects = state.effectVisibilityGeneration
        refreshVideoOwners()
        repackBloom()
        return true
    }

    private func refreshVideoOwners() {
        var owners: [String: MTLTexture] = [:]
        for (index, draw) in graphs.layout.draws {
            guard case let .scene(description)? = graphs.layout.frames[0].draws[index], description.effectID == nil,
                  let source = draw.textures.first?["g_Texture0"] else { continue }
            let texture: MTLTexture? = switch source {
            case let .image(image): image
            case let .resource(id): planner.layerImages[id]
            }
            if let texture, videos.contains(texture) {
                owners[description.objectID] = texture
            }
        }
        videos.setOwners(owners)
    }

    /// A synchronous effect/membership change may discover a video, but cannot publish its unwritten texture.
    func installVideoReadyLayout(_ layout: Layout, planner candidate: WPEParityFrameDrawPlanner,
                                 cachePrevious: Bool) throws -> Bool {
        let streams = candidate.videos.filter { !videos.contains($0.texture) }
        guard streams.isEmpty else {
            guard streams.allSatisfy({ !$0.bytes.isEmpty }) else {
                throw WPEParityFrameSkip.videoTexture("A newly selected video has no admission payload")
            }
            pendingVideoLayout = PendingVideoLayout(request: VideoAdmission(id: UUID(), streams: streams),
                                                    planner: candidate, layout: layout,
                                                    stamp: videoLayoutStamp, cachePrevious: cachePrevious)
            return false
        }
        let prepared = try prepareGraphs(layout)
        planner = candidate
        publishGraphs(prepared, cachePrevious: cachePrevious)
        return true
    }

    /// Resolved at frame submission, after every graph replacement path has also updated the planner's images.
    func bindVideoSources() -> [Int: Set<Int>] {
        let sources = Self.videoSources(of: graphs.layout.draws.mapValues(\.textures), videos: videos.textures,
                                        layerImages: planner.layerImages)
        drawVideoSources = sources
        videos.setBoundSources(Set(sources.values.joined()))
        return sources
    }

    /// Per draw operation, the indices into `videos` of the textures any slot of any of its passes binds;
    /// draws binding none are absent.
    static func videoSources(of draws: [Int: [[String: WPEParityFrameDrawPlan.TextureSource]]], videos: [MTLTexture],
                             layerImages: [WPEResourceID: MTLTexture]) -> [Int: Set<Int>] {
        guard !videos.isEmpty else { return [:] }
        var indices: [ObjectIdentifier: Int] = [:]
        for (index, texture) in videos.enumerated() {
            indices[ObjectIdentifier(texture)] = index
        }
        var sources: [Int: Set<Int>] = [:]
        for (operation, passes) in draws {
            var bound: Set<Int> = []
            for slots in passes {
                for source in slots.values {
                    let texture: MTLTexture? = switch source {
                    case let .image(image): image
                    case let .resource(id): layerImages[id]
                    }
                    if let texture, let index = indices[ObjectIdentifier(texture)] {
                        bound.insert(index)
                    }
                }
            }
            if !bound.isEmpty {
                sources[operation] = bound
            }
        }
        return sources
    }
}
#endif
