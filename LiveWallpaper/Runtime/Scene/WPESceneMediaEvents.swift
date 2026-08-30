#if !LITE_BUILD
import Foundation
import JavaScriptCore
import LiveWallpaperProWPE

// SceneScript media integration (GitHub issue #133). WPE has no `register*Listener` call and
// no `supports*` opt-in for Scene wallpapers: the engine looks up conventionally-named exported
// functions on each property script module and calls them (contract from the official
// `lib.sceneScript.d.ts`). `mediaPlaybackChanged`, `mediaPropertiesChanged`,
// `mediaThumbnailChanged` and `mediaTimelineChanged` are wired here (`mediaStatusChanged` is
// not: no installed scene binds it).

/// The frozen `MediaPlaybackEvent` constants installed by
/// `WPESceneScriptBaseclasses`. Raw values are the contract, not an enum order.
enum WPESceneMediaPlaybackState: Int, Sendable, Equatable {
    case stopped = 0
    case playing = 1
    case paused = 2
}

/// `mediaPropertiesChanged`'s event payload. Every field is a String on the JS
/// side; the docs state most players fill in only title and artist, so the
/// fields we cannot source stay empty strings rather than becoming `undefined`.
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

    /// nil when the player reported no position or no duration — the handler isn't called at
    /// all then. Docs are explicit that authors must cope ("Not all media players support this
    /// feature, make sure your wallpaper also works fine when this function is never called"),
    /// so silence is contract-compliant; sending zeros would paint a live-looking `0:00 / 0:00`
    /// progress bar out of data we don't have.
    static func interpolated(
        from state: MonitorNowPlayingState,
        now: Double
    ) -> WPESceneMediaTimeline? {
        guard let duration = state.duration, let position = state.position else { return nil }
        var delivered = position
        // Spotify reports position in its notification, Apple Music does not (a
        // 5s AppleScript poll fills it in), so a raw sample can be that stale.
        // Only advance it while playing — a paused track's position is exact.
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
    case propertiesChanged(WPESceneMediaProperties)
    case thumbnailChanged(WPESceneMediaThumbnail)
    case timelineChanged(WPESceneMediaTimeline)

    var handlerName: String {
        switch self {
        case .playbackChanged: return "mediaPlaybackChanged"
        case .propertiesChanged: return "mediaPropertiesChanged"
        case .thumbnailChanged: return "mediaThumbnailChanged"
        case .timelineChanged: return "mediaTimelineChanged"
        }
    }
}

/// Which media handlers one evaluated module actually exported. All three script
/// runtimes carry one of these so a script that exported nothing never costs a
/// queue crossing.
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
        case .playbackChanged: return playback
        case .propertiesChanged: return properties
        case .thumbnailChanged: return thumbnail
        case .timelineChanged: return timeline
        }
    }
}

/// What the source currently reports, in the shape the handlers receive. The
/// diff gate compares these, so anything not represented here cannot trigger a
/// redundant dispatch.
struct WPESceneMediaSnapshot: Sendable, Equatable {
    var state: WPESceneMediaPlaybackState
    var properties: WPESceneMediaProperties
    var thumbnail: WPESceneMediaThumbnail
    var timeline: WPESceneMediaTimeline?
    /// Distinguishes "the source has not reported yet" from a real stop, which
    /// `state` alone flattens. Only the diff gate reads it — handlers never see it.
    var isAwaitingFirstEvent: Bool = false

    init(
        state: WPESceneMediaPlaybackState,
        properties: WPESceneMediaProperties,
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

    /// `awaitingFirstEvent` has no PLAYBACK_* counterpart — WPE only calls
    /// `mediaPlaybackChanged` for real transitions — so it borrows `.stopped`
    /// and carries `isAwaitingFirstEvent` for the diff gate to suppress on.
    /// The thumbnail is passed in rather than derived here so the caller owns
    /// the decode cache.
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
        self.isAwaitingFirstEvent = state.phase == .awaitingFirstEvent
        self.properties = WPESceneMediaProperties(
            title: state.title,
            artist: state.artist ?? "",
            albumTitle: state.album ?? ""
        )
        self.thumbnail = thumbnail
        self.timeline = timeline
    }
}

/// Builds the handler's argument inside the script's own JSContext.
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
    case let .propertiesChanged(properties):
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

/// Colours must arrive as real `Vec3` instances, not plain `{x,y,z}` bags:
/// corpus scenes assign `event.primaryColor` straight into a transform value and
/// call vector methods on it (3326873240's colour script does
/// `oldColor.mix(newColor, t)` and returns the result).
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

/// Per-instance demand: WPE dispatches to whatever the module exported, so
/// presence in the evaluated context is the truth (the document-level text scan
/// only decides whether the scene subscribes at all).
func wpeExportsFunction(named name: String, in context: JSContext) -> Bool {
    guard let value = context.objectForKeyedSubscript(name) else { return false }
    return !value.isUndefined && value.hasProperty("call")
}

/// Field diff, mirroring the reference implementation: force both events on the
/// first delivery after load, then send each one only when its own fields moved.
/// Without this a handler would run on every source push (and, if the renderer
/// polled, every frame).
struct WPESceneMediaDiffGate {
    private var delivered: WPESceneMediaSnapshot?

    mutating func events(for snapshot: WPESceneMediaSnapshot) -> [WPESceneMediaEvent] {
        guard let previous = delivered else {
            // A cold launch replays `awaitingFirstEvent` — a state nobody has
            // observed, not an observation. Delivering it as PLAYBACK_STOPPED
            // latched author scripts that gate on stop (3510729512 hides its
            // media panel), and delivering its EMPTY properties made scenes run
            // their track-change animation into a blank title and park there
            // (3326873240's flip froze at scale 0). WPE's contract is that a
            // handler is simply not called until there is data, so send nothing
            // and stay armed: the first real snapshot takes this branch again
            // and force-delivers every field.
            guard !snapshot.isAwaitingFirstEvent else { return [] }
            delivered = snapshot
            var events: [WPESceneMediaEvent] = [
                .playbackChanged(snapshot.state),
                .propertiesChanged(snapshot.properties),
                .thumbnailChanged(snapshot.thumbnail)
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
        // The extracted palette IS the payload, so comparing it is exactly
        // "did anything the handler can observe move". Two different covers that
        // extract to the same five colours deliberately do not re-fire.
        if delivered.thumbnail != snapshot.thumbnail {
            events.append(.thumbnailChanged(snapshot.thumbnail))
        }
        // The delivered position is interpolated to now, so this moves on every source push
        // while playing — bounded, since pushes are source-driven (no timer, no per-frame tick;
        // scripts interpolate on their own clock between events). Losing data mid-track sends
        // nothing rather than a zeroed timeline.
        if let timeline = snapshot.timeline, delivered.timeline != timeline {
            events.append(.timelineChanged(timeline))
        }
        return events
    }
}

/// Hand-off from the `@MainActor` source to the renderer's display actor. The
/// renderer drains it on its own frame path, so no scene-script state is ever
/// touched from two isolation domains.
/// `@unchecked Sendable`: every access to `pending` is inside `lock`.
final class WPESceneMediaEventMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [WPESceneMediaEvent] = []

    func post(_ events: [WPESceneMediaEvent]) {
        guard !events.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        pending.append(contentsOf: events)
    }

    /// Empty on the overwhelming majority of frames — the diff gate only posts
    /// on an actual change.
    func drain() -> [WPESceneMediaEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return [] }
        let events = pending
        pending.removeAll(keepingCapacity: true)
        return events
    }
}

/// The subscribe/unsubscribe surface the dispatcher needs, so tests never reach
/// `NowPlayingMonitor.shared` (and through it the user's running Spotify).
@MainActor
protocol WPENowPlayingEventSource: AnyObject {
    func subscribe(id: UUID, handler: @escaping @Sendable (UInt64, MonitorNowPlayingState) -> Void)
    func unsubscribe(id: UUID)
}

extension NowPlayingMonitor: WPENowPlayingEventSource {}

/// Owns one scene's media subscription: demand gate at load, field diff per
/// push, and an explicit `stop()` at teardown so the subscription cannot
/// outlive the wallpaper.
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

    /// True when any bound script in the document exports a media handler. A scene without
    /// one must cost nothing — no subscription, no per-frame work (Issue #133 was the mirror
    /// image: capture gated on a flag scenes never set). `nonisolated`: a pure document scan,
    /// called from the renderer's display actor before anything touches the main actor.
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

    func start() {
        guard !isSubscribed else { return }
        isSubscribed = true
        // `subscribe` replays the current state synchronously, which is what
        // forces the first delivery — a scene loaded mid-song starts correct.
        source.subscribe(id: id) { [weak self] ordinal, state in
            // NowPlayingMonitor is @MainActor and notifies from it; this closure
            // is only ever entered on the main actor.
            MainActor.assumeIsolated {
                self?.ingest(ordinal: ordinal, state: state)
            }
        }
    }

    func stop() {
        guard isSubscribed else { return }
        isSubscribed = false
        source.unsubscribe(id: id)
    }

    private func ingest(ordinal: UInt64, state: MonitorNowPlayingState) {
        // The ordinal lets a late hop be dropped rather than rewinding the scene.
        if let lastOrdinal, ordinal < lastOrdinal { return }
        lastOrdinal = ordinal
        let snapshot = WPESceneMediaSnapshot(
            state,
            thumbnail: palette.thumbnail(for: state.artwork),
            timeline: WPESceneMediaTimeline.interpolated(from: state, now: now())
        )
        mailbox.post(gate.events(for: snapshot))
    }
}
#endif
