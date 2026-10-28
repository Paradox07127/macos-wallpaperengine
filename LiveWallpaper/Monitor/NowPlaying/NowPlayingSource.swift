import Foundation
#if !LITE_BUILD
import CryptoKit
import Darwin
#endif

final actor NowPlayingSource: MonitorDataSource {
    nonisolated let sourceID = "nowPlaying"

    private let monitorOverride: NowPlayingMonitor?
    private let fetcher: NowPlayingArtworkFetcher
    private var subscriptionID = UUID()
    private var monitor: NowPlayingMonitor?
    private var sink: (any MonitorSnapshotSink)?
    private var lastForwardedOrdinal: UInt64?
    /// Artwork may only attach to the track key that is still current when the fetch lands.
    private var currentTrackKey: String?
    /// Key the running/finished artwork task was started for, so repeated
    /// frames of one track do not spawn repeated fetch tasks.
    private var artworkTaskKey: String?
    private var artworkTask: Task<Void, Never>?
    private var lastPublishedState: MonitorNowPlayingState?

    init(
        monitor: NowPlayingMonitor? = nil,
        artworkFetcher: NowPlayingArtworkFetcher? = nil,
        audioReactive: Bool = true,
        audioDemand: (@MainActor @Sendable (Bool) -> Void)? = nil,
        positionProvider: PositionProvider? = nil,
        positionPollInterval: Duration = NowPlayingSource.defaultPositionPollInterval
    ) {
        monitorOverride = monitor
        fetcher = artworkFetcher ?? .shared
        self.audioReactive = audioReactive
        self.audioDemand = audioDemand ?? Self.defaultAudioDemand
        self.positionProvider = positionProvider ?? Self.defaultPositionProvider
        self.positionPollInterval = positionPollInterval
    }

    // MARK: - Playhead polling (players whose notification omits the position)

    /// Reads a player's playhead in seconds, or nil if it cannot be read.
    typealias PositionProvider = @MainActor @Sendable (String) async -> Double?

    /// 5 s: one Apple Event per 5 s while a track is up, only while an overlay is alive.
    static let defaultPositionPollInterval: Duration = .seconds(5)

    private let positionProvider: PositionProvider
    private let positionPollInterval: Duration
    private var positionTask: Task<Void, Never>?
    /// The *track* the poll loop is asking about, not just the player: keying on the player alone left the
    /// loop untouched across an in-app skip — no leading tick, so the bar stayed blank until the next
    /// interval — and let an in-flight reply for the previous song land on the new one.
    private var positionPollKey: String?

    private static let defaultPositionProvider: PositionProvider = { bundleID in
        await NowPlayingController.shared.value(for: .playerPosition, from: bundleID)?.doubleValue
    }

    /// Only players whose mapping carries no position key need this — the rest
    /// already put the playhead in every notification, and asking twice would
    /// spend an Apple Event to learn what we were just told.
    private static func needsPositionPolling(_ state: MonitorNowPlayingState) -> Bool {
        guard state.isSystemMedia != true || state.position == nil,
              state.phase.hasTrack, let bundleID = state.playerBundleID,
              let mapping = NowPlayingMonitor.mappings.first(where: { $0.bundleID == bundleID }) else {
            return false
        }
        return mapping.positionKey == nil
    }

    private func syncPositionPolling(for state: MonitorNowPlayingState, needed: Bool) {
        guard needed,
              let bundleID = state.playerBundleID,
              let key = NowPlayingArtworkFetcher.trackKey(for: state)
        else {
            stopPositionPolling()
            return
        }
        guard positionPollKey != key else { return }
        stopPositionPolling()
        positionPollKey = key
        let interval = positionPollInterval
        let provider = positionProvider
        positionTask = Task { [weak self] in
            // Leading tick: the bar should appear on the track change, not one
            // interval into the song.
            while !Task.isCancelled {
                // Stamped before the round trip, not after: an Apple Event is synchronous IPC, so a
                // reply already in flight when the user scrubbed would otherwise land with a *newer*
                // timestamp than the scrub — exactly the test the widget uses to decide the player moved
                // on, snapping the bar back to before the drag.
                let issuedAt = Date().timeIntervalSince1970
                let seconds = await provider(bundleID)
                guard !Task.isCancelled else { return }
                await self?.applyPolledPosition(seconds, key: key, sampledAt: issuedAt)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func stopPositionPolling() {
        positionTask?.cancel()
        positionTask = nil
        positionPollKey = nil
    }

    /// Same token discipline as the artwork landing: a reply for a track that is
    /// no longer on screen must not be written into whatever replaced it.
    private func applyPolledPosition(_ seconds: Double?, key: String, sampledAt: Double) async {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return }
        guard let sink, positionPollKey == key else { return }
        guard var state = lastPublishedState,
              NowPlayingArtworkFetcher.trackKey(for: state) == key else { return }
        state.position = state.duration.map { min(seconds, $0) } ?? seconds
        state.positionSampledAt = sampledAt
        lastPublishedState = state
        await sink.updateNowPlaying(state)
    }

    /// Whether any placed layer still draws the reactive effects. Retaining the
    /// capture tap regardless would run the FFT for nobody.
    private let audioReactive: Bool

    private static let defaultAudioDemand: @MainActor @Sendable (Bool) -> Void = { wanted in
        #if !LITE_BUILD
            if wanted {
                SystemAudioCaptureManager.shared.retain()
            } else {
                SystemAudioCaptureManager.shared.release()
            }
        #endif
    }

    func start(sink: any MonitorSnapshotSink) async {
        self.sink = sink
        let id = subscriptionID
        let startGeneration = generation
        let forward: @Sendable (UInt64, MonitorNowPlayingState) -> Void = { [weak self] ordinal, state in
            guard let self else { return }
            Task { await self.push(state, ordinal: ordinal, sourceGeneration: startGeneration) }
        }
        let override = monitorOverride
        let subscribedMonitor = await MainActor.run { () -> NowPlayingMonitor in
            let monitor = override ?? NowPlayingMonitor.shared
            monitor.subscribe(id: id, handler: forward)
            return monitor
        }
        guard generation == startGeneration else {
            await MainActor.run { subscribedMonitor.unsubscribe(id: id) }
            return
        }
        monitor = subscribedMonitor
    }

    func stop() async {
        generation &+= 1
        let id = subscriptionID
        subscriptionID = UUID()
        let retiredMonitor = monitor
        monitor = nil
        sink = nil
        stopPositionPolling()
        artworkTask?.cancel()
        artworkTask = nil
        artworkTaskKey = nil
        currentTrackKey = nil
        lastPublishedState = nil
        // A reused instance must not let the old ordinal swallow the next
        // subscribe replay.
        lastForwardedOrdinal = nil
        await setAudioDemand(false)
        guard let retiredMonitor else { return }
        await MainActor.run { retiredMonitor.unsubscribe(id: id) }
    }

    private func push(_ state: MonitorNowPlayingState, ordinal: UInt64, sourceGeneration: UInt64) async {
        // MainActor→actor hops are unordered; the ordinal drops a stale frame. Re-read generation after every suspension so an interleaved stop() wins.
        let gen = generation
        guard generation == sourceGeneration, let sink else { return }
        if let last = lastForwardedOrdinal, ordinal <= last { return }
        lastForwardedOrdinal = ordinal

        // Claiming the ordinal above isn't enough: this actor suspends below, and a newer frame can publish
        // during the suspension. Every resume re-checks this frame is still the newest, or it would
        // overwrite the newer state — and drive audio demand from a stale phase.
        func stillCurrent() -> Bool { generation == gen && lastForwardedOrdinal == ordinal }

        var state = state
        // nil for the no-track phases (empty title) — those never touch the
        // network and clear the token so any in-flight artwork is orphaned.
        let key = NowPlayingArtworkFetcher.trackKey(for: state)
        if key != currentTrackKey {
            currentTrackKey = key
            artworkTask?.cancel()
            artworkTask = nil
            artworkTaskKey = nil
        }
        if let key, state.artwork == nil,
           NowPlayingArtworkRoute.all.contains(where: { $0.bundleID == state.playerBundleID }) {
            let cached = await fetcher.cachedArtwork(forKey: key)
            guard stillCurrent() else { return }
            if let cached {
                state.artwork = cached
            } else if artworkTaskKey != key {
                // Publish the text-only state below without waiting for the
                // image; the fetch re-publishes an enriched state on landing.
                artworkTaskKey = key
                let fetcher = fetcher
                // Copy: capturing the mutable `state` would hand the escaping
                // task the variable itself, which this scope keeps using below.
                let pending = state
                artworkTask = Task { [weak self] in
                    let data = await fetcher.artwork(for: pending)
                    guard !Task.isCancelled else { return }
                    await self?.finishArtworkFetch(data, key: key)
                }
            }
        }
        guard stillCurrent() else { return }
        // Carry the polled playhead across the notification that replaced it:
        // Music re-sends full metadata on a bare state change, and rebuilding
        // the state from it would blank the bar every time the user paused.
        let needsPositionPolling = Self.needsPositionPolling(state)
        if state.position == nil,
           let key = NowPlayingArtworkFetcher.trackKey(for: state),
           positionPollKey == key,
           let previous = lastPublishedState,
           NowPlayingArtworkFetcher.trackKey(for: previous) == key,
           let carried = previous.position {
            state.position = carried
            state.positionSampledAt = previous.positionSampledAt
        }
        lastPublishedState = state
        await sink.updateNowPlaying(state)
        guard stillCurrent() else { return }
        syncPositionPolling(for: state, needed: needsPositionPolling)
        await setAudioDemand(audioReactive && state.phase == .playing)
    }

    /// Bumped by stop(); an in-flight push must never publish or flip audio
    /// demand once its generation is stale.
    private var generation: UInt64 = 0

    /// At most one retain per source; balanced on phase change and stop().
    private let audioDemand: @MainActor @Sendable (Bool) -> Void
    private var audioDemandHeld = false

    private func setAudioDemand(_ wanted: Bool) async {
        guard wanted != audioDemandHeld else { return }
        audioDemandHeld = wanted
        await audioDemand(wanted)
    }

    /// Clear the per-track fetch token on any outcome; a leftover set token would make a miss permanent. Safe because the fetcher keeps its own TTL'd negative cache.
    private func finishArtworkFetch(_ data: Data?, key: String) async {
        if artworkTaskKey == key { artworkTaskKey = nil }
        guard let data else { return }
        await applyFetchedArtwork(data, key: key)
    }

    private func applyFetchedArtwork(_ data: Data, key: String) async {
        // A slow response for a previous track, or one landing after stop(), must never publish.
        guard let sink, key == currentTrackKey else { return }
        guard var state = lastPublishedState, state.artwork == nil else { return }
        state.artwork = data
        lastPublishedState = state
        await sink.updateNowPlaying(state)
    }
}

#if !LITE_BUILD
struct NowPlayingSystemSnapshot: Decodable, Sendable {
    var bundleID: String?
    var title: String?
    var artist: String?
    var album: String?
    var trackID: String?
    var artworkID: String?
    var playing: Bool
    var duration: Double?
    var position: Double?
    var timestamp: Double?
    var rate: Double?
    var artwork: String?
    var controlID: String?
    var commands: [Int]?
    var mediaKind: String?
    var origin: String?

    var identity: String {
        let fields = [bundleID, trackID, title, artist, album, artworkID].map { $0 ?? "" }
        let bytes = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private var stableTrackID: String {
        if let trackID, !trackID.isEmpty, trackID.utf8.count <= 4096 {
            if bundleID == "com.spotify.client", NowPlayingArtworkFetcher.spotifyOEmbedURL(trackID: trackID) != nil {
                return trackID
            }
            return "system:\(bundleID ?? ""):\(trackID)"
        }
        let fields = [bundleID, title, artist, album].map { $0 ?? "" }
        let bytes = (try? JSONEncoder().encode(fields)) ?? Data()
        return "system:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func state(now: Double = Date().timeIntervalSince1970) -> MonitorNowPlayingState? {
        guard let bundleID, !bundleID.isEmpty, bundleID.utf8.count <= 512,
              let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 16384 else { return nil }
        var state = MonitorNowPlayingState(phase: playing ? .playing : .paused, title: title)
        state.playerBundleID = bundleID
        state.artist = artist?.isEmpty == false ? artist : nil
        state.album = album?.isEmpty == false ? album : nil
        state.trackID = stableTrackID
        state.isSystemMedia = true
        state.systemPlayerID = controlID.flatMap { !$0.isEmpty && $0.utf8.count <= 4096 ? $0 : nil }
        state.systemCommands = commands.map { Array(Set($0.filter { [0, 1, 2, 4, 5].contains($0) })).sorted() }
        state.mediaKind = mediaKind.flatMap(MonitorNowPlayingMediaKind.init(rawValue:))
        state.mediaOrigin = origin.flatMap(MonitorNowPlayingMediaOrigin.init(rawValue:))
        state.duration = duration.flatMap { $0.isFinite && $0 > 0 && $0 <= 604_800 ? $0 : nil }
        state.playbackRate = rate.flatMap { $0.isFinite && $0 >= 0 && $0 <= 16 ? $0 : nil }
        if let position, position.isFinite, position >= 0 {
            state.position = state.duration.map { min(position, $0) } ?? position
            if let timestamp, timestamp.isFinite, timestamp <= now + 2,
               now - timestamp <= 86400 {
                let speed = state.effectivePlaybackRate
                let advanced = position + (playing ? max(0, now - timestamp) * speed : 0)
                if playing, let duration = state.duration, advanced > duration + 2 {
                    state.position = nil
                } else if speed == 1 {
                    state.positionSampledAt = timestamp
                } else {
                    state.position = state.duration.map { min(advanced, $0) } ?? advanced
                    state.positionSampledAt = now
                }
            }
        }
        return state
    }
}

actor NowPlayingSystemBridge {
    static let shared = NowPlayingSystemBridge()
    typealias Query = @Sendable (Bool) async throws -> Data
    private let query: Query
    private var artworkKey: String?
    private var artwork: Data?
    private var artworkTrack: [String]?
    /// false = `artwork` is nil or belongs to an older artwork identifier of the same track.
    private var artworkIsCurrent = false
    private var lastArtworkAttempt = Date.distantPast

    init(query: Query? = nil) {
        self.query = query ?? Self.querySystem
    }

    private static func querySystem(artwork: Bool) async throws -> Data {
        let arguments = ["-l", "JavaScript", "-e", script] + (artwork ? ["artwork"] : [])
        return try await NowPlayingSystemProcess().run(arguments: arguments)
    }

    enum ControlFailure: Error { case rejected }

    /// Submission is not a player acknowledgement; subsequent snapshots report the actual state.
    static func send(command: Int, playerID: String) async throws {
        struct Reply: Decodable { let submitted: Bool }
        let data = try await NowPlayingSystemProcess().run(arguments: ["-l", "JavaScript", "-e", script, "command", playerID, String(command)])
        guard try JSONDecoder().decode(Reply.self, from: data).submitted else { throw ControlFailure.rejected }
    }

    func snapshot() async throws -> MonitorNowPlayingState? {
        let raw = try await query(false)
        let snapshot = try JSONDecoder().decode(NowPlayingSystemSnapshot.self, from: raw)
        guard var state = snapshot.state() else {
            artworkKey = nil
            artworkTrack = nil
            artwork = nil
            return nil
        }
        if artworkKey != snapshot.identity {
            artworkKey = snapshot.identity
            // A same-track artwork revision keeps the old cover on screen until the new one lands.
            artworkIsCurrent = false
            let track = [state.trackID, state.title, state.artist, state.album].map { $0 ?? "" }
            if artworkTrack != track {
                artwork = nil
            }
            artworkTrack = track
            lastArtworkAttempt = .distantPast
        } else if !artworkIsCurrent, Date().timeIntervalSince(lastArtworkAttempt) >= 30 {
            lastArtworkAttempt = Date()
            do {
                let bytes = try await query(true)
                let enriched = try JSONDecoder().decode(NowPlayingSystemSnapshot.self, from: bytes)
                guard enriched.identity == snapshot.identity, artworkKey == snapshot.identity else { return state }
                if let encoded = enriched.artwork, encoded.utf8.count <= 2_796_204,
                   let data = Data(base64Encoded: encoded), !data.isEmpty,
                   data.count <= NowPlayingArtworkFetcher.maxImageBytes {
                    artwork = data
                    artworkIsCurrent = true
                }
            } catch {
                try Task.checkCancellation()
            }
        }
        state.artwork = artwork
        return state
    }

    static let script = #"""
    ObjC.import('Foundation');
    function nil(x) { return !x || x.isNil(); }
    function text(x) { return nil(x) ? null : String(ObjC.unwrap(x)).slice(0,4096); }
    function run(args) {
        const framework=$.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework');
        if (nil(framework) || !framework.load) throw Error('MediaRemote unavailable');
        const Request=$.NSClassFromString('MRNowPlayingRequest');
        if (nil(Request)) throw Error('Now Playing unavailable');
        const path=Request.localNowPlayingPlayerPath, item=Request.localNowPlayingItem;
        const client=nil(path)?null:path.client, info=nil(item)?null:item.nowPlayingInfo;
        function field(key) { return nil(info)?null:info.objectForKey('kMRMediaRemoteNowPlayingInfo'+key); }
        function number(key) { const x=field(key); if(nil(x))return null; const n=Number(ObjC.unwrap(x)); return isFinite(n)?n:null; }
        const date=field('Timestamp');
        const out={
            bundleID:nil(client)?null:(text(client.parentApplicationBundleIdentifier)||text(client.bundleIdentifier)),
            playing:Boolean(Request.localIsPlaying), title:text(field('Title')),
            artist:text(field('Artist')), album:text(field('Album')),
            trackID:text(field('ContentItemIdentifier')), artworkID:text(field('ArtworkIdentifier')),
            duration:number('Duration'), position:number('ElapsedTime'), rate:number('PlaybackRate'),
            timestamp:nil(date)?null:Number(date.timeIntervalSince1970)
        };
        out.controlID=nil(path)?null:JSON.stringify([out.bundleID,text(client.bundleIdentifier),Number(client.processIdentifier),text(path.player.identifier)]);
        const supported=Request.respondsToSelector($.NSSelectorFromString('localSupportedCommands'))?Request.localSupportedCommands:null;
        out.commands=nil(supported)?null:[];
        if(!nil(supported))for(let i=0;i<Math.min(Number(supported.count),128);i++) {
            const entry=supported.objectAtIndex(i), command=Number(entry.command);
            if(Boolean(entry.isEnabled)&&[0,1,2,4,5].includes(command))out.commands.push(command);
        }
        const skip=field('ProhibitsSkip');
        if(out.commands&&!nil(skip)&&Boolean(ObjC.unwrap(skip)))out.commands=out.commands.filter(x=>x!==4&&x!==5);
        const kind=text(field('MediaType'));
        out.mediaKind=kind==='kMRMediaRemoteNowPlayingInfoTypeAudio'?'audio':kind==='kMRMediaRemoteNowPlayingInfoTypeVideo'?'video':null;
        out.origin=null;
        const asset=field('AssetURL');
        if(!nil(asset)) {
            const url=asset.respondsToSelector($.NSSelectorFromString('scheme'))?asset:$.NSURL.URLWithString(asset);
            const scheme=nil(url)?null:(text(url.scheme)||'').toLowerCase();
            out.origin=scheme==='file'?'local':['http','https'].includes(scheme)?'web':null;
        }
        if(args[0]==='command') {
            const command=Number(args[2]);
            if(!out.title||!out.bundleID||out.controlID!==args[1]||!out.commands||!out.commands.includes(command))return JSON.stringify({submitted:false});
            const request=Request.alloc.initWithPlayerPath(path);
            if(!request.respondsToSelector($.NSSelectorFromString('sendCommand:options:queue:completion:')))return JSON.stringify({submitted:false});
            request.sendCommandOptionsQueueCompletion(command,$.NSDictionary.alloc.init,null,null);
            const until=Date.now()+200;
            while(Date.now()<until)$.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.02));
            return JSON.stringify({submitted:true});
        }
        if(!out.title || !out.bundleID || args[0]!=='artwork')return JSON.stringify(out);
        ObjC.bindFunction('objc_msgSend',['void',['id','selector','id','id']]);
        const request=Request.alloc.initWithPlayerPath(path);
        const callback=ObjC.block(['void',['id','id']],function(art,error){
            if(!nil(art)&&nil(error)) {
                const data=art.respondsToSelector($.NSSelectorFromString('imageData'))?art.imageData:art;
                if(!nil(data)&&Number(data.length)<=2097152)out.artwork=ObjC.unwrap(data.base64EncodedStringWithOptions(0));
            }
            out.artworkCompleted=true;
        });
        const holder=$.NSPredicate.predicateWithBlock(callback), block=holder.valueForKey('block');
        $.objc_msgSend(request,$.NSSelectorFromString('requestNowPlayingItemArtworkWithCompletion:'),block,null);
        const deadline=Date.now()+800;
        while(!out.artworkCompleted&&Date.now()<deadline)$.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.02));
        return JSON.stringify(out);
    }
    """#
}

/// The lock serializes launch/cancel; one run task owns the output file and exit readback.
final class NowPlayingSystemProcess: @unchecked Sendable {
    enum Failure: Error { case timedOut, outputTooLarge, exited(Int32) }
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false

    var isRunning: Bool {
        lock.withLock { process.isRunning }
    }

    func run(arguments: [String], timeout: Duration = .seconds(3), outputLimit: Int = 3 * 1024 * 1024) async throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("loomscreen-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("snapshot.json")
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        return try await withTaskCancellationHandler {
            defer {
                if isRunning {
                    cancel()
                }
            }
            try lock.withLock {
                guard !cancelled else { throw CancellationError() }
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = arguments
                process.standardOutput = file
                process.standardError = FileHandle.nullDevice
                try process.run()
            }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw Failure.timedOut }
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size <= outputLimit else { throw Failure.outputTooLarge }
                try await Task.sleep(for: .milliseconds(25))
            }
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else { throw Failure.exited(process.terminationStatus) }
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            let data = try reader.read(upToCount: outputLimit + 1) ?? Data()
            guard data.count <= outputLimit else { throw Failure.outputTooLarge }
            return data
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        let needsKill = lock.withLock {
            cancelled = true
            guard process.isRunning else { return false }
            process.terminate()
            return true
        }
        if needsKill {
            Task.detached { [self] in
                try? await Task.sleep(for: .milliseconds(250))
                lock.withLock {
                    if process.isRunning {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
    }
}
#endif
