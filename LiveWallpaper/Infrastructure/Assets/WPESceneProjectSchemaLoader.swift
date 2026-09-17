#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import os

enum WPESceneProjectSchemaLoader {
    struct Outcome: Sendable {
        let schema: WallpaperEngineProjectPropertySchema?
        let log: String
        let isExpectedAbsence: Bool
        let failure: WallpaperFailureCause?

        init(schema: WallpaperEngineProjectPropertySchema?, log: String, isExpectedAbsence: Bool, failure: WallpaperFailureCause? = nil) {
            self.schema = schema
            self.log = log
            self.isExpectedAbsence = isExpectedAbsence
            self.failure = failure
        }
    }

    private struct CacheKey: Hashable {
        let workshopID: String
        let cacheRelativePath: String
        let entryFile: String
        let assetStorage: String
        let originFingerprint: String?
        let supportRootPath: String?
    }

    /// `project.json` as it stood when the memo was taken.
    private struct ProjectFingerprint: Equatable {
        let size: Int
        let modified: TimeInterval

        init?(_ url: URL?) {
            guard let url,
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let modified = values.contentModificationDate
            else { return nil }
            self.size = size
            self.modified = modified.timeIntervalSince1970
        }
    }

    private struct CacheEntry {
        let outcome: Outcome
        let fingerprint: ProjectFingerprint
    }

    /// Answers about a scene (a schema, or a confirmed absence) are memoized so a re-mounted
    /// inspector can render on its first frame; failed reads are never memoized.
    private static let cache = OSAllocatedUnfairLock<[CacheKey: CacheEntry]>(initialState: [:])

    /// Process-lifetime observer; the token is deliberately dropped (never removed).
    private static let observesImports: Bool = {
        _ = NotificationCenter.default.addObserver(
            forName: .wpeImportDidComplete, object: nil, queue: nil
        ) { _ in
            invalidateCache()
        }
        return true
    }()

    private static func cacheKey(
        descriptor: SceneDescriptor,
        wpeOrigin: WPEOrigin?,
        supportRoot: URL?
    ) -> CacheKey {
        CacheKey(
            workshopID: descriptor.workshopID,
            cacheRelativePath: descriptor.cacheRelativePath,
            entryFile: descriptor.entryFile,
            assetStorage: String(describing: descriptor.assetStorage),
            originFingerprint: wpeOrigin?.sourceFolderBookmark.base64EncodedString(),
            supportRootPath: supportRoot?.path
        )
    }

    static func cachedOutcome(
        descriptor: SceneDescriptor,
        wpeOrigin: WPEOrigin?,
        applicationSupportRootURL: URL? = nil
    ) -> Outcome? {
        let key = cacheKey(
            descriptor: descriptor,
            wpeOrigin: wpeOrigin,
            supportRoot: applicationSupportRootURL ?? defaultApplicationSupportRoot()
        )
        return cache.withLock { $0[key]?.outcome }
    }

    static func invalidateCache() {
        cache.withLock { $0.removeAll() }
    }

    /// The app's own copy of `project.json`, which is the only one a later load can re-stat without
    /// resolving a security-scoped bookmark. `nil` for every other shape.
    private static func cachedProjectURL(descriptor: SceneDescriptor, supportRoot: URL?) -> URL? {
        guard descriptor.assetStorage == .cache,
              let supportRoot,
              WPEPathSafety.isSafeCacheRelativePath(descriptor.cacheRelativePath)
        else { return nil }
        return cacheFolderURL(supportRoot: supportRoot, cacheRelativePath: descriptor.cacheRelativePath)
            .appendingPathComponent("project.json")
    }

    static func load(
        descriptor: SceneDescriptor,
        wpeOrigin: WPEOrigin?,
        applicationSupportRootURL: URL? = nil
    ) async -> Outcome {
        _ = observesImports
        let supportRoot = applicationSupportRootURL ?? defaultApplicationSupportRoot()
        let key = cacheKey(descriptor: descriptor, wpeOrigin: wpeOrigin, supportRoot: supportRoot)
        let projectURL = cachedProjectURL(descriptor: descriptor, supportRoot: supportRoot)
        if let entry = cache.withLock({ $0[key] }) {
            // A fingerprint we cannot take (the folder went away) is not evidence the answer changed;
            // a different one is.
            let current = ProjectFingerprint(projectURL)
            if current == nil || current == entry.fingerprint {
                return entry.outcome
            }
        }
        let outcome = await read(
            descriptor: descriptor,
            wpeOrigin: wpeOrigin,
            applicationSupportRootURL: applicationSupportRootURL
        )
        // Only the app's own copy is memoized: revalidating a source folder would mean resolving its
        // bookmark on every load, which is the cost the memo exists to avoid.
        if outcome.schema != nil || outcome.isExpectedAbsence,
           let fingerprint = ProjectFingerprint(projectURL) {
            cache.withLock { $0[key] = CacheEntry(outcome: outcome, fingerprint: fingerprint) }
        }
        return outcome
    }

    private static func read(
        descriptor: SceneDescriptor,
        wpeOrigin: WPEOrigin?,
        applicationSupportRootURL: URL?
    ) async -> Outcome {
        guard WPEPathSafety.isSafeCacheRelativePath(descriptor.cacheRelativePath) else {
            return Outcome(
                schema: nil,
                log: "skip - unsafe cacheRelativePath (\(descriptor.cacheRelativePath))",
                isExpectedAbsence: false,
                failure: WallpaperFailureCause(code: "schema.unsafe_path", reason: String(localized: "The project settings path is not safe to open.", bundle: .appLanguage))
            )
        }

        let cacheRelativePath = descriptor.cacheRelativePath
        let supportRoot = applicationSupportRootURL ?? defaultApplicationSupportRoot()
        let workshopID = descriptor.workshopID

        return await Task.detached(priority: .userInitiated) {
            if descriptor.assetStorage == .cache, let supportRoot,
               let outcome = readFromCache(
                   supportRoot: supportRoot,
                   cacheRelativePath: cacheRelativePath,
                   workshopID: workshopID
               ) {
                return outcome
            }

            guard let bookmark = wpeOrigin?.sourceFolderBookmark else {
                return Outcome(
                    schema: nil,
                    log: "no cached project.json and wpeOrigin missing source bookmark for workshop=\(workshopID)",
                    isExpectedAbsence: false,
                    failure: WallpaperFailureCause(code: "schema.source_missing", reason: String(localized: "The project settings source is unavailable. Choose the project folder again.", bundle: .appLanguage))
                )
            }
            return readFromBookmark(bookmark: bookmark, workshopID: workshopID)
        }.value
    }

    // MARK: - Cache path

    private static func cacheFolderURL(supportRoot: URL, cacheRelativePath: String) -> URL {
        supportRoot
            .appendingPathComponent("LiveWallpaper", isDirectory: true)
            .appendingPathComponent(cacheRelativePath, isDirectory: true)
    }

    private static func readFromCache(
        supportRoot: URL,
        cacheRelativePath: String,
        workshopID: String
    ) -> Outcome? {
        let folderURL = cacheFolderURL(supportRoot: supportRoot, cacheRelativePath: cacheRelativePath)
        let projectURL = folderURL.appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: projectURL.path) else {
            return nil
        }
        do {
            // schemecolor is the WPE GLOBAL accent — most scenes never bind a field to it, so the picker is a no-op for them on macOS.
            // Hidden by default (matches read()'s default); scenes that DO reference it via a `{"user":"schemecolor"}` envelope still resolve its value through effectiveSceneValues in the renderer.
            let parsed = try WallpaperEngineProjectPropertySchema.read(from: folderURL)
            return makeOutcome(parsed: parsed, workshopID: workshopID, locationDescription: "cache at \(folderURL.path)")
        } catch {
            return Outcome(
                schema: nil,
                log: "project.json read/parse failed for workshop=\(workshopID) at \(folderURL.path) (\(error.localizedDescription))",
                isExpectedAbsence: false,
                failure: SceneFailureCause.make(error)
            )
        }
    }

    // MARK: - Source-bookmark fallback

    private static func readFromBookmark(
        bookmark: Data,
        workshopID: String
    ) -> Outcome {
        let result = SecurityScopedBookmarkResolver.shared.resolve(bookmark, target: .transient)
        switch result {
        case .failure(let failure):
            return Outcome(
                schema: nil,
                log: "bookmark resolve failed for workshop=\(workshopID) (\(failure.localizedDescription))",
                isExpectedAbsence: false,
                failure: SceneFailureCause.make(failure)
            )
        case .success(let resolved):
            do {
                let parsed = try SecurityScopedBookmarkResolver.withScopedAccess(resolved.url) { _ in
                    try WallpaperEngineProjectPropertySchema.read(from: resolved.url)
                }
                return makeOutcome(parsed: parsed, workshopID: workshopID, locationDescription: "source folder at \(resolved.url.path)")
            } catch {
                return Outcome(
                    schema: nil,
                    log: "project.json read/parse failed for workshop=\(workshopID) at \(resolved.url.path) (\(error.localizedDescription))",
                    isExpectedAbsence: false,
                    failure: SceneFailureCause.make(error)
                )
            }
        }
    }

    private static func makeOutcome(
        parsed: WallpaperEngineProjectPropertySchema,
        workshopID: String,
        locationDescription: String
    ) -> Outcome {
        if parsed.hasMeaningfulSettings {
            return Outcome(
                schema: parsed,
                log: "loaded \(parsed.properties.count) properties (editable=\(parsed.properties.filter { $0.type.isEditable }.count)) for workshop=\(workshopID) from \(locationDescription)",
                isExpectedAbsence: false
            )
        }
        return Outcome(
            schema: nil,
            log: "parsed \(parsed.properties.count) properties but none are editable for workshop=\(workshopID) from \(locationDescription)",
            isExpectedAbsence: true
        )
    }

    private static func defaultApplicationSupportRoot() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
    }
}
#endif
