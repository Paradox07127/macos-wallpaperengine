import Foundation
import os.log

/// The IO half of `SystemWallpaperProviderStaleness` (the decision itself lives
/// in `Models/SystemWallpaperManifest.swift`, which this target shares with the
/// app, so it can be unit-tested).
///
/// The stale process cannot be signalled from the sandboxed app, so it retires
/// itself. Exiting mid-wallpaper is intended: WallpaperAgent re-instantiates the
/// extension — the installed one — the next time it needs the surface.
enum ProviderStaleness {
    /// Read straight from `Contents/Info.plist` rather than through `Bundle`:
    /// `Bundle.main.infoDictionary` is the dictionary loaded at launch, which is
    /// exactly the stale value this check exists to compare against.
    static func onDiskBuild(atBundlePath path: String) -> String? {
        let plist = URL(fileURLWithPath: path)
            .appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any]
        else { return nil }
        return info["CFBundleVersion"] as? String ?? ""
    }

    /// Retire this process if the build it is running is no longer installed.
    /// Called from the keep-alive tick and from `accept(connection:)` — the two
    /// moments a stale process would otherwise act on the system's behalf.
    static func exitIfStale(bundle: Bundle = .main) {
        let loaded = bundle.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let verdict = SystemWallpaperProviderStaleness.verdict(
            loadedBuild: loaded,
            onDiskBuild: onDiskBuild(atBundlePath: bundle.bundlePath)
        )
        switch verdict {
        case .current:
            return
        case .bundleGone:
            // Path-shaped: `.private`, per the rule WPXLogPrivacy documents.
            wpxLog.info("retiring — launched from a bundle that is gone (\(bundle.bundlePath, privacy: .private))")
        case let .buildChanged(loadedBuild, onDisk):
            wpxLog.info("retiring — build \(loadedBuild, privacy: .public) replaced on disk by \(onDisk, privacy: .public)")
        }
        exit(0)
    }
}
