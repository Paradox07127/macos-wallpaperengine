import Foundation
import IOKit.ps
import os.log

/// Sole home of every private-API touchpoint (plan §2): dlopen of
/// WallpaperExtensionKit and the NSXPCInterface wiring that speaks its opaque
/// types. If the runtime layout check fails we accept no connection, so the
/// extension quietly disappears from the wallpaper panel rather than crashing
/// inside WallpaperAgent.
/// `@unchecked Sendable`: the only mutable state is `handlers`, and every read
/// and write of it goes through `handlersLock`. The store/settings/registry
/// references are immutable after init.
final class WallpaperXPCBridge: @unchecked Sendable {
    private let store: SharedLibraryStore
    private let registry = SurfaceRegistry()
    private let settings: SettingsProvider
    private let handlersLock = NSLock()
    private var handlers: [ObjectIdentifier: WallpaperXPCHandler] = [:]

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"

    /// Keep the handle open — the framework must stay loaded for the classes
    /// we resolve to remain valid. `nonisolated(unsafe)`: written once by the
    /// lazy initializer and never mutated afterwards; readers only test it for nil.
    nonisolated(unsafe) private static let frameworkHandle: UnsafeMutableRawPointer? =
        dlopen(frameworkPath, RTLD_LAZY)

    /// The classes our contract depends on. Missing any of them means the OS
    /// changed shape under us, which is the documented degrade path.
    private static let criticalClasses = [
        "WallpaperRemoteContextXPC",
        "WallpaperSnapshotXPC",
        "WallpaperCreationRequestXPC",
        "WallpaperSettingsViewModelsXPC",
        "WallpaperIDXPC",
    ]

    /// Everything that may cross the wire, for the NSXPCInterface allowlists.
    private static let wireClassNames = criticalClasses + [
        "WallpaperUpdateRequestXPC",
        "WallpaperContentTypeSetXPC",
        "WallpaperChoiceIDXPC",
        "WallpaperChoiceIDsXPC",
        "WallpaperExtensionChoiceRequestXPC",
        "WallpaperChoiceRequestAdditionResultXPC",
        "WallpaperDebugRequestXPC",
        "WallpaperDebugResponseXPC",
        "WallpaperMigrationVersionXPC",
        "AuditTokenXPC",
    ]

    /// Bridges the app's Darwin `libraryChanged` post into a policy re-apply,
    /// so flipping the playback-mode switch reaches a running wallpaper now
    /// instead of at the next system update callback. Lives as long as the
    /// bridge (= the process), so no removal path is needed.
    private final class LibraryChangeObserver {
        let registry: SurfaceRegistry
        let store: SharedLibraryStore
        /// Weak: the bridge owns this observer.
        weak var owner: WallpaperXPCBridge?

        init(registry: SurfaceRegistry, store: SharedLibraryStore) {
            self.registry = registry
            self.store = store
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                { _, observer, _, _, _ in
                    guard let observer else { return }
                    let self_ = Unmanaged<LibraryChangeObserver>.fromOpaque(observer).takeUnretainedValue()
                    WallpaperXPCHandler.reapplyPolicy(registry: self_.registry, store: self_.store)
                    self_.owner?.libraryDidChange()
                },
                SystemWallpaperPaths.darwinLibraryChangedNote as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    /// `PlaybackPolicy` reads thermal state, Low Power Mode and AC/battery on
    /// every evaluation, but the only things that triggered an evaluation were
    /// the Agent's `update` and the app's Darwin note — so unplugging the power
    /// or heating the machine up left a running wallpaper on its old rate until
    /// something unrelated happened. Lives as long as the bridge (= the
    /// process), so no removal path is needed.
    private final class PowerConditionObserver {
        private let registry: SurfaceRegistry
        private let store: SharedLibraryStore

        init(registry: SurfaceRegistry, store: SharedLibraryStore) {
            self.registry = registry
            self.store = store
            // Same one-way handoff `reapplyPolicy` documents: the registry is
            // confined to the lifecycle queue, and these closures do nothing
            // with it but pass it there.
            nonisolated(unsafe) let registry = registry
            let store = store
            for name in [ProcessInfo.thermalStateDidChangeNotification,
                         NSNotification.Name.NSProcessInfoPowerStateDidChange] {
                NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: nil
                ) { _ in WallpaperXPCHandler.reapplyPolicy(registry: registry, store: store) }
            }
            // On macOS NSProcessInfoPowerStateDidChange only reports Low Power
            // Mode; AC↔battery — a policy input of its own (`onBattery`) — has
            // to come from IOKit.
            guard let source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                Unmanaged<PowerConditionObserver>.fromOpaque(context)
                    .takeUnretainedValue()
                    .reapply()
            }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() else {
                wpxLog.error("power source notifications unavailable — battery policy will not follow")
                return
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        private func reapply() {
            WallpaperXPCHandler.reapplyPolicy(registry: registry, store: store)
        }
    }

    /// Built on the first accepted connection, not in `init`. WallpaperAgent
    /// re-runs extension discovery every time the LaunchServices database
    /// changes — which an Xcode build or an app update does — and instantiates
    /// every registered provider, ours included. A discovery pass that never
    /// leads to a connection should not leave Darwin, NotificationCenter and
    /// IOKit run-loop observers behind. Both are `let`-once under `observerLock`;
    /// they are never torn down, because a process that has served one
    /// connection keeps them for its whole life (see the class comments).
    private let observerLock = NSLock()
    private var libraryObserver: LibraryChangeObserver?
    private var powerObserver: PowerConditionObserver?

    init(store: SharedLibraryStore) {
        self.store = store
        self.settings = SettingsProvider(
            store: store,
            providerID: Bundle.main.bundleIdentifier ?? "com.loomscreen.wallpaper"
        )
    }

    private func activateObserversIfNeeded() {
        observerLock.lock()
        defer { observerLock.unlock() }
        guard libraryObserver == nil else { return }
        let library = LibraryChangeObserver(registry: registry, store: store)
        library.owner = self
        libraryObserver = library
        powerObserver = PowerConditionObserver(registry: registry, store: store)
    }

    /// Fans a library change out to every live connection. Only a handler holds
    /// a route to the Agent, and only while its connection is up.
    fileprivate func libraryDidChange() {
        let live = handlersLock.withLock { Array(handlers.values) }
        for handler in live { handler.libraryDidChange() }
    }

    static func verifyRuntimeLayout() -> Bool {
        guard frameworkHandle != nil else {
            wpxLog.error("dlopen failed for WallpaperExtensionKit")
            return false
        }
        let missing = criticalClasses.filter { NSClassFromString($0) == nil }
        guard missing.isEmpty else {
            wpxLog.error("runtime layout check failed, missing: \(missing.joined(separator: ","), privacy: .public)")
            return false
        }
        // The two classes we raw-write must still carry the ivars we write to;
        // a class that exists with a changed layout degrades here, up front,
        // instead of failing every acquire one by one.
        let ivarChecks: [(className: String, ivarName: String)] = [
            ("WallpaperRemoteContextXPC", "box"),
            ("WallpaperSnapshotXPC", "rawValue"),
        ]
        for check in ivarChecks {
            guard let cls = NSClassFromString(check.className),
                  PrivateClassFactory.ivarOffset(cls, check.ivarName) != nil else {
                wpxLog.error("runtime layout check failed, ivar \(check.className, privacy: .public).\(check.ivarName, privacy: .public) missing")
                return false
            }
        }
        return true
    }

    /// Class metatypes are ObjC objects but not Swift `Hashable`, so the
    /// allowlist is assembled as an NSSet and bridged for `setClasses`.
    private static func allowedClasses() -> Set<AnyHashable> {
        let classes = NSMutableSet()
        for cls in [NSString.self, NSNumber.self, NSData.self, NSArray.self,
                    NSDictionary.self, NSURL.self, NSError.self, NSUUID.self] as [AnyClass] {
            classes.add(cls)
        }
        for name in wireClassNames {
            if let cls = NSClassFromString(name) { classes.add(cls) }
        }
        return (classes as? Set<AnyHashable>) ?? []
    }

    func accept(connection: NSXPCConnection) -> Bool {
        // The system is about to put this process to work — the last moment a
        // build that is no longer installed may still bow out.
        ProviderStaleness.exitIfStale()
        guard Self.verifyRuntimeLayout() else {
            store.writeHeartbeat(activeChoiceID: nil, runtimeHealthy: false)
            return false
        }
        activateObserversIfNeeded()

        let exported = NSXPCInterface(with: WallpaperExtensionXPCProtocol.self)
        let allowed = Self.allowedClasses()
        Self.applyAllowlist(allowed, to: exported)
        connection.exportedInterface = exported

        let handler = WallpaperXPCHandler(store: store, registry: registry, settings: settings)
        connection.exportedObject = handler
        handlersLock.withLock { handlers[ObjectIdentifier(connection)] = handler }

        let proxyInterface = NSXPCInterface(with: WallpaperExtensionProxyXPCProtocol.self)
        // The proxy side was never allowlisted. Its `id`-typed arguments and
        // replies mean NSXPC silently drops any message carrying a class it
        // was not told about — today only `invalidateSnapshots` is used and it
        // carries just an NSError, but the next use of
        // `updateSettingsViewModels` would fail with no error anywhere.
        Self.applyProxyAllowlist(allowed, to: proxyInterface)
        connection.remoteObjectInterface = proxyInterface

        connection.interruptionHandler = {
            wpxLog.info("connection interrupted")
        }
        connection.invalidationHandler = { [weak self] in
            // Never tear down render contexts here: every wallpaper pick drops
            // the connection and re-acquires about a second later (contract §9).
            self?.handlersLock.withLock { _ = self?.handlers.removeValue(forKey: ObjectIdentifier(connection)) }
            wpxLog.info("connection invalidated (contexts kept)")
        }

        // Wired before resuming so an early callback never sees a nil provider.
        // The connection is captured weakly: it owns the handler, so a strong
        // capture here would keep both alive forever.
        handler.agentProxyProvider = { [weak connection] in
            connection?.remoteObjectProxy as? WallpaperExtensionProxyXPCProtocol
        }
        connection.resume()
        wpxLog.info("accept(connection:) — wired")
        return true
    }

    private static func applyProxyAllowlist(_ classes: Set<AnyHashable>, to interface: NSXPCInterface) {
        let extra = NSMutableSet()
        for name in ["NSURL", "NSString", "NSError", "NSData", "NSNumber", "NSDictionary", "NSArray"] {
            if let cls = NSClassFromString(name) { extra.add(cls) }
        }
        let all = classes.union((extra as? Set<AnyHashable>) ?? [])
        let selector = #selector(WallpaperExtensionProxyXPCProtocol.updateSettingsViewModels(_:reply:))
        interface.setClasses(all, for: selector, argumentIndex: 0, ofReply: false)
        let access = #selector(WallpaperExtensionProxyXPCProtocol.requestReadOnlyAccess(to:reply:))
        interface.setClasses(all, for: access, argumentIndex: 0, ofReply: false)
        interface.setClasses(all, for: access, argumentIndex: 0, ofReply: true)
    }

    private static func applyAllowlist(_ classes: Set<AnyHashable>, to interface: NSXPCInterface) {
        // Every selector that carries an `id` argument or reply value needs
        // the private classes whitelisted, or NSXPC drops the message.
        let argumentSelectors: [(Selector, [Int])] = [
            (#selector(WallpaperExtensionXPCProtocol.acquire(id:request:reply:)), [0, 1]),
            (#selector(WallpaperExtensionXPCProtocol.update(id:request:reply:)), [0, 1]),
            (#selector(WallpaperExtensionXPCProtocol.invalidate(id:reply:)), [0]),
            (#selector(WallpaperExtensionXPCProtocol.snapshot(id:reply:)), [0]),
            (#selector(WallpaperExtensionXPCProtocol.provideSettingsViewModels(contentTypes:reply:)), [0]),
            (#selector(WallpaperExtensionXPCProtocol.addChoiceRequest(request:onBehalfOfProcess:reply:)), [0, 1]),
            (#selector(WallpaperExtensionXPCProtocol.removeChoiceRequest(request:reply:)), [0]),
            (#selector(WallpaperExtensionXPCProtocol.selectedChoicesDidChange(for:reply:)), [0]),
            (#selector(WallpaperExtensionXPCProtocol.invokeContextMenuAction(menuItemID:groupItemID:reply:)), [0, 1]),
            (#selector(WallpaperExtensionXPCProtocol.isChoiceDownloaded(with:reply:)), [0]),
            // Stubs, but stubs the system can still call: an un-allowlisted
            // `id` argument is dropped before it reaches them, so the Agent
            // waits out its call with no reply and no error.
            (#selector(WallpaperExtensionXPCProtocol.download(choiceID:reply:)), [0]),
            (#selector(WallpaperExtensionXPCProtocol.pauseDownload(for:reply:)), [0]),
            (#selector(WallpaperExtensionXPCProtocol.cancelDownload(for:reply:)), [0]),
            (#selector(WallpaperExtensionXPCProtocol.resumeDownload(for:reply:)), [0]),
            (#selector(WallpaperExtensionXPCProtocol.removeDownload(for:reply:)), [0]),
            (#selector(WallpaperExtensionXPCProtocol.migrateSelectedChoice(for:reply:)), [0]),
            (#selector(WallpaperExtensionXPCProtocol.migrate(from:to:reply:)), [0, 1]),
            (#selector(WallpaperExtensionXPCProtocol.skipShuffledContent(id:reply:)), [0]),
            (#selector(WallpaperExtensionXPCProtocol.canSkipShuffledContent(id:reply:)), [0]),
            (#selector(WallpaperExtensionXPCProtocol.handleDebugRequest(for:reply:)), [0]),
            (#selector(WallpaperExtensionXPCProtocol.handleNotification(named:reply:)), [0]),
        ]
        for (selector, indexes) in argumentSelectors {
            for index in indexes {
                interface.setClasses(classes, for: selector, argumentIndex: index, ofReply: false)
            }
        }

        let replySelectors: [Selector] = [
            #selector(WallpaperExtensionXPCProtocol.acquire(id:request:reply:)),
            #selector(WallpaperExtensionXPCProtocol.snapshot(id:reply:)),
            #selector(WallpaperExtensionXPCProtocol.provideSettingsViewModels(contentTypes:reply:)),
            #selector(WallpaperExtensionXPCProtocol.addChoiceRequest(request:onBehalfOfProcess:reply:)),
            #selector(WallpaperExtensionXPCProtocol.migrateSelectedChoice(for:reply:)),
            #selector(WallpaperExtensionXPCProtocol.handleDebugRequest(for:reply:)),
        ]
        for selector in replySelectors {
            interface.setClasses(classes, for: selector, argumentIndex: 0, ofReply: true)
        }
    }
}
