import ExtensionFoundation
import Foundation
import os.log

/// Entry point for the system wallpaper appex (ExtensionKit point
/// `com.apple.wallpaper`). The system launches this process on demand; the
/// main app does not need to be running (plan §3 U7, tested).
@main
@MainActor
final class SystemWallpaperProvider: NSObject, AppExtension {
    let bridge: WallpaperXPCBridge

    override required init() {
        let hostID = SharedLibraryStore.inferredHostBundleID()
        self.bridge = WallpaperXPCBridge(store: SharedLibraryStore(hostBundleID: hostID))
        super.init()
        wpxLog.info("EXTENSION INIT — \(Bundle.main.bundleIdentifier ?? "?", privacy: .public) host=\(hostID, privacy: .public)")
    }

    var configuration: WallpaperExtensionConfiguration {
        WallpaperExtensionConfiguration(bridge: bridge)
    }
}

struct WallpaperExtensionConfiguration: AppExtensionConfiguration {
    nonisolated let bridge: WallpaperXPCBridge

    nonisolated func accept(connection: NSXPCConnection) -> Bool {
        bridge.accept(connection: connection)
    }
}
