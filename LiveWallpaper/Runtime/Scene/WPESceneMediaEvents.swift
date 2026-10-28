#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal

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
            delivered += max(0, now - sampledAt) * state.effectivePlaybackRate
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
    let textures: WPEMediaTextureStore.ParitySnapshot?
    /// Property key → generated system texture name; the host wraps each name in `{value: name}`.
    let systemProperties: [String: String]
    let events: [WPESceneMediaEvent]
    let diagnostics: [String]
}

/// `@unchecked Sendable`: every queue and loaded-consumer identity is accessed inside `lock`.
final class WPESceneMediaEventMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingParity: [WPESceneParityMediaInput] = []
    private var parityGeneration: Int?

    /// Called by the driver before preparing a load.
    func beginParityGeneration(_ generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard parityGeneration != generation else { return }
        parityGeneration = generation
        pendingParity.removeAll(keepingCapacity: true)
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
}

@MainActor
protocol WPENowPlayingEventSource: AnyObject {
    func subscribe(id: UUID, handler: @escaping @Sendable (UInt64, MonitorNowPlayingState) -> Void)
    func unsubscribe(id: UUID)
}

#if !SYSTEM_WALLPAPER_EXTENSION
extension NowPlayingMonitor: WPENowPlayingEventSource {}
#endif

@MainActor
final class WPESceneMediaEventDispatcher {
    let mailbox = WPESceneMediaEventMailbox()

    private let id = UUID()
    private let source: any WPENowPlayingEventSource
    private let now: @MainActor () -> Double
    private var palette = WPEMediaArtworkPaletteCache()
    private var lastOrdinal: UInt64?
    private var isSubscribed = false
    private var latest: MonitorNowPlayingState?

    private enum ParityArtworkIdentity: Equatable {
        case absent
        case empty
        case bytes(String)
    }

    /// The configured parity consumer; nil before `configureParity` and after `stop()`.
    private final class ParityState {
        var generation: Int
        var textureDemand: Bool
        var onChange: @Sendable () -> Void
        var store: WPEMediaTextureStore?
        var device: ObjectIdentifier?
        var gate = WPESceneMediaDiffGate()
        var hasPublished = false
        // Names follow raw observations; their upload bytes are retained only when qualified by the Mac decoder.
        var artworkIdentity: ParityArtworkIdentity?
        var currentArtwork: Data?
        var previousArtwork: Data?
        var currentSystemName: String?
        var previousSystemName: String?
        var artworkDiagnostics: [String] = []

        init(generation: Int, textureDemand: Bool, onChange: @escaping @Sendable () -> Void) {
            self.generation = generation
            self.textureDemand = textureDemand
            self.onChange = onChange
        }
    }

    private var parity: ParityState?
    /// Outlives `parity`: `stop()` does not restart the generated system texture names.
    private var parityArtworkRevision: UInt64 = 0

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
        let newConsumer = parity?.generation != generation
        let demandChanged = parity?.textureDemand != textureDemand
        let state = parity ?? ParityState(generation: generation, textureDemand: textureDemand, onChange: onChange)
        var newStore = false
        if textureDemand, let device {
            let identity = ObjectIdentifier(device)
            if state.store == nil || state.device != identity {
                state.store = WPEMediaTextureStore(device: device)
                state.device = identity
                newStore = true
            }
        }
        state.generation = generation
        state.textureDemand = textureDemand
        state.onChange = onChange
        parity = state
        if newConsumer {
            state.gate = WPESceneMediaDiffGate()
            state.hasPublished = false
        } else if demandChanged || newStore {
            state.hasPublished = false
        }
        start()
        _ = replayGeneration(generation)
        return mailbox.isParityGeneration(generation)
    }

    /// A normal reload needs a current-state delivery even when the source ordinal did not change.
    @discardableResult
    func replayGeneration(_ generation: Int) -> Bool {
        guard let parity, parity.generation == generation, mailbox.isParityGeneration(generation) else { return false }
        if parity.hasPublished {
            return true
        }
        guard let latest else { return false }
        return publishParity(state: latest, isReplay: true)
    }

    private func start() {
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
        if let parity {
            mailbox.invalidateParityGeneration(parity.generation)
            self.parity = nil
            latest = nil
        }
    }

    private func ingest(ordinal: UInt64, state: MonitorNowPlayingState) {
        // The ordinal lets a late hop be dropped rather than rewinding the scene.
        if let lastOrdinal, ordinal < lastOrdinal {
            return
        }
        lastOrdinal = ordinal
        latest = state
        _ = publishParity(state: state, isReplay: false)
    }

    @discardableResult
    private func publishParity(state: MonitorNowPlayingState, isReplay: Bool) -> Bool {
        guard let parity, state.phase != .awaitingFirstEvent else { return false }
        var thumbnail = palette.thumbnail(for: state.artwork)
        let artworkChanged = updateParityArtwork(parity, artwork: state.artwork, thumbnail: thumbnail)
        var diagnostics = parity.artworkDiagnostics
        let hasRawArtwork = state.artwork?.isEmpty == false
        if hasRawArtwork, !thumbnail.hasThumbnail {
            // Native hasThumbnail tests the byte range, not whether colour analysis found opaque samples.
            thumbnail.hasThumbnail = true
            diagnostics.append("media.artwork-palette-unavailable-native-colors-unverified")
        }
        let snapshot = WPESceneMediaSnapshot(
            state, thumbnail: thumbnail, timeline: WPESceneMediaTimeline.interpolated(from: state, now: now())
        )
        // While a replacement load prepares, keep the source's pair current for its eventual seed, but do not
        // upload or dispatch on behalf of the previous, no longer admitted consumer.
        guard mailbox.isParityGeneration(parity.generation) else { return false }
        var textures = WPEMediaTextureStore.ParitySnapshot(
            revision: parityArtworkRevision, current: nil, previous: nil,
            currentSystemName: parity.currentSystemName, previousSystemName: parity.previousSystemName
        )
        if parity.textureDemand, let store = parity.store {
            let uploaded = store.paritySnapshot(
                revision: parityArtworkRevision,
                currentArtwork: parity.currentArtwork, previousArtwork: parity.previousArtwork,
                currentSystemName: parity.currentSystemName, previousSystemName: parity.previousSystemName
            )
            textures = uploaded.snapshot
            diagnostics += uploaded.diagnostics
        }
        var events = parity.gate.events(for: snapshot)
        // 140172830:253–272 only seeds an initial thumbnail when image bytes exist.
        if !parity.hasPublished, !snapshot.thumbnail.hasThumbnail {
            events.removeAll {
                if case .thumbnailChanged = $0 {
                    true
                } else {
                    false
                }
            }
        }
        if artworkChanged, hasRawArtwork,
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
        if isReplay || artworkChanged || !parity.hasPublished {
            properties["$mediaThumbnail"] = parity.currentSystemName
            properties["$mediaPreviousThumbnail"] = parity.previousSystemName
        }
        let input = WPESceneParityMediaInput(generation: parity.generation, textures: textures,
                                             systemProperties: properties, events: events,
                                             diagnostics: diagnostics)
        guard mailbox.postParityInput(input) else { return false }
        parity.hasPublished = true
        parity.onChange()
        return true
    }

    private func updateParityArtwork(_ parity: ParityState, artwork: Data?, thumbnail: WPESceneMediaThumbnail) -> Bool {
        let identity: ParityArtworkIdentity = if let artwork {
            artwork.isEmpty ? .empty : .bytes(WPEMediaArtworkPaletteCache.identity(of: artwork))
        } else {
            .absent
        }
        guard identity != parity.artworkIdentity else { return false }
        parity.artworkIdentity = identity
        parityArtworkRevision &+= 1
        // 140171440:213–387 rotates raw identities before decode, including an artwork change to an empty range.
        parity.previousSystemName = parity.currentSystemName
        parity.currentSystemName = "mediaThumbnail_\(parityArtworkRevision).system"
        parity.previousArtwork = parity.currentArtwork
        if let artwork, !artwork.isEmpty,
           thumbnail.hasThumbnail || WPEMediaTextureStore.hasDecodableParityArtwork(artwork) {
            parity.currentArtwork = artwork
            parity.artworkDiagnostics = []
        } else {
            // This observation still has a raw name. Only its Mac upload qualification fails; the previous
            // observation keeps its own qualified bytes/name, without claiming Windows' factory result.
            parity.currentArtwork = nil
            let reason = switch identity {
            case .absent: "absent"
            case .empty: "empty"
            case .bytes: "undecodable"
            }
            parity.artworkDiagnostics = ["media.artwork-\(reason)-native-behavior-unverified"]
        }
        return true
    }
}
#endif
