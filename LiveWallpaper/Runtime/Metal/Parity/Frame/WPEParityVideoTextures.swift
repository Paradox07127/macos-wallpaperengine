#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import MetalPerformanceShaders

/// Plays each video .tex of a scene into the fixed texture its draws sample, and each video file the user bound to
/// one of its scene textures.
final class WPEParityVideoTextures {
    /// A video .tex as planned: the texture draws sample and the MP4 stream from its first mip.
    struct Stream {
        let texture: MTLTexture
        /// Empty once the planner has handed the stream to its decoder.
        var bytes: Data
    }

    private var videos: [(source: WPEVideoTextureSource, texture: MTLTexture)]
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

    /// The actual decoder owners, including live user-video replacements.
    var sourceCount: Int {
        videos.count + userVideos.count
    }

    func contains(_ texture: MTLTexture) -> Bool {
        videos.contains { $0.texture === texture }
    }

    /// Transfers only newly prepared players. The temporary owner's deinit must not stop adopted players.
    func adopt(_ prepared: WPEParityVideoTextures) {
        guard prepared !== self else { return }
        precondition(prepared.userVideos.isEmpty, "Only a newly prepared authored-stream batch may transfer players")
        let added = prepared.videos
        prepared.videos.removeAll()
        for video in added {
            guard !contains(video.texture) else {
                video.source.invalidate()
                continue
            }
            video.source.applyPerformanceProfile(profile)
            videos.append(video)
            lastSampledFrame.append(submittedFrames)
            reportedLoops.append(video.source.completedLoopCount)
        }
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

    /// WPE pauses a video no draw has bound for more than this many frames and plays it again once one does
    /// (1400f3930.c:48-75).
    static let unsampledFrameLimit = 30
    private var submittedFrames = 0
    /// Per source, the last submitted frame on which an executed draw bound its texture.
    private var lastSampledFrame: [Int]
    /// Sources some draw of the current layout binds; a source no draw binds keeps playing.
    private var boundSources: Set<Int> = []

    func setBoundSources(_ sources: Set<Int>) {
        boundSources = sources
    }

    /// Call once per submitted frame with the sources the draws it executed bound.
    func recordSampled(sources: some Sequence<Int>) {
        submittedFrames += 1
        for index in sources {
            lastSampledFrame[index] = submittedFrames
        }
        for (index, video) in videos.enumerated() {
            let unsampled = submittedFrames - lastSampledFrame[index] > Self.unsampledFrameLimit
            video.source.setUnsampledPaused(boundSources.contains(index) && unsampled)
        }
        for key in sampledUserVideos {
            userVideos[key]?.lastSampledFrame = submittedFrames
        }
        sampledUserVideos.removeAll()
        for video in userVideos.values {
            video.source.setUnsampledPaused(submittedFrames - video.lastSampledFrame > Self.unsampledFrameLimit)
        }
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        self.profile = profile
        for video in videos {
            video.source.applyPerformanceProfile(profile)
        }
        for video in userVideos.values {
            video.source.applyPerformanceProfile(profile)
        }
    }

    #if DEBUG
    /// Capture harness only: parks every decoder at `seconds` of media time instead of the wall clock.
    nonisolated(nonsending) func seekForCapture(to seconds: Double) async {
        for video in videos {
            _ = await video.source.seekForCapture(to: seconds)
        }
    }
    #endif

    /// Per source, the completed play count already reported.
    private var reportedLoops: [Int]

    /// Call once per frame: each owner of a source that reached its end since the last call, once per occurrence.
    func takeEndedOwnerIDs() -> [String] {
        var ended: [String] = []
        for (index, video) in videos.enumerated() {
            let count = video.source.completedLoopCount
            let occurrences = count - reportedLoops[index]
            reportedLoops[index] = count
            guard occurrences > 0 else { continue }
            let owners = owners.filter { $0.value == index }.keys.sorted()
            for _ in 0 ..< occurrences {
                ended += owners
            }
        }
        return ended
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
                   value.x.isFinite, value.x > 0,
                   source.scriptPlaybackSnapshot?.rate != Double(value.x) {
                    source.scriptSetAnyPositiveRate(Double(value.x))
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
        var accepted = false
        defer {
            if !accepted {
                for video in videos {
                    video.source.invalidate()
                }
            }
        }
        for stream in streams {
            try Task.checkCancellation()
            let url = try await WPEVideoTextureDiskCache.shared.store(stream.bytes, workshopID: workshopID)
            let source: WPEVideoTextureSource
            do {
                try Task.checkCancellation()
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
        try Task.checkCancellation()
        self.videos = videos
        lastSampledFrame = Array(repeating: 0, count: videos.count)
        reportedLoops = videos.map(\.source.completedLoopCount)
        scaler = Self.scaler(device: device)
        self.device = device
        self.queue = queue
        accepted = true
    }

    /// A video file the user bound to a scene texture: muted, looping and wall-clock paced like a video .tex.
    private struct UserVideo {
        let url: URL
        let source: WPEVideoTextureSource
        let scoped: Bool
        var lastSampledFrame: Int
        /// Per rounded slot aspect (tenths; nil = keepaspect), that aspect's crop; nil until a frame fills it.
        var crops: [Int?: (aspect: Float?, texture: MTLTexture?)] = [:]
    }

    private var userVideos: [String: UserVideo] = [:]
    private var sampledUserVideos: Set<String> = []
    private var encodedUserVideos: Set<String> = []
    private var profile: WallpaperPerformanceProfile = .quality
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    /// Transparent black, what a slot samples between opening its video and the first decoded frame.
    private lazy var blank: MTLTexture? = {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 0, count: 4),
                         bytesPerRow: 4)
        return texture
    }()

    /// Property key → bound file; starts a player for each new file and retires the ones no longer bound.
    func bindUserVideos(_ urls: [String: URL]) {
        for (key, video) in userVideos where urls[key] != video.url {
            Self.retire(video)
            userVideos[key] = nil
        }
        for (key, url) in urls where userVideos[key] == nil {
            let scoped = url.startAccessingSecurityScopedResource()
            // Without an onInvalidate the source deletes its file on retirement: here that is the user's own video.
            guard let source = try? WPEVideoTextureSource(device: device, videoURL: url, commandQueue: queue,
                                                          onInvalidate: { _ in }) else {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
                continue
            }
            source.applyPerformanceProfile(profile)
            userVideos[key] = UserVideo(url: url, source: source, scoped: scoped, lastSampledFrame: submittedFrames)
        }
    }

    /// The video bound to `slot.key`, centre-cropped to the slot aspect; transparent black until its first frame.
    /// nil (the authored texture) without a video, while the file is still opening, or once it can't be played.
    func userTexture(for slot: WPEUserImageSlot) -> MTLTexture? {
        guard let video = userVideos[slot.key] else { return nil }
        sampledUserVideos.insert(slot.key)
        guard video.source.openState == true else { return nil }
        let fit = slot.aspect.map { Int(($0 * 10).rounded()) }
        if let texture = video.crops[fit]?.texture {
            return texture
        }
        if video.crops[fit] == nil {
            userVideos[slot.key]?.crops[fit] = (slot.aspect, nil)
        }
        return blank
    }

    private static func retire(_ video: UserVideo) {
        video.source.invalidate()
        if video.scoped {
            video.url.stopAccessingSecurityScopedResource()
        }
    }

    #if DEBUG
    var authoredSourcesForTesting: [WPEVideoTextureSource] {
        videos.map(\.source)
    }

    func userVideoSourceForTesting(_ key: String) -> WPEVideoTextureSource? {
        userVideos[key]?.source
    }
    #endif

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
        for video in userVideos.values {
            Self.retire(video)
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
        for (key, video) in userVideos {
            guard let frame = video.source.texture(at: 0) else { continue }
            let staged = video.source.hasStagedFrameWork
            if staged {
                video.source.encodeStagedFrameWork(into: commandBuffer)
                guard !video.source.stagedFrameWorkEncodingFailed else { continue }
                encodedUserVideos.insert(key)
            }
            for (fit, crop) in video.crops where staged || crop.texture == nil {
                userVideos[key]?.crops[fit]?.texture = centreCrop(frame, aspect: crop.aspect, into: crop.texture,
                                                                  commandBuffer: commandBuffer)
            }
        }
    }

    /// `frame`'s centred region of the slot aspect, copied 1:1 into `texture` or into a new texture of that size.
    private func centreCrop(_ frame: MTLTexture, aspect: Float?, into texture: MTLTexture?,
                            commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let rect = aspect.map { WPEUserShortcutIconImage.cropRect(width: frame.width, height: frame.height, aspect: $0) }
            ?? (x: 0, y: 0, width: frame.width, height: frame.height)
        var target = texture
        if target?.width != rect.width || target?.height != rect.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: rect.width,
                                                                      height: rect.height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            target = device.makeTexture(descriptor: descriptor)
        }
        guard let target else { return nil }
        var transform = MPSScaleTransform(scaleX: 1, scaleY: 1, translateX: -Double(rect.x), translateY: -Double(rect.y))
        withUnsafePointer(to: &transform) { transform in
            scaler.scaleTransform = transform
            scaler.encode(commandBuffer: commandBuffer, sourceTexture: frame, destinationTexture: target)
        }
        scaler.scaleTransform = nil
        return target
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
        for (key, video) in userVideos {
            if encodedUserVideos.contains(key) {
                video.source.commitStagedFrameWork()
            } else {
                video.source.rollbackStagedFrameWork()
            }
        }
        encodedUserVideos.removeAll()
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
