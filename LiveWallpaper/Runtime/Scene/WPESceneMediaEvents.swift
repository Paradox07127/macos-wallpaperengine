#if !LITE_BUILD
import Foundation
import JavaScriptCore
import LiveWallpaperProWPE
import Metal

#if DEBUG
enum WPEOracleMediaSnapshotError: Error, Equatable {
    case loadAlreadyStarted
    case invalidSnapshot
}

struct WPEOracleMediaInputReceipt: Encodable, Sendable, Equatable {
    let mode = "oracle-frozen"
    let source = "per-renderer-frozen-source"
    let scope = "source-subscription-replay-not-vm-completion"
    let generation: Int
    let sourceOrdinal: UInt64?
    let replayCount: Int
    let scriptSubscriptionCreated: Bool
    let textureSubscriptionCreated: Bool
    let interpolationNow: Double
    let state: MonitorNowPlayingState
}

@MainActor
final class WPEOracleFrozenNowPlayingSource: WPENowPlayingEventSource {
    let state: MonitorNowPlayingState
    private(set) var replayCount = 0
    private var subscribers: Set<UUID> = []
    var subscriberCount: Int {
        subscribers.count
    }

    var interpolationNow: Double {
        state.positionSampledAt ?? 0
    }

    init(state: MonitorNowPlayingState) {
        self.state = state
    }

    nonisolated static func validate(_ state: MonitorNowPlayingState) throws {
        let strings = [state.title, state.artist, state.album, state.trackID, state.playerBundleID]
        guard state.phase != .awaitingFirstEvent,
              strings.compactMap(\.self).allSatisfy({ $0.utf8.count <= 4096 }),
              (state.artwork?.count ?? 0) <= 1_048_576 else {
            throw WPEOracleMediaSnapshotError.invalidSnapshot
        }
        if state.phase == .noPlayer {
            guard state.title.isEmpty, (state.artist ?? "").isEmpty, (state.album ?? "").isEmpty,
                  state.duration == nil, state.position == nil, state.positionSampledAt == nil,
                  state.artwork == nil else { throw WPEOracleMediaSnapshotError.invalidSnapshot }
        } else if state.title.isEmpty {
            throw WPEOracleMediaSnapshotError.invalidSnapshot
        }
        switch (state.duration, state.position) {
        case (nil, nil):
            guard state.positionSampledAt == nil else { throw WPEOracleMediaSnapshotError.invalidSnapshot }
        case let (duration?, position?):
            guard duration.isFinite, position.isFinite, duration >= 0, position >= 0,
                  position <= duration, state.positionSampledAt?.isFinite != false else {
                throw WPEOracleMediaSnapshotError.invalidSnapshot
            }
        default: throw WPEOracleMediaSnapshotError.invalidSnapshot
        }
    }

    func subscribe(id: UUID, handler: @escaping @Sendable (UInt64, MonitorNowPlayingState) -> Void) {
        subscribers.insert(id)
        replayCount += 1
        handler(1, state)
    }

    func unsubscribe(id: UUID) {
        subscribers.remove(id)
    }

    func receipt(generation: Int, scripts: Bool, textures: Bool) -> WPEOracleMediaInputReceipt {
        WPEOracleMediaInputReceipt(
            generation: generation, sourceOrdinal: replayCount > 0 ? 1 : nil, replayCount: replayCount,
            scriptSubscriptionCreated: scripts, textureSubscriptionCreated: textures,
            interpolationNow: interpolationNow, state: state
        )
    }
}
#endif

/// The frozen `MediaPlaybackEvent` constants installed by
/// `WPESceneScriptBaseclasses`. Raw values are the contract, not an enum order.
enum WPESceneMediaPlaybackState: Int, Sendable, Equatable {
    case stopped = 0
    case playing = 1
    case paused = 2
}

/// Every field is a String on the JS side; fields we cannot source stay empty strings rather than becoming undefined.
struct WPESceneMediaProperties: Sendable, Equatable {
    var title: String = ""
    var artist: String = ""
    var subTitle: String = ""
    var albumTitle: String = ""
    var albumArtist: String = ""
    var genres: String = ""
    var contentType: String = ""
}

/// `mediaTimelineChanged`'s event payload: the two `Number` members the official
/// `lib.sceneScript.d.ts` declares, both in seconds.
struct WPESceneMediaTimeline: Sendable, Equatable {
    var position: Double
    var duration: Double

    /// nil when the player reported no position or no duration — the handler isn't called then; zeros would paint a live-looking 0:00 / 0:00.
    static func interpolated(
        from state: MonitorNowPlayingState,
        now: Double
    ) -> WPESceneMediaTimeline? {
        guard let duration = state.duration, let position = state.position else { return nil }
        var delivered = position
        // Only advance interpolated position while playing — a paused track's position is exact.
        if state.phase == .playing, let sampledAt = state.positionSampledAt {
            delivered += max(0, now - sampledAt)
        }
        return WPESceneMediaTimeline(
            position: min(delivered, duration),
            duration: duration
        )
    }
}

enum WPESceneMediaEvent: Sendable, Equatable {
    case playbackChanged(WPESceneMediaPlaybackState)
    /// nil = no player; the payload carries no fields, so a script keeps its own track name.
    case propertiesChanged(WPESceneMediaProperties?)
    case thumbnailChanged(WPESceneMediaThumbnail)
    case timelineChanged(WPESceneMediaTimeline)

    var handlerName: String {
        switch self {
        case .playbackChanged: "mediaPlaybackChanged"
        case .propertiesChanged: "mediaPropertiesChanged"
        case .thumbnailChanged: "mediaThumbnailChanged"
        case .timelineChanged: "mediaTimelineChanged"
        }
    }
}

extension [WPESceneMediaEvent] {
    /// One pending entry per handler: a newer event replaces the older one in place.
    mutating func coalesce(_ event: WPESceneMediaEvent) {
        if let index = firstIndex(where: { $0.handlerName == event.handlerName }) {
            self[index] = event
        } else {
            append(event)
        }
    }
}

struct WPESceneMediaHandlerSet: Sendable, Equatable {
    var playback = false
    var properties = false
    var thumbnail = false
    var timeline = false

    init() {}

    init(in context: JSContext) {
        playback = wpeExportsFunction(named: "mediaPlaybackChanged", in: context)
        properties = wpeExportsFunction(named: "mediaPropertiesChanged", in: context)
        thumbnail = wpeExportsFunction(named: "mediaThumbnailChanged", in: context)
        timeline = wpeExportsFunction(named: "mediaTimelineChanged", in: context)
    }

    func handles(_ event: WPESceneMediaEvent) -> Bool {
        switch event {
        case .playbackChanged: playback
        case .propertiesChanged: properties
        case .thumbnailChanged: thumbnail
        case .timelineChanged: timeline
        }
    }
}

struct WPESceneMediaSnapshot: Sendable, Equatable {
    var state: WPESceneMediaPlaybackState
    var properties: WPESceneMediaProperties?
    var thumbnail: WPESceneMediaThumbnail
    var timeline: WPESceneMediaTimeline?
    /// Distinguishes "the source has not reported yet" from a real stop, which
    /// `state` alone flattens. Only the diff gate reads it — handlers never see it.
    var isAwaitingFirstEvent: Bool = false

    init(
        state: WPESceneMediaPlaybackState,
        properties: WPESceneMediaProperties?,
        thumbnail: WPESceneMediaThumbnail = .absent,
        timeline: WPESceneMediaTimeline? = nil,
        isAwaitingFirstEvent: Bool = false
    ) {
        self.state = state
        self.properties = properties
        self.thumbnail = thumbnail
        self.timeline = timeline
        self.isAwaitingFirstEvent = isAwaitingFirstEvent
    }

    /// awaitingFirstEvent has no PLAYBACK_* counterpart, so it borrows .stopped and carries isAwaitingFirstEvent for the diff gate to suppress on.
    init(
        _ state: MonitorNowPlayingState,
        thumbnail: WPESceneMediaThumbnail = .absent,
        timeline: WPESceneMediaTimeline? = nil
    ) {
        switch state.phase {
        case .playing: self.state = .playing
        case .paused: self.state = .paused
        case .noPlayer, .awaitingFirstEvent: self.state = .stopped
        }
        isAwaitingFirstEvent = state.phase == .awaitingFirstEvent
        properties = self.state == .stopped ? nil : WPESceneMediaProperties(
            title: state.title,
            artist: state.artist ?? "",
            albumTitle: state.album ?? ""
        )
        self.thumbnail = thumbnail
        self.timeline = timeline
    }
}

func wpeMediaEventObject(_ event: WPESceneMediaEvent, in context: JSContext) -> JSValue {
    guard let object = JSValue(newObjectIn: context) else {
        return JSValue(undefinedIn: context) ?? JSValue(nullIn: context)!
    }
    switch event {
    case let .playbackChanged(state):
        object.setObject(state.rawValue, forKeyedSubscript: "state" as NSString)
    case let .thumbnailChanged(thumbnail):
        object.setObject(thumbnail.hasThumbnail, forKeyedSubscript: "hasThumbnail" as NSString)
        object.setObject(wpeVec3(thumbnail.primaryColor, in: context), forKeyedSubscript: "primaryColor" as NSString)
        object.setObject(wpeVec3(thumbnail.secondaryColor, in: context), forKeyedSubscript: "secondaryColor" as NSString)
        object.setObject(wpeVec3(thumbnail.tertiaryColor, in: context), forKeyedSubscript: "tertiaryColor" as NSString)
        object.setObject(wpeVec3(thumbnail.textColor, in: context), forKeyedSubscript: "textColor" as NSString)
        object.setObject(
            wpeVec3(thumbnail.highContrastColor, in: context),
            forKeyedSubscript: "highContrastColor" as NSString
        )
    case let .timelineChanged(timeline):
        object.setObject(timeline.position, forKeyedSubscript: "position" as NSString)
        object.setObject(timeline.duration, forKeyedSubscript: "duration" as NSString)
    case .propertiesChanged(nil):
        break
    case let .propertiesChanged(properties?):
        object.setObject(properties.title, forKeyedSubscript: "title" as NSString)
        object.setObject(properties.artist, forKeyedSubscript: "artist" as NSString)
        object.setObject(properties.subTitle, forKeyedSubscript: "subTitle" as NSString)
        object.setObject(properties.albumTitle, forKeyedSubscript: "albumTitle" as NSString)
        object.setObject(properties.albumArtist, forKeyedSubscript: "albumArtist" as NSString)
        object.setObject(properties.genres, forKeyedSubscript: "genres" as NSString)
        object.setObject(properties.contentType, forKeyedSubscript: "contentType" as NSString)
    }
    return object
}

/// Colours must arrive as real Vec3 instances, not plain {x,y,z} bags: corpus scenes call vector methods on them.
private func wpeVec3(_ value: SIMD3<Double>, in context: JSContext) -> JSValue {
    if let constructor = context.objectForKeyedSubscript("Vec3"),
       !constructor.isUndefined,
       let vector = constructor.construct(withArguments: [value.x, value.y, value.z]) {
        return vector
    }
    // Only reachable if the sandbox failed to install; components still read.
    guard let object = JSValue(newObjectIn: context) else {
        return JSValue(undefinedIn: context) ?? JSValue(nullIn: context)!
    }
    object.setObject(value.x, forKeyedSubscript: "x" as NSString)
    object.setObject(value.y, forKeyedSubscript: "y" as NSString)
    object.setObject(value.z, forKeyedSubscript: "z" as NSString)
    return object
}

func wpeExportsFunction(named name: String, in context: JSContext) -> Bool {
    guard let value = context.objectForKeyedSubscript(name) else { return false }
    return !value.isUndefined && value.hasProperty("call")
}

/// Force events on the first delivery after load, then send each only when its own fields moved.
struct WPESceneMediaDiffGate {
    private var delivered: WPESceneMediaSnapshot?

    mutating func events(for snapshot: WPESceneMediaSnapshot) -> [WPESceneMediaEvent] {
        guard let previous = delivered else {
            // awaitingFirstEvent is not an observation: send nothing and stay armed so the first real snapshot force-delivers.
            guard !snapshot.isAwaitingFirstEvent else { return [] }
            delivered = snapshot
            var events: [WPESceneMediaEvent] = [
                .playbackChanged(snapshot.state),
                .propertiesChanged(snapshot.properties),
                .thumbnailChanged(snapshot.thumbnail),
            ]
            if let timeline = snapshot.timeline {
                events.append(.timelineChanged(timeline))
            }
            return events
        }
        let delivered = previous
        self.delivered = snapshot
        var events: [WPESceneMediaEvent] = []
        if delivered.state != snapshot.state {
            events.append(.playbackChanged(snapshot.state))
        }
        if delivered.properties != snapshot.properties {
            events.append(.propertiesChanged(snapshot.properties))
        }
        // The extracted palette is the payload; two covers that extract to the same five colours do not re-fire.
        if delivered.thumbnail != snapshot.thumbnail {
            events.append(.thumbnailChanged(snapshot.thumbnail))
        }
        // Interpolated position moves on every source push while playing; losing data mid-track sends nothing rather than a zeroed timeline.
        if let timeline = snapshot.timeline, delivered.timeline != timeline {
            events.append(.timelineChanged(timeline))
        }
        return events
    }
}

/// One source observation for one loaded parity consumer. The uploaded texture pair is immutable and retained
/// with its events; a renderer must keep the textures it submits until their last GPU reader completes.
struct WPESceneParityMediaInput: Sendable {
    let generation: Int
    let sourceOrdinal: UInt64
    let isReplay: Bool
    let textures: WPEMediaTextureStore.ParitySnapshot?
    /// Property key → generated system texture name; the host wraps each name in `{value: name}`.
    let systemProperties: [String: String]
    let events: [WPESceneMediaEvent]
    let diagnostics: [String]
}

/// `@unchecked Sendable`: every queue and loaded-consumer identity is accessed inside `lock`.
final class WPESceneMediaEventMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [WPESceneMediaEvent] = []
    private var pendingParity: [WPESceneParityMediaInput] = []
    private var parityGeneration: Int?
    private var latestParityGeneration: Int?

    /// Called by the driver before preparing a load. A retired load ID cannot admit itself again.
    @discardableResult
    func beginParityGeneration(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if parityGeneration == generation {
            return true
        }
        if let latestParityGeneration, generation <= latestParityGeneration {
            return false
        }
        latestParityGeneration = generation
        parityGeneration = generation
        pendingParity.removeAll(keepingCapacity: true)
        return true
    }

    func isParityGeneration(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return parityGeneration == generation
    }

    func hasPendingParityInputs(generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return parityGeneration == generation && !pendingParity.isEmpty
    }

    @discardableResult
    func postParityInput(_ input: WPESceneParityMediaInput) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard parityGeneration == input.generation else { return false }
        pendingParity.append(input)
        return true
    }

    func drainParityInputs(generation: Int) -> [WPESceneParityMediaInput] {
        lock.lock()
        defer { lock.unlock() }
        guard parityGeneration == generation else { return [] }
        let inputs = pendingParity
        pendingParity.removeAll(keepingCapacity: true)
        return inputs
    }

    func invalidateParityGeneration(_ generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard parityGeneration == generation else { return }
        parityGeneration = nil
        pendingParity.removeAll(keepingCapacity: true)
    }

    func post(_ events: [WPESceneMediaEvent]) {
        guard !events.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        pending.append(contentsOf: events)
    }

    func drain() -> [WPESceneMediaEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return [] }
        let events = pending
        pending.removeAll(keepingCapacity: true)
        return events
    }
}

@MainActor
protocol WPENowPlayingEventSource: AnyObject {
    func subscribe(id: UUID, handler: @escaping @Sendable (UInt64, MonitorNowPlayingState) -> Void)
    func unsubscribe(id: UUID)
}

extension NowPlayingMonitor: WPENowPlayingEventSource {}

@MainActor
final class WPESceneMediaEventDispatcher {
    let mailbox = WPESceneMediaEventMailbox()

    private let id = UUID()
    private let source: any WPENowPlayingEventSource
    private let now: @MainActor () -> Double
    private var gate = WPESceneMediaDiffGate()
    private var palette = WPEMediaArtworkPaletteCache()
    private var lastOrdinal: UInt64?
    private var isSubscribed = false
    private var latest: (ordinal: UInt64, state: MonitorNowPlayingState)?

    private struct ParityConfiguration {
        let generation: Int
        let textureDemand: Bool
        let onChange: @Sendable () -> Void
    }

    private var parityConfiguration: ParityConfiguration?
    private var parityStore: WPEMediaTextureStore?
    private var parityDevice: ObjectIdentifier?
    private var parityGate = WPESceneMediaDiffGate()
    private var parityHasPublished = false

    private enum ParityArtworkIdentity: Equatable {
        case absent
        case empty
        case bytes(String)
    }

    // Names and source bytes belong to the observation, including script-only consumers without GPU demand.
    private var parityArtworkIdentity: ParityArtworkIdentity?
    private var parityArtworkRevision: UInt64 = 0
    private var parityCurrentArtwork: Data?
    private var parityPreviousArtwork: Data?
    private var parityCurrentSystemName: String?
    private var parityPreviousSystemName: String?
    private var parityArtworkDiagnostics: [String] = []

    nonisolated static func isNeeded(by document: WPESceneDocument) -> Bool {
        WPESceneScriptInstanceInventory.usesMediaAPI(in: document)
    }

    init(
        source: any WPENowPlayingEventSource,
        now: @escaping @MainActor () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.source = source
        self.now = now
    }

    /// Configures an already admitted load. One subscription feeds both the uploaded pair and its events.
    /// Reusing the dispatcher for a new consumer resets its event gate, not the artwork pair or upload identity.
    @discardableResult
    func configureParity(generation: Int, device: (any MTLDevice)?, textureDemand: Bool,
                         onChange: @escaping @Sendable () -> Void) -> Bool {
        guard mailbox.isParityGeneration(generation), !textureDemand || device != nil else { return false }
        let previous = parityConfiguration
        let newConsumer = previous?.generation != generation
        var newStore = false
        if textureDemand, let device {
            let identity = ObjectIdentifier(device)
            if parityStore == nil || parityDevice != identity {
                parityStore = WPEMediaTextureStore(device: device)
                parityDevice = identity
                newStore = true
            }
        }
        parityConfiguration = ParityConfiguration(generation: generation, textureDemand: textureDemand,
                                                  onChange: onChange)
        if newConsumer {
            parityGate = WPESceneMediaDiffGate()
            parityHasPublished = false
        } else if previous?.textureDemand != textureDemand || newStore {
            parityHasPublished = false
        }
        start()
        _ = replayGeneration(generation)
        return mailbox.isParityGeneration(generation)
    }

    /// A normal reload needs a current-state delivery even when the source ordinal did not change.
    @discardableResult
    func replayGeneration(_ generation: Int) -> Bool {
        guard let configuration = parityConfiguration, configuration.generation == generation,
              mailbox.isParityGeneration(generation) else { return false }
        if parityHasPublished {
            return true
        }
        guard let latest else { return false }
        return publishParity(ordinal: latest.ordinal, state: latest.state, isReplay: true)
    }

    func start() {
        guard !isSubscribed else { return }
        isSubscribed = true
        // `subscribe` replays the current state synchronously, which is what
        // forces the first delivery — a scene loaded mid-song starts correct.
        source.subscribe(id: id) { [weak self] ordinal, state in
            MainActor.assumeIsolated {
                guard let self, self.isSubscribed else { return }
                self.ingest(ordinal: ordinal, state: state)
            }
        }
    }

    func stop() {
        guard isSubscribed else { return }
        isSubscribed = false
        source.unsubscribe(id: id)
        if let configuration = parityConfiguration {
            mailbox.invalidateParityGeneration(configuration.generation)
            parityConfiguration = nil
            parityStore = nil
            parityDevice = nil
            parityHasPublished = false
            parityGate = WPESceneMediaDiffGate()
            parityArtworkIdentity = nil
            parityCurrentArtwork = nil
            parityPreviousArtwork = nil
            parityCurrentSystemName = nil
            parityPreviousSystemName = nil
            parityArtworkDiagnostics = []
            latest = nil
        }
    }

    private func ingest(ordinal: UInt64, state: MonitorNowPlayingState) {
        // The ordinal lets a late hop be dropped rather than rewinding the scene.
        if let lastOrdinal, ordinal < lastOrdinal {
            return
        }
        lastOrdinal = ordinal
        latest = (ordinal, state)
        if parityConfiguration != nil {
            _ = publishParity(ordinal: ordinal, state: state, isReplay: false)
            return
        }
        let snapshot = WPESceneMediaSnapshot(
            state,
            thumbnail: palette.thumbnail(for: state.artwork),
            timeline: WPESceneMediaTimeline.interpolated(from: state, now: now())
        )
        mailbox.post(gate.events(for: snapshot))
    }

    @discardableResult
    private func publishParity(ordinal: UInt64, state: MonitorNowPlayingState, isReplay: Bool) -> Bool {
        guard let configuration = parityConfiguration, state.phase != .awaitingFirstEvent else { return false }
        var thumbnail = palette.thumbnail(for: state.artwork)
        let artworkChanged = updateParityArtwork(state.artwork, thumbnail: thumbnail)
        var diagnostics = parityArtworkDiagnostics
        if parityCurrentArtwork != nil, !thumbnail.hasThumbnail {
            // Native hasThumbnail tests the byte range, not whether colour analysis found opaque samples.
            thumbnail.hasThumbnail = true
            diagnostics.append("media.artwork-palette-unavailable-native-colors-unverified")
        }
        let snapshot = WPESceneMediaSnapshot(
            state, thumbnail: thumbnail, timeline: WPESceneMediaTimeline.interpolated(from: state, now: now())
        )
        // While a replacement load prepares, keep the source's pair current for its eventual seed, but do not
        // upload or dispatch on behalf of the previous, no longer admitted consumer.
        guard mailbox.isParityGeneration(configuration.generation) else { return false }
        var textures = WPEMediaTextureStore.ParitySnapshot(
            revision: parityArtworkRevision, current: nil, previous: nil,
            currentSystemName: parityCurrentSystemName, previousSystemName: parityPreviousSystemName
        )
        if configuration.textureDemand, let parityStore {
            let uploaded = parityStore.paritySnapshot(
                revision: parityArtworkRevision, currentArtwork: parityCurrentArtwork,
                previousArtwork: parityPreviousArtwork, currentSystemName: parityCurrentSystemName,
                previousSystemName: parityPreviousSystemName
            )
            textures = uploaded.snapshot
            diagnostics += uploaded.diagnostics
        }
        var events = parityGate.events(for: snapshot)
        // 140172830:253–272 only seeds an initial thumbnail when image bytes exist.
        if !parityHasPublished, !snapshot.thumbnail.hasThumbnail {
            events.removeAll {
                if case .thumbnailChanged = $0 {
                    true
                } else {
                    false
                }
            }
        }
        if artworkChanged, parityCurrentArtwork != nil,
           !events.contains(where: {
               if case .thumbnailChanged = $0 {
                   true
               } else {
                   false
               }
           }) {
            // The legacy palette-only diff cannot distinguish different covers with identical colours.
            let timeline = events.firstIndex {
                if case .timelineChanged = $0 {
                    true
                } else {
                    false
                }
            } ?? events.count
            events.insert(.thumbnailChanged(snapshot.thumbnail), at: timeline)
        }
        guard isReplay || artworkChanged || !events.isEmpty else { return false }
        var properties: [String: String] = [:]
        if isReplay || artworkChanged || !parityHasPublished {
            properties["$mediaThumbnail"] = parityCurrentSystemName
            properties["$mediaPreviousThumbnail"] = parityPreviousSystemName
        }
        let input = WPESceneParityMediaInput(generation: configuration.generation, sourceOrdinal: ordinal,
                                             isReplay: isReplay, textures: textures,
                                             systemProperties: properties, events: events,
                                             diagnostics: diagnostics)
        guard mailbox.postParityInput(input) else { return false }
        parityHasPublished = true
        configuration.onChange()
        return true
    }

    private func updateParityArtwork(_ artwork: Data?, thumbnail: WPESceneMediaThumbnail) -> Bool {
        let identity: ParityArtworkIdentity = if let artwork {
            artwork.isEmpty ? .empty : .bytes(WPEMediaArtworkPaletteCache.identity(of: artwork))
        } else {
            .absent
        }
        guard identity != parityArtworkIdentity else { return false }
        parityArtworkIdentity = identity
        parityArtworkRevision &+= 1
        if let artwork, !artwork.isEmpty,
           thumbnail.hasThumbnail || WPEMediaTextureStore.hasDecodableParityArtwork(artwork) {
            parityPreviousArtwork = parityCurrentArtwork
            parityPreviousSystemName = parityCurrentSystemName
            parityCurrentArtwork = artwork
            parityCurrentSystemName = "mediaThumbnail_\(parityArtworkRevision).system"
            parityArtworkDiagnostics = []
        } else {
            // The native factory's empty/bad-image result is unknown. Break the qualified nonempty chain;
            // neither transparent nor authored fallback nor the old cover is asserted to be Windows' result.
            parityCurrentArtwork = nil
            parityPreviousArtwork = nil
            parityCurrentSystemName = nil
            parityPreviousSystemName = nil
            let reason = switch identity {
            case .absent: "absent"
            case .empty: "empty"
            case .bytes: "undecodable"
            }
            parityArtworkDiagnostics = ["media.artwork-\(reason)-native-behavior-unverified"]
        }
        return true
    }
}
#endif
