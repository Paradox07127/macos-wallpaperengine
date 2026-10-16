#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import MetalPerformanceShaders

/// Plays each video .tex of a scene into the fixed texture its draws sample.
final class WPEParityVideoTextures {
    /// A video .tex as planned: the texture draws sample and the MP4 stream from its first mip.
    struct Stream {
        let texture: MTLTexture
        /// Empty once the planner has handed the stream to its decoder.
        var bytes: Data
    }

    private let videos: [(source: WPEVideoTextureSource, texture: MTLTexture)]
    private let scaler: MPSImageBilinearScale
    /// Indices of the sources whose staged frame went into the current frame's command buffer.
    private var encoded: Set<Int> = []
    private var owners: [String: Int] = [:]
    private struct ObservedControls {
        var rate: WPEParitySceneState.ScriptValue?
        var loop: WPEParitySceneState.ScriptValue?
    }

    private var observedControls: [String: ObservedControls] = [:]
    private var seenScriptFieldsGeneration: Int?

    var textures: [MTLTexture] {
        videos.map(\.texture)
    }

    /// Slot zero keeps the planner's existing shared-asset identity: owners of the same texture share one player.
    func setOwners(_ textures: [String: MTLTexture]) {
        var indices: [ObjectIdentifier: Int] = [:]
        for (index, video) in videos.enumerated() {
            indices[ObjectIdentifier(video.texture)] = index
        }
        let next = textures.compactMapValues { indices[ObjectIdentifier($0)] }
        guard next != owners else { return }
        observedControls = observedControls.filter { next[$0.key] == owners[$0.key] }
        owners = next
        seenScriptFieldsGeneration = nil
    }

    /// Native pause forwards to the layer's existing player (1401fa560); shared owners keep sharing that source.
    func pause(ownerID: String) -> Bool {
        guard let index = owners[ownerID] else { return false }
        videos[index].source.scriptPause()
        return true
    }

    /// The other IVideoTexture methods on the same player; nil = `ownerID` has no video.
    func command(ownerID: String, _ command: WPEParityScriptEngine.VideoCommand, argument: Double) -> Double? {
        guard let index = owners[ownerID] else { return nil }
        let source = videos[index].source
        switch command {
        case .play: source.scriptPlay()
        case .stop: source.scriptStop()
        case .setCurrentTime: source.scriptSetCurrentTime(argument)
        case .isPlaying: return source.scriptPlaybackSnapshot?.isPlaying == true ? 1 : 0
        case .getCurrentTime: return source.scriptPlaybackSnapshot?.currentTime ?? 0
        }
        return 0
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        for video in videos {
            video.source.applyPerformanceProfile(profile)
        }
    }

    func hasOwner(_ id: String) -> Bool {
        owners[id] != nil
    }

    /// Observes the existing source; this is not a SceneScript query API or a second playback state.
    func playbackSnapshot(ownerID: String) -> WPEVideoPlaybackSnapshot? {
        guard let index = owners[ownerID] else { return nil }
        return videos[index].source.scriptPlaybackSnapshot
    }

    /// Seeds script descriptors from the player, including a duration that can become ready after scene loading.
    var scriptFieldDefaults: [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue] {
        let snapshots = videos.map(\.source.scriptPlaybackSnapshot)
        var fields: [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue] = [:]
        for (owner, index) in owners {
            guard let snapshot = snapshots[index] else { continue }
            fields[.init(objectID: owner, name: "video.rate")] = .vector(SIMD4(Float(snapshot.rate), 0, 0, 0))
            fields[.init(objectID: owner, name: "video.loop")] = .vector(SIMD4(snapshot.loop ? 1 : 0, 0, 0, 0))
            fields[.init(objectID: owner, name: "video.duration")] = .vector(SIMD4(Float(snapshot.duration), 0, 0, 0))
        }
        return fields
    }

    /// Applies only newly observed controls, then publishes asynchronously ready durations without dirtying draws.
    func applyScriptFields(state: inout WPEParitySceneState) {
        if seenScriptFieldsGeneration != state.scriptFieldsGeneration {
            // A shared asset can have several owners. An unrelated field change must not replay another owner's
            // older command over the current source value; owner ordering only resolves simultaneous new writes.
            for owner in owners.keys.sorted() {
                guard let index = owners[owner] else { continue }
                let source = videos[index].source
                let rate = state.scriptField("video.rate", of: owner)
                let loop = state.scriptField("video.loop", of: owner)
                let previous = observedControls[owner]
                if rate != previous?.rate, case let .vector(value)? = rate,
                   value.x.isFinite, (0.5 ... 2).contains(value.x),
                   source.scriptPlaybackSnapshot?.rate != Double(value.x) {
                    source.scriptSetRate(Double(value.x))
                }
                if loop != previous?.loop, case let .vector(value)? = loop, value.x.isFinite,
                   source.scriptPlaybackSnapshot?.loop != (value.x != 0) {
                    source.scriptSetLoop(value.x != 0)
                }
                observedControls[owner] = ObservedControls(rate: rate, loop: loop)
            }
        }
        let durations = videos.map { $0.source.scriptPlaybackSnapshot?.duration }
        for (owner, index) in owners {
            guard let duration = durations[index], duration.isFinite else { continue }
            let value = WPEParitySceneState.ScriptValue.vector(SIMD4(Float(duration), 0, 0, 0))
            if state.scriptField("video.duration", of: owner) != value {
                state.setScriptField("video.duration", of: owner, to: value, invalidating: .none)
            }
        }
        seenScriptFieldsGeneration = state.scriptFieldsGeneration
    }

    /// Stores each stream in the video disk cache and starts looping wall-clock playback.
    nonisolated(nonsending) init(streams: [Stream], workshopID: String, device: MTLDevice,
                                 queue: MTLCommandQueue) async throws {
        var videos: [(source: WPEVideoTextureSource, texture: MTLTexture)] = []
        for stream in streams {
            let url = try await WPEVideoTextureDiskCache.shared.store(stream.bytes, workshopID: workshopID)
            let source: WPEVideoTextureSource
            do {
                source = try WPEVideoTextureSource(device: device, videoURL: url, commandQueue: queue,
                                                   onInvalidate: { url in
                                                       Task.detached(priority: .utility) {
                                                           await WPEVideoTextureDiskCache.shared.release(url)
                                                       }
                                                   })
            } catch {
                await WPEVideoTextureDiskCache.shared.release(url)
                throw error
            }
            source.applyPerformanceProfile(.quality)
            videos.append((source, stream.texture))
        }
        self.videos = videos
        scaler = Self.scaler(device: device)
    }

    /// The default zero edge mode blends the border texels with transparent black.
    static func scaler(device: MTLDevice) -> MPSImageBilinearScale {
        let scaler = MPSImageBilinearScale(device: device)
        scaler.edgeMode = .clamp
        return scaler
    }

    deinit {
        for video in videos {
            video.source.invalidate()
        }
    }

    /// Stages each decoder's new frame into `commandBuffer` ahead of the scene and stretches it over its texture; a
    /// source without a new frame leaves its texture as it was.
    func encode(into commandBuffer: MTLCommandBuffer) throws {
        for (index, video) in videos.enumerated() {
            // The decoder paces by AVPlayer's wall clock and ignores the time argument.
            guard let frame = video.source.texture(at: 0), video.source.hasStagedFrameWork else { continue }
            video.source.encodeStagedFrameWork(into: commandBuffer)
            guard !video.source.stagedFrameWorkEncodingFailed else { continue }
            encoded.insert(index)
            try Self.stretch(frame, into: video.texture, scaler: scaler, commandBuffer: commandBuffer)
        }
    }

    /// Call after every frame: `encode` only runs on a command buffer that is then committed, so the sources it
    /// encoded publish their frame and every other source drops what it armed.
    func finishFrame() {
        for (index, video) in videos.enumerated() {
            if encoded.contains(index) {
                video.source.commitStagedFrameWork()
            } else {
                video.source.rollbackStagedFrameWork()
            }
        }
        encoded.removeAll()
    }

    /// Fills `texture` with `frame`, as WPE's TransferVideoFrame stretches into the fixed texture (1400f3480.c:18-52).
    static func stretch(_ frame: MTLTexture, into texture: MTLTexture, scaler: MPSImageBilinearScale,
                        commandBuffer: MTLCommandBuffer) throws {
        if frame.width == texture.width, frame.height == texture.height, frame.pixelFormat == texture.pixelFormat {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw WPEParityFrameRenderError.encoderUnavailable
            }
            blit.copy(from: frame, to: texture)
            blit.endEncoding()
        } else {
            scaler.encode(commandBuffer: commandBuffer, sourceTexture: frame, destinationTexture: texture)
        }
    }
}
#endif
