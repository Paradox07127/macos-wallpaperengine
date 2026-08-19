import Foundation
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
                },
                SystemWallpaperPaths.darwinLibraryChangedNote as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    private let libraryObserver: LibraryChangeObserver

    init(store: SharedLibraryStore) {
        self.store = store
        self.settings = SettingsProvider(
            store: store,
            providerID: Bundle.main.bundleIdentifier ?? "com.loomscreen.wallpaper"
        )
        self.libraryObserver = LibraryChangeObserver(registry: registry, store: store)
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
        guard Self.verifyRuntimeLayout() else {
            store.writeHeartbeat(activeChoiceID: nil, runtimeHealthy: false)
            return false
        }

        let exported = NSXPCInterface(with: WallpaperExtensionXPCProtocol.self)
        let allowed = Self.allowedClasses()
        Self.applyAllowlist(allowed, to: exported)
        connection.exportedInterface = exported

        let handler = WallpaperXPCHandler(store: store, registry: registry, settings: settings)
        connection.exportedObject = handler
        handlersLock.withLock { handlers[ObjectIdentifier(connection)] = handler }

        let proxyInterface = NSXPCInterface(with: WallpaperExtensionProxyXPCProtocol.self)
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

        // Grab the proxy before resuming so an early callback never sees nil.
        handler.agentProxy = connection.remoteObjectProxy as AnyObject
        connection.resume()
        wpxLog.info("accept(connection:) — wired")
        return true
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
