import Foundation
import os.log

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

    /// Zero surfaces and zero live connections only — a serving process stays even when it is not the declared copy, and so does one the Agent still holds a proxy to: after an exit the Agent keeps using that proxy until its own 5-minute disconnection and every call errors (NSCocoaErrorDomain 4099) instead of relaunching. Runs on the lifecycle queue right after the Agent's disconnection, before RunningBoard suspends the process.
    static func exitIfIdleAndSuperseded(
        registry: SurfaceRegistry,
        store: SharedLibraryStore,
        hasLiveConnections: () -> Bool,
        bundle: Bundle = .main
    ) {
        let surfaces = registry.all.count
        let connected = hasLiveConnections()
        guard surfaces == 0, !connected else {
            wpxLog.info("idle retirement skipped — surfaces=\(surfaces, privacy: .public) connected=\(connected, privacy: .public)")
            return
        }
        let verdict = SystemWallpaperProviderStaleness.idleVerdict(
            bundleVerdict(bundle: bundle),
            ownBundlePath: bundle.bundlePath,
            declared: store.loadDeclaredProvider()
        )
        retire(if: verdict, bundle: bundle)
    }

    private static func bundleVerdict(bundle: Bundle) -> SystemWallpaperProviderStaleness.Verdict {
        let loaded = bundle.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return SystemWallpaperProviderStaleness.verdict(
            loadedBuild: loaded,
            onDiskBuild: onDiskBuild(atBundlePath: bundle.bundlePath)
        )
    }

    private static func retire(if verdict: SystemWallpaperProviderStaleness.Verdict, bundle: Bundle) {
        switch verdict {
        case .current:
            return
        case .bundleGone:
            // Path-shaped: `.private`, per the rule WPXLogPrivacy documents.
            wpxLog.info("retiring — launched from a bundle that is gone (\(bundle.bundlePath, privacy: .private))")
        case let .buildChanged(loadedBuild, onDisk):
            wpxLog.info("retiring — build \(loadedBuild, privacy: .public) replaced on disk by \(onDisk, privacy: .public)")
        case let .supersededByDeclared(declaredPath):
            wpxLog.info("retiring idle — the app declares \(declaredPath, privacy: .private), this is \(bundle.bundlePath, privacy: .private)")
        }
        exit(0)
    }
}
