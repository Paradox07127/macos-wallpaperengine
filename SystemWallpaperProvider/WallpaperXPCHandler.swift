import Foundation
import IOKit.ps
import QuartzCore
import os.log

/// Implements the Agent-facing protocol. One instance per connection; all
/// lifecycle work hops onto a process-wide serial queue so an invalidate can
/// never interleave with the two halves of an acquire (contract §3).
///
/// `@unchecked Sendable`: every stored property except `agentProxy` is a `let`,
/// and `agentProxy` is assigned once in `accept(connection:)` before the
/// connection is resumed, so no incoming call can observe it mid-write.
final class WallpaperXPCHandler: NSObject, WallpaperExtensionXPCProtocol, @unchecked Sendable {
    private let store: SharedLibraryStore
    private let registry: SurfaceRegistry
    private let settings: SettingsProvider
    weak var agentProxy: AnyObject?

    private static let queue = DispatchQueue(label: "com.loomscreen.wallpaper.lifecycle")
    /// Long enough to ride out a sleep/wake blink, short enough to stop
    /// burning power on a surface the system really did drop.
    private static let teardownGrace: TimeInterval = 15
    /// Ceiling on the deferred switch reply — past this the blink is the lesser
    /// evil compared with a wallpaper panel that never finishes switching.
    private static let firstFrameReplyTimeout: TimeInterval = 1.0

    init(store: SharedLibraryStore, registry: SurfaceRegistry, settings: SettingsProvider) {
        self.store = store
        self.registry = registry
        self.settings = settings
        super.init()
    }

    // MARK: - Settings

    func provideSettingsViewModels(contentTypes: Any?, reply: @escaping @Sendable (Any?, Error?) -> Void) {
        Self.queue.async { [self] in
            let models = settings.makeViewModels()
            // An empty-but-valid reply beats an error: the panel then shows an
            // empty group instead of logging a 4099 and dropping us.
            let object = SettingsViewModelsEncoder.makeXPCObject(models)
                ?? SettingsViewModelsEncoder.makeXPCObject(
                    SettingsViewModels(desktop: nil, screenSaver: nil))
            wpxLog.info("provideSettingsViewModels — \(models.desktop?.groups.first?.items.count ?? 0) item(s)")
            writeActiveHeartbeat()
            reply(object, nil)
        }
    }

    // MARK: - Lifecycle

    func acquire(id: Any?, request: Any?, reply: @escaping @Sendable (Any?, Error?) -> Void) {
        // Opaque XPC values: handed to the lifecycle queue and read only
        // there, so the one-way handoff is what makes this safe.
        nonisolated(unsafe) let id = id
        nonisolated(unsafe) let request = request
        Self.queue.async { [self] in
            let uuid = MirrorProbe.firstUUID(in: id) ?? Self.fallbackUUID(for: request)
            let size = Self.sanitized(size: MirrorProbe.cgSize(named: "size", in: request))
            let scale = Self.sanitized(scale: MirrorProbe.cgFloat(named: "scaleFactor", in: request))
            let displayID = MirrorProbe.uint32(named: "directDisplayID", in: request)
            let isPreview = (MirrorProbe.value(named: "isPreview", in: request) as? Bool) ?? false
            let choiceID = Self.choiceID(from: request)

            guard let surface = registry.makeSurface(for: uuid) else {
                wpxLog.error("surface cap hit — refusing \(uuid.uuidString, privacy: .public)")
                reply(nil, NSError(domain: "com.loomscreen.wallpaper", code: 2))
                return
            }
            surface.teardownWorkItem?.cancel()
            surface.teardownWorkItem = nil
            surface.isPreview = isPreview

            // Re-acquire of a live surface: keep the same contextId, only
            // re-frame or swap the asset (contract §3.1, §9 坑 9).
            if surface.contextId != 0 {
                surface.bridge.reframe(size: size, scale: scale)
                let context = PrivateClassFactory.remoteContext(contextId: surface.contextId)

                guard let choiceID, choiceID != surface.choiceID else {
                    writeActiveHeartbeat()
                    reply(context, nil)
                    return
                }
                surface.choiceID = choiceID
                writeActiveHeartbeat()
                // Switching between two of our own wallpapers: the Agent keeps
                // compositing the OLD context until we reply, so holding the
                // reply until the new video's first frame is out replaces the
                // blink with a clean hand-off (contract §3.1). Preview surfaces
                // reply at once — the picker must stay responsive.
                if isPreview {
                    startPlayback(surface: surface, choiceID: choiceID, size: size, replyOnFirstFrame: nil)
                    reply(context, nil)
                    return
                }
                let once = ReplyOnce { reply(context, nil) }
                startPlayback(surface: surface, choiceID: choiceID, size: size) { once.fire() }
                // A video that never produces a frame must not wedge the panel.
                Self.queue.asyncAfter(deadline: .now() + Self.firstFrameReplyTimeout) { once.fire() }
                return
            }

            guard let contextId = surface.bridge.makeContext(displayID: displayID, size: size, scale: scale) else {
                registry.remove(uuid)
                reply(nil, NSError(domain: "com.loomscreen.wallpaper", code: 1))
                return
            }
            surface.contextId = contextId
            surface.choiceID = choiceID

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.renderer.layer.frame = CGRect(origin: .zero, size: size)
            surface.bridge.rootLayer.addSublayer(surface.renderer.layer)
            CATransaction.commit()
            CATransaction.flush()

            // Seed a still so the context has composited content before we
            // reply — the Agent swaps to us on reply and would otherwise show
            // a blank surface (contract §3.1). Seeding the chosen video's own
            // poster frame rather than flat black is what makes the switch read
            // as the wallpaper appearing instead of a black (or, on an
            // untouched surface, green) flash.
            surface.renderer.enqueueStill(posterURL: posterURL(for: choiceID), size: size)
            CATransaction.flush()

            if let choiceID {
                startPlayback(surface: surface, choiceID: choiceID, size: size, replyOnFirstFrame: nil)
            }
            writeActiveHeartbeat()
            wpxLog.info("acquire — surface \(uuid.uuidString, privacy: .public) ctx=\(contextId) preview=\(isPreview)")
            reply(PrivateClassFactory.remoteContext(contextId: contextId), nil)
        }
    }

    func update(id: Any?, request: Any?, reply: @escaping @Sendable (Error?) -> Void) {
        // Opaque XPC values: handed to the lifecycle queue and read only
        // there, so the one-way handoff is what makes this safe.
        nonisolated(unsafe) let id = id
        nonisolated(unsafe) let request = request
        Self.queue.async { [self] in
            let mode = MirrorProbe.enumCaseName(named: "presentationMode", in: request) ?? "default"
            let activity = MirrorProbe.enumCaseName(named: "activityState", in: request) ?? "active"
            let uuid = MirrorProbe.firstUUID(in: id) ?? MirrorProbe.uint32(named: "directDisplayID", in: id)
                .map { Self.fallbackUUID(forDisplayID: $0) }

            let playbackMode = store.loadManifest().playbackMode
            let targets = uuid.flatMap { registry.surface(for: $0) }.map { [$0] } ?? registry.all
            for surface in targets where !surface.isPreview {
                surface.lastPresentationMode = mode
                surface.lastActivityState = activity
                // Ease rather than cut, so the wallpaper settles into a still.
                surface.renderer.rampRate(to: Self.rate(for: surface, playbackMode: playbackMode))
            }
            wpxLog.info("update — mode=\(mode, privacy: .public) activity=\(activity, privacy: .public) targets=\(targets.count)")
            reply(nil)
        }
    }

    func invalidate(id: Any?, reply: @escaping @Sendable (Error?) -> Void) {
        // Opaque XPC values: handed to the lifecycle queue and read only
        // there, so the one-way handoff is what makes this safe.
        nonisolated(unsafe) let id = id
        Self.queue.async { [self] in
            // Acquires without a WallpaperID were keyed off the display; probe
            // the same field here or their surfaces can never be torn down and
            // the remote context leaks into the Agent's composite tree.
            let uuid = MirrorProbe.firstUUID(in: id)
                ?? MirrorProbe.uint32(named: "directDisplayID", in: id).map { Self.fallbackUUID(forDisplayID: $0) }
            guard let uuid, let surface = registry.surface(for: uuid) else {
                reply(nil)
                return
            }
            // Defer teardown: display wake and fast switching both invalidate
            // then immediately re-acquire the same surface (contract §3.3).
            // Strong captures on purpose — the connection (and this handler)
            // usually dies within the 15 s grace, and a teardown that no-ops
            // then leaks the remote context into the Agent's composite tree
            // until `killall WallpaperAgent`. Registry and store outlive every
            // connection (they belong to the bridge), so nothing cycles.
            let registry = registry
            let store = store
            let work = DispatchWorkItem {
                // Sync, and before the context goes: the pump must not enqueue
                // into a dead context, and the layer teardown must not race it.
                surface.renderer.stopSync()
                surface.bridge.invalidate()
                registry.remove(uuid)
                // The work item's closure holds `surface` and the surface holds
                // the work item — break the cycle or every torn-down surface
                // (layer, decoder, context wrapper) lives until process exit.
                surface.teardownWorkItem = nil
                // Republish the heartbeat so the app stops claiming this
                // wallpaper is live the moment the surface really goes away.
                Self.writeActiveHeartbeat(registry: registry, store: store)
                wpxLog.info("invalidate — torn down \(uuid.uuidString, privacy: .public)")
            }
            surface.teardownWorkItem?.cancel()
            surface.teardownWorkItem = work
            Self.queue.asyncAfter(deadline: .now() + Self.teardownGrace, execute: work)
            reply(nil)
        }
    }

    func snapshot(id: Any?, reply: @escaping @Sendable (Any?, Error?) -> Void) {
        nonisolated(unsafe) let id = id
        Self.queue.async { [self] in
            let uuid = MirrorProbe.firstUUID(in: id)
            let choiceID = uuid.flatMap { registry.surface(for: $0)?.choiceID } ?? activeChoiceID()
            guard let posterURL = posterURL(for: choiceID),
                  let surface = SnapshotFactory.makeIOSurface(imageURL: posterURL),
                  let object = PrivateClassFactory.snapshot(surface: surface) else {
                // No poster is not an error: the panel falls back to its own
                // placeholder, exactly as it did before this was implemented.
                reply(nil, nil)
                return
            }
            reply(object, nil)
        }
    }

    // MARK: - Choices

    func selectedChoicesDidChange(for id: Any?, reply: @escaping @Sendable (Error?) -> Void) {
        // Deliberately no renderer work: the callback carries no display, and
        // the system follows it with invalidate + acquire (contract §9 坑 7).
        store.writeHeartbeat(activeChoiceID: MirrorProbe.identifierFromDescription(id), runtimeHealthy: true)
        reply(nil)
    }

    /// Kept working even though our choices now report `.none` disposability
    /// (SettingsProvider): if a future macOS does route a removal here, it has
    /// to delete rather than reply success and strand the files on disk.
    func removeChoiceRequest(request: Any?, reply: @escaping @Sendable (Error?) -> Void) {
        nonisolated(unsafe) let request = request
        Self.queue.async { [self] in
            guard let choiceID = MirrorProbe.identifierFromDescription(request) else {
                wpxLog.error("removeChoiceRequest without an identifier")
                reply(nil)
                return
            }
            let removed: SystemWallpaperManifest?
            do {
                removed = try SystemWallpaperLock.withExclusiveLock(root: store.sharedRoot()) {
                    try SystemWallpaperLibrary.remove(
                        id: choiceID,
                        from: store.loadManifest(),
                        videosDirectory: store.videosDirectory(),
                        persist: { try store.writeManifest($0) }
                    )
                }
            } catch {
                // Manifest write failed: nothing was deleted, so the library
                // is still consistent — report it rather than claim success.
                wpxLog.error("removeChoiceRequest persist failed: \(String(describing: error), privacy: .public)")
                reply(error)
                return
            }
            guard let updated = removed else {
                reply(nil)
                return
            }
            // Stop only the surfaces bound to this choice: other displays may be
            // playing something else and must keep running (upstream parity).
            let stopped = registry.all.filter { $0.choiceID == choiceID }
            for surface in stopped {
                surface.renderer.stop()
                surface.choiceID = nil
            }
            wpxLog.info("removed choice \(choiceID, privacy: .public) — \(updated.items.count) left, stopped \(stopped.count) renderer(s)")
            // Without this the panel keeps showing the tile it just removed.
            invalidateAgentSnapshots()
            reply(nil)
        }
    }

    private func invalidateAgentSnapshots() {
        guard let proxy = agentProxy as? WallpaperExtensionProxyXPCProtocol else { return }
        proxy.invalidateSnapshots { error in
            if let error {
                wpxLog.error("invalidateSnapshots failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func addChoiceRequest(request: Any?, onBehalfOfProcess: Any?, reply: @escaping @Sendable (Any?, Error?) -> Void) {
        reply(nil, nil)
    }

    func invokeContextMenuAction(menuItemID: Any?, groupItemID: Any?, reply: @escaping @Sendable (Error?) -> Void) {
        reply(nil)
    }

    // MARK: - Stubs (contract §11)

    func isChoiceDownloaded(with choiceID: Any?, reply: @escaping @Sendable (Bool, Error?) -> Void) { reply(true, nil) }
    func download(choiceID: Any?, reply: @escaping @Sendable (Error?) -> Void) -> Any? { reply(nil); return nil }
    func pauseDownload(for choiceID: Any?, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
    func cancelDownload(for choiceID: Any?, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
    func resumeDownload(for choiceID: Any?, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
    func removeDownload(for choiceID: Any?, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
    func migrateSelectedChoice(for id: Any?, reply: @escaping @Sendable (Any?, Error?) -> Void) { reply(nil, nil) }
    func migrate(from: Any?, to: Any?, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
    func skipShuffledContent(id: Any?, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
    func canSkipShuffledContent(id: Any?, reply: @escaping @Sendable (Bool, Error?) -> Void) { reply(false, nil) }
    func handleDebugRequest(for request: Any?, reply: @escaping @Sendable (Any?, Error?) -> Void) { reply(nil, nil) }
    func handleNotification(named: Any?, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }

    // MARK: - Helpers

    private func startPlayback(surface: WallpaperSurface, choiceID: String, size: CGSize,
                               replyOnFirstFrame: (@Sendable () -> Void)?) {
        let manifest = store.loadManifest()
        guard let item = manifest.items.first(where: { $0.id == choiceID }) else {
            wpxLog.error("choice \(choiceID, privacy: .public) not in manifest")
            return
        }
        let url = store.videoURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else {
            wpxLog.error("video missing: \(url.lastPathComponent, privacy: .public)")
            return
        }
        surface.renderer.start(url: url, onFirstFrame: replyOnFirstFrame)
    }

    /// The policy has had an `onBattery` input since day one but nothing ever
    /// set it, so both of its branches were dead. IOPowerSources is the only
    /// battery API a sandboxed appex can read.
    private static func isOnBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                let state = description[kIOPSPowerSourceStateKey] as? String else { continue }
            if state == kIOPSBatteryPowerValue { return true }
        }
        return false
    }

    /// XPC replies must run exactly once; the first-frame callback and the
    /// timeout race by design.
    private final class ReplyOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: (() -> Void)?

        init(_ body: @escaping () -> Void) { pending = body }

        func fire() {
            lock.lock()
            let body = pending
            pending = nil
            lock.unlock()
            body?()
        }
    }

    /// The JPEG the app writes next to each published video.
    private func posterURL(for choiceID: String?) -> URL? {
        guard let choiceID,
              let item = store.loadManifest().items.first(where: { $0.id == choiceID }),
              let thumbnailFileName = item.thumbnailFileName else { return nil }
        let url = store.videosDirectory().appendingPathComponent(thumbnailFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func activeChoiceID() -> String? {
        registry.all.first(where: { !$0.isPreview })?.choiceID
    }

    /// Every choice a non-preview surface is showing — with two displays on
    /// two videos, both count as "on screen" (the single-value field would
    /// mark the second one removable-and-idle in the app). Static so the
    /// deferred teardown can publish it after its handler is gone.
    static func writeActiveHeartbeat(registry: SurfaceRegistry, store: SharedLibraryStore) {
        var seen = Set<String>()
        let active = registry.all.compactMap { surface -> String? in
            guard !surface.isPreview, let id = surface.choiceID, seen.insert(id).inserted else { return nil }
            return id
        }
        store.writeHeartbeat(activeChoiceID: active.first, activeChoiceIDs: active, runtimeHealthy: true)
    }

    private func writeActiveHeartbeat() {
        Self.writeActiveHeartbeat(registry: registry, store: store)
    }

    /// The tier for one surface, from its last known system state plus the
    /// manifest as it stands right now. Shared by `update` and the Darwin
    /// notification path so the two can never disagree.
    static func rate(for surface: WallpaperSurface, playbackMode: SystemWallpaperPlaybackMode) -> Double {
        let input = PlaybackPolicyInput(
            thermalState: ProcessInfo.processInfo.thermalState,
            onBattery: isOnBattery(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            systemRequestedPause: surface.lastActivityState.contains("suspended")
                || surface.lastPresentationMode == "idle",
            isLockScreen: surface.lastPresentationMode == "locked",
            playbackMode: playbackMode
        )
        return PlaybackPolicy.rate(for: PlaybackPolicy.tier(for: input))
    }

    /// Entered from the Darwin `libraryChanged` notification: the user just
    /// flipped the playback-mode switch (or edited the library) in the app,
    /// and a running wallpaper should follow now, not at the next system
    /// update callback.
    static func reapplyPolicy(registry: SurfaceRegistry, store: SharedLibraryStore) {
        // The registry is confined to the lifecycle queue; this hop is the
        // only thing the Darwin callback does with it.
        nonisolated(unsafe) let registry = registry
        queue.async {
            let playbackMode = store.loadManifest().playbackMode
            for surface in registry.all where !surface.isPreview {
                surface.renderer.rampRate(to: rate(for: surface, playbackMode: playbackMode))
            }
            wpxLog.info("library changed — reapplied policy to \(registry.all.count) surface(s)")
        }
    }

    /// The panel and Agent normally send sane values; these guards are about
    /// arithmetic safety, not trust — `Int(CGFloat.nan)` traps, and a huge
    /// size becomes a huge IOSurface allocation.
    private static func sanitized(size: CGSize?) -> CGSize {
        let fallback = CGSize(width: 1920, height: 1080)
        guard let size, size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1,
              size.width <= 16384, size.height <= 16384 else { return fallback }
        return size
    }

    private static func sanitized(scale: CGFloat?) -> CGFloat {
        guard let scale, scale.isFinite, scale >= 1, scale <= 4 else { return 2 }
        return scale
    }

    /// Some acquires arrive without a WallpaperID; key them off the display so
    /// they still get a stable, reusable surface.
    private static func fallbackUUID(for request: Any?) -> UUID {
        fallbackUUID(forDisplayID: MirrorProbe.uint32(named: "directDisplayID", in: request) ?? 0)
    }

    static func fallbackUUID(forDisplayID displayID: UInt32) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: displayID.littleEndian) { raw in
            for (index, byte) in raw.enumerated() { bytes[index] = byte }
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func choiceID(from request: Any?) -> String? {
        if let data = MirrorProbe.data(named: "configuration", in: request),
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        if let identifier = MirrorProbe.value(named: "identifier", in: request) as? String, !identifier.isEmpty {
            return identifier
        }
        return MirrorProbe.identifierFromDescription(request)
    }
}
