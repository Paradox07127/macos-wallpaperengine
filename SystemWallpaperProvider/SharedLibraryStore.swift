import Foundation
import os.log

let wpxLog = Logger(subsystem: "com.loomscreen.wallpaper", category: "extension")

/// Appex-side access to the host app's shared directory. Read-only for the
/// manifest/videos, write for the heartbeat (via the appex's sandbox
/// temporary-exception; the main app's entitlements stay untouched).
struct SharedLibraryStore {
    let hostBundleID: String

    /// The appex bundle id is `<host>.wallpaper`, so the host id is derivable
    /// without any per-SKU compile flag (packages/appexes don't see LITE_BUILD).
    static func inferredHostBundleID() -> String {
        let own = Bundle.main.bundleIdentifier ?? "com.loomscreen.pro.wallpaper"
        if own.hasSuffix(".wallpaper") {
            return String(own.dropLast(".wallpaper".count))
        }
        return own
    }

    func loadManifest() -> SystemWallpaperManifest {
        let url = SystemWallpaperPaths.manifestURL(hostBundleID: hostBundleID)
        guard let data = try? Data(contentsOf: url) else {
            wpxLog.info("manifest missing at \(url.path, privacy: .public)")
            return .empty
        }
        do {
            return try SystemWallpaperCoding.decoder.decode(SystemWallpaperManifest.self, from: data)
        } catch {
            wpxLog.error("manifest decode failed: \(String(describing: error), privacy: .public)")
            return .empty
        }
    }

    /// Nil when the manifest is on disk but will not decode. Callers that
    /// would otherwise show a black wallpaper need to tell "damaged" apart
    /// from "empty library" — `loadManifest()` collapses both to empty.
    func loadManifestIfReadable() -> SystemWallpaperManifest? {
        let url = SystemWallpaperPaths.manifestURL(hostBundleID: hostBundleID)
        // Only absence means "empty library". A present file we cannot read is
        // damaged as far as callers are concerned — reporting it empty stops
        // every running choice as if the user had deleted them.
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? SystemWallpaperCoding.decoder.decode(SystemWallpaperManifest.self, from: data)
    }

    func videoURL(for item: SystemWallpaperManifest.Item) -> URL {
        SystemWallpaperPaths.videosDirectory(hostBundleID: hostBundleID)
            .appendingPathComponent(item.fileName)
    }

    /// The extension writes the manifest only when macOS itself removes a
    /// choice; the app is otherwise the sole writer. Mutations run under
    /// `SystemWallpaperLock` on both sides — the atomic write only prevents
    /// torn JSON, the lock is what prevents lost updates.
    func writeManifest(_ manifest: SystemWallpaperManifest) throws {
        let url = SystemWallpaperPaths.manifestURL(hostBundleID: hostBundleID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try SystemWallpaperCoding.encoder.encode(manifest).write(to: url, options: .atomic)
    }

    func sharedRoot() -> URL {
        SystemWallpaperPaths.sharedRoot(hostBundleID: hostBundleID)
    }

    func videosDirectory() -> URL {
        SystemWallpaperPaths.videosDirectory(hostBundleID: hostBundleID)
    }

    func writeHeartbeat(activeChoiceID: String?, activeChoiceIDs: [String]? = nil, runtimeHealthy: Bool = true) {
        let beat = SystemWallpaperHeartbeat(
            timestamp: Date(),
            activeChoiceID: activeChoiceID,
            activeChoiceIDs: activeChoiceIDs,
            runtimeHealthy: runtimeHealthy,
            osVersion: SystemWallpaperHeartbeat.currentOSVersion()
        )
        guard let data = try? SystemWallpaperCoding.encoder.encode(beat) else { return }
        let url = SystemWallpaperPaths.heartbeatURL(hostBundleID: hostBundleID)
        do {
            // The shared directory does not exist until the app publishes its
            // first video, but the app reads this heartbeat to tell "extension
            // alive" from "extension never ran" — so create it from this side.
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            wpxLog.error("heartbeat write failed: \(String(describing: error), privacy: .public)")
        }
    }
}
