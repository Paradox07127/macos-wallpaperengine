import AppKit
import LiveWallpaperCore
import Metal
import os

#if !LITE_BUILD
import LiveWallpaperProWPE
#endif

#if LITE_BUILD
private enum WPEPathSafety {
    static func isSafeRelativePath(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix("/")
            && !value.contains("..")
            && value != "."
    }

    static func isSafeCacheRelativePath(_ path: String) -> Bool {
        path.hasPrefix("wpe-cache/")
            && !path.contains("\\")
            && !path.contains("..")
            && !path.contains("//")
    }

    static func contains(_ child: URL, in parent: URL) -> Bool {
        let childPath = normalizedPath(child.path(percentEncoded: false))
        let parentPath = normalizedPath(parent.path(percentEncoded: false))
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    static func resourceURL(root: URL, relativePath: String) -> URL? {
        guard isSafeRelativePath(relativePath) else { return nil }
        return containedResourceURL(root: root, relativePath: relativePath)
    }

    private static func containedResourceURL(root: URL, relativePath: String) -> URL? {
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = rootURL
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard contains(url, in: rootURL) else { return nil }
        return url
    }

    private static func normalizedPath(_ path: String) -> String {
        var normalized = path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
#endif

struct HTMLWallpaperCompatibilityResult {
    let config: HTMLConfig
    let trust: HTMLTrust
    let enabledPhysicalPixelLayout: Bool
}

enum HTMLWallpaperCompatibilityPolicy {
    static func runtimeConfig(
        source: HTMLSource,
        config: HTMLConfig,
        trustedOrigins: Set<TrustedHTMLOrigin>,
        bookmarkResolver: SecurityScopedBookmarkResolver = .shared
    ) -> HTMLWallpaperCompatibilityResult {
        let trust = HTMLTrust.evaluate(source: source, trustedOrigins: trustedOrigins)
        var effective = config
        effective.allowJavaScript = trust.effectiveAllowJavaScript(requested: config.allowJavaScript)
        effective.muteAudio = trust.effectiveMuteAudio(requested: config.muteAudio)
        effective.audioVolume = trust.effectiveAudioVolume(requested: config.audioVolume)

        let shouldEnablePhysicalPixels = !effective.physicalPixelLayout
            && shouldAutoEnablePhysicalPixelLayout(source, bookmarkResolver: bookmarkResolver)
        if shouldEnablePhysicalPixels {
            effective.physicalPixelLayout = true
        }

        return HTMLWallpaperCompatibilityResult(
            config: effective,
            trust: trust,
            enabledPhysicalPixelLayout: shouldEnablePhysicalPixels
        )
    }

    /// Older canvas HTML needs physical pixels; modern DPR-aware pages stay CSS-point.
    static func shouldAutoEnablePhysicalPixelLayout(
        _ source: HTMLSource,
        bookmarkResolver: SecurityScopedBookmarkResolver = .shared
    ) -> Bool {
        guard case .folder(_, let indexFileName) = source else { return false }
        return withResolvedFolderURL(source, bookmarkResolver: bookmarkResolver) { folderURL in
            shouldAutoEnablePhysicalPixelLayout(folderURL: folderURL, indexFileName: indexFileName)
        } ?? false
    }

    static func shouldAutoEnablePhysicalPixelLayout(folderURL: URL, indexFileName: String) -> Bool {
        let manifest = folderURL.appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return false }
        return !entryHTMLLooksDPRAware(folderURL: folderURL, indexFileName: indexFileName)
    }

    private static func withResolvedFolderURL<T>(
        _ source: HTMLSource,
        bookmarkResolver: SecurityScopedBookmarkResolver,
        _ body: (URL) -> T
    ) -> T? {
        guard case .folder(let bookmarkData, _) = source else { return nil }
        guard case .success(let resolved) = bookmarkResolver.resolve(
            bookmarkData,
            target: .transient
        ) else { return nil }
        let folderURL = resolved.url
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }
        return body(folderURL)
    }

    private static func entryHTMLLooksDPRAware(folderURL: URL, indexFileName: String) -> Bool {
        guard let entryURL = WPEPathSafety.resourceURL(root: folderURL, relativePath: indexFileName) else {
            return false
        }
        guard let data = try? Data(contentsOf: entryURL, options: .mappedIfSafe),
              let source = String(data: data, encoding: .utf8) else {
            return false
        }
        let lowered = source.lowercased()
        return lowered.contains("setpixelratio(")
            || lowered.contains("devicepixelratio")
    }
}

@MainActor
final class AmbientWallpaperSessionBuilder {
    typealias BookmarkRefreshHandler = @MainActor (_ original: Data, _ refreshed: Data) -> Void
    typealias WPEOriginRefreshHandler = @MainActor (_ origin: WPEOrigin, _ refreshed: Data) -> Void

    /// Relocate a dead workshop bookmark via Steam library id lookup.
    typealias WorkshopSourceRelocator = @MainActor (_ workshopID: String) -> Data?

    private let bookmarkResolver: SecurityScopedBookmarkResolver
    private let relocateWorkshopSource: WorkshopSourceRelocator

    init(
        bookmarkResolver: SecurityScopedBookmarkResolver = .shared,
        relocateWorkshopSource: @escaping WorkshopSourceRelocator = AmbientWallpaperSessionBuilder.defaultWorkshopSourceRelocator
    ) {
        self.bookmarkResolver = bookmarkResolver
        self.relocateWorkshopSource = relocateWorkshopSource
    }

    /// Lite has no Steam library binding to relocate against.
    static func defaultWorkshopSourceRelocator(_ workshopID: String) -> Data? {
        #if LITE_BUILD
        return nil
        #else
        return SteamCMDDoctorService.relocatedWorkshopSourceBookmark(workshopID: workshopID)
        #endif
    }

    func makeHTMLSession(
        source: HTMLSource,
        config: HTMLConfig,
        frame: CGRect,
        onBookmarkRefresh: @escaping BookmarkRefreshHandler = { _, _ in }
    ) -> AmbientWallpaperSession {
        // Resolve before compatibility probe — the probe can burn the one-shot stale grace.
        let effectiveSource = refreshingHTMLSource(
            source,
            onBookmarkRefresh: onBookmarkRefresh
        )
        let window = VideoWallpaperWindow(frame: frame)

        let compatibility = HTMLWallpaperCompatibilityPolicy.runtimeConfig(
            source: effectiveSource,
            config: config,
            trustedOrigins: TrustedHostStore.shared.originSet,
            bookmarkResolver: bookmarkResolver
        )
        let effective = compatibility.config
        if case .untrustedRemote(let origin) = compatibility.trust {
            if config.allowJavaScript {
                Logger.warning("HTML wallpaper: dropping JS for untrusted origin \(origin.rawValue)", category: .screenManager)
            }
            if !config.muteAudio || config.audioVolume > 0 {
                Logger.warning("HTML wallpaper: force-muting untrusted origin \(origin.rawValue)", category: .screenManager)
            }
        }
        if compatibility.enabledPhysicalPixelLayout {
            Logger.info("HTML wallpaper: detected Wallpaper Engine project — enabling physical-pixel layout", category: .screenManager)
        }

        let htmlView = HTMLWallpaperView(
            frame: frame,
            initialEphemeral: effective.requiresEphemeralStorage,
            bookmarkResolver: bookmarkResolver,
            onBookmarkRefresh: onBookmarkRefresh
        )
        window.contentView = htmlView

        let session = AmbientWallpaperSession(window: window, wallpaperType: .html, performanceTarget: htmlView)
        htmlView.onError = { [weak session] error in
            session?.recordRuntimeError(error)
        }

        htmlView.apply(effective)
        htmlView.loadSource(effectiveSource)

        window.setWallpaperMouseInteractionEnabled(config.allowMouseInteraction)
        return session
    }

    /// Local HTML preflight (internal for tests without WebKit).
    func refreshingHTMLSource(
        _ source: HTMLSource,
        onBookmarkRefresh: BookmarkRefreshHandler = { _, _ in }
    ) -> HTMLSource {
        guard let original = source.localBookmarkData,
              case .success(let resolved) = bookmarkResolver.resolve(
                original,
                target: .transient
              ),
              resolved.didRefresh,
              let refreshedSource = source.replacingLocalBookmark(
                matching: original,
                with: resolved.bookmarkData
              ) else { return source }
        onBookmarkRefresh(original, resolved.bookmarkData)
        return refreshedSource
    }

    #if !LITE_BUILD
    func makeSceneSession(
        descriptor: SceneDescriptor,
        origin: WPEOrigin? = nil,
        frame: CGRect,
        dependencyMounts: [WPEAssetMount] = [],
        engineAssetsRootURL: URL? = nil,
        applicationSupportRootURL: URL? = nil,
        fileManager: FileManager = .default,
        onOriginBookmarkRefresh: @escaping WPEOriginRefreshHandler = { _, _ in }
    ) -> SceneWallpaperSession? {
        let supportRoot: URL
        if let applicationSupportRootURL {
            supportRoot = applicationSupportRootURL
        } else if let resolved = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            supportRoot = resolved.appendingPathComponent("LiveWallpaper", isDirectory: true)
        } else {
            return nil
        }

        guard WPEPathSafety.isSafeCacheRelativePath(descriptor.cacheRelativePath) else {
            Logger.warning("Scene descriptor cache path failed safety check: \(descriptor.cacheRelativePath)", category: .screenManager)
            return nil
        }
        let safeSupportRoot = supportRoot.standardizedFileURL.resolvingSymlinksInPath()
        let cacheURL = safeSupportRoot
            .appendingPathComponent(descriptor.cacheRelativePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard WPEPathSafety.contains(cacheURL, in: safeSupportRoot) else {
            Logger.warning("Scene descriptor cache escapes app support: \(descriptor.cacheRelativePath)", category: .screenManager)
            return nil
        }
        // Only legacy `.cache` needs an extracted directory; package/source read in place.
        guard let assets = sceneAssets(
            descriptor: descriptor,
            origin: origin,
            cacheURL: cacheURL,
            fileManager: fileManager,
            onOriginBookmarkRefresh: onOriginBookmarkRefresh
        ) else {
            Logger.warning("Scene source unavailable for in-place read: \(descriptor.workshopID)", category: .screenManager)
            return nil
        }
        // Legacy `.cache` dir required only when provider fell back to it (nil).
        if descriptor.assetStorage == .cache, assets.provider == nil {
            guard fileManager.fileExists(atPath: cacheURL.path) else {
                Logger.warning("Scene descriptor cache directory missing: \(cacheURL.lastPathComponent)", category: .screenManager)
                return nil
            }
        }

        let entryAvailable: Bool
        if let provider = assets.provider {
            entryAvailable = provider.exists(atRelativePath: descriptor.entryFile)
        } else {
            entryAvailable = (try? SceneResourceResolver(cacheRootURL: cacheURL)
                .resolveExistingFileURL(relativePath: descriptor.entryFile)) != nil
        }
        guard entryAvailable else {
            Logger.warning("Scene descriptor entry file failed safety check: \(descriptor.entryFile)", category: .screenManager)
            return nil
        }

        let rendererFrame = CGRect(origin: .zero, size: frame.size)
        // Metal is the only scene renderer; failure surfaces as loadError.
        guard let device = MTLCreateSystemDefaultDevice() else {
            Logger.warning("Metal scene renderer unavailable on this Mac", category: .screenManager)
            return nil
        }
        // Main-thread surface first, then render actor; no frames until load.
        let backing = WPEOffMainRenderFlag.backing
        let surface = WPERenderSurface(frame: rendererFrame, device: device)
        let renderActor = WPEDisplayRenderActor(backing: backing)
        // Pacing: `.renderThread` uses CADisplayLink pacer; `.main` paces MTKView as before.
        let surfaceControl: any WPESurfaceControl
        switch backing {
        case .main:
            surfaceControl = surface
        case .renderThread:
            surfaceControl = WPERenderThreadFramePacer(surface: surface, renderActor: renderActor)
        }
        let renderer: WPEMetalSceneRenderer
        do {
            renderer = try WPEMetalSceneRenderer(
                descriptor: descriptor,
                cacheRootURL: cacheURL,
                assetProvider: assets.provider,
                projectManifestRootURL: assets.projectRoot,
                dependencyMounts: dependencyMounts,
                engineAssetsRootURL: engineAssetsRootURL,
                surfaceControl: surfaceControl,
                mailbox: surface.mailbox,
                presentLayer: WPEPresentLayer(layer: surface.metalLayer),
                drawableSize: surface.metalLayer.drawableSize,
                device: device
            )
        } catch {
            Logger.warning("Metal scene renderer could not be created: \(error.localizedDescription)", category: .screenManager)
            return nil
        }

        // Surface owns delivery shim → render actor (keeps renderer `sending`-adoptable).
        let shim = WPERenderSurfaceClientShim(renderActor: renderActor, backing: backing)
        surface.attach(client: shim)

        let window = VideoWallpaperWindow(frame: frame)
        window.contentView = surface.mtkView
        window.orderBack(nil)

        // Start CADisplayLink driver when windowed; `.main` mode keeps MTKView pacing.
        if case .renderThread = backing {
            surface.startDisplayLinkDriver(renderActor: renderActor)
        }

        // Adopt renderer into actor then load; session keeps surface (+ shim) alive.
        let session = SceneWallpaperSession(window: window, renderActor: renderActor, surface: surface)
        // Frame/audio activity mirror for the App Nap gate. Installed before the
        // handoff (the renderer must not be touched after adoption); the renderer
        // pushes from its actor, the session consumes on MainActor.
        // Unstructured MainActor hops are not FIFO: deliver latest-wins through
        // a mailbox so a stale idle can't land after (and overwrite) a newer
        // active — the renderer dedups on its side, so a lost transition would
        // never be corrected.
        let activityMailbox = OSAllocatedUnfairLock<WPESceneRuntimeActivity?>(initialState: nil)
        renderer.onRuntimeActivityChange = { [weak session] activity in
            activityMailbox.withLock { $0 = activity }
            Task { @MainActor in
                guard let latest = activityMailbox.withLock({ $0 }) else { return }
                session?.noteRendererRuntimeActivity(latest)
            }
        }
        // One-shot `WPERendererHandoff` (main-built, never touched again); session owns adopt+load task.
        session.startAdoptingRenderer(WPERendererHandoff(renderer: renderer))
        return session
    }

    /// Resolve in-place asset provider + `project.json` root (legacy `.cache` → nil provider).
    /// Returned provider owns the source security scope for its lifetime.
    private func sceneAssets(
        descriptor: SceneDescriptor,
        origin: WPEOrigin?,
        cacheURL: URL,
        fileManager: FileManager,
        onOriginBookmarkRefresh: @escaping WPEOriginRefreshHandler
    ) -> (provider: (any WPESceneAssetProvider)?, projectRoot: URL)? {
        switch descriptor.assetStorage {
        case .cache:
            // Prefer fingerprint-validated extracted cache; fall back to in-place import source.
            if fileManager.fileExists(atPath: cacheURL.path) {
                return (nil, cacheURL)
            }
            if let upgraded = cacheFallbackSourceProvider(
                origin: origin,
                fileManager: fileManager,
                onOriginBookmarkRefresh: onOriginBookmarkRefresh
            ) {
                Logger.info("WPE scene cache absent; reading in place from source for \(descriptor.workshopID)", category: .screenManager)
                return upgraded
            }
            return (nil, cacheURL)
        case .sourceDirectory:
            guard let source = resolveSourceFolder(
                origin: origin,
                onOriginBookmarkRefresh: onOriginBookmarkRefresh
            ) else { return nil }
            let provider = WPESecurityScopedSceneAssetProvider(
                wrapped: WPEDirectorySceneAssetProvider(rootURL: source.url),
                scopedURL: source.url,
                didStartAccessing: source.didStart
            )
            return (provider, source.url)
        case .packageSource(let fileName):
            guard let source = resolveSourceFolder(
                origin: origin,
                onOriginBookmarkRefresh: onOriginBookmarkRefresh
            ) else { return nil }
            let packageURL = source.url.appendingPathComponent(fileName, isDirectory: false)
            guard fileManager.fileExists(atPath: packageURL.path),
                  let pkg = try? WPEPackageSceneAssetProvider(packageURL: packageURL) else {
                if source.didStart { source.url.stopAccessingSecurityScopedResource() }
                Logger.warning("Scene package missing/unreadable: \(packageURL.lastPathComponent)", category: .screenManager)
                return nil
            }
            let provider = WPESecurityScopedSceneAssetProvider(
                wrapped: pkg, scopedURL: source.url, didStartAccessing: source.didStart
            )
            return (provider, source.url)
        }
    }

    /// Resolve source folder from origin bookmark; caller owns security scope.
    private func resolveSourceFolder(
        origin: WPEOrigin?,
        onOriginBookmarkRefresh: @escaping WPEOriginRefreshHandler
    ) -> (url: URL, didStart: Bool)? {
        guard let origin,
              let resolved = refreshingWPEOrigin(
                origin,
                onOriginBookmarkRefresh: onOriginBookmarkRefresh
              ) else { return nil }
        return (resolved.url, resolved.url.startAccessingSecurityScopedResource())
    }

    /// Resolve WPE source owner and carry refreshed bookmark Data back for persistence.
    func refreshingWPEOrigin(
        _ origin: WPEOrigin,
        onOriginBookmarkRefresh: WPEOriginRefreshHandler = { _, _ in }
    ) -> (origin: WPEOrigin, url: URL)? {
        guard case .success(let resolved) = bookmarkResolver.resolve(
            origin.sourceFolderBookmark,
            target: .transient
        ) else {
            return relocatingWPEOrigin(origin)
        }
        guard resolved.didRefresh,
              let refreshedOrigin = origin.replacingSourceFolderBookmark(
                matching: origin.sourceFolderBookmark,
                with: resolved.bookmarkData
              ) else {
            return (origin, resolved.url)
        }
        onOriginBookmarkRefresh(origin, resolved.bookmarkData)
        return (refreshedOrigin, resolved.url)
    }

    /// Dead-bookmark fallback via Steam library id. NOT persisted — a failed resolve
    /// may be an unmounted volume; writing back would irreversibly replace a good source.
    private func relocatingWPEOrigin(_ origin: WPEOrigin) -> (origin: WPEOrigin, url: URL)? {
        guard !origin.workshopID.isEmpty,
              let relocated = relocateWorkshopSource(origin.workshopID),
              case .success(let resolved) = bookmarkResolver.resolve(relocated, target: .transient),
              let relocatedOrigin = origin.replacingSourceFolderBookmark(
                matching: origin.sourceFolderBookmark,
                with: resolved.bookmarkData
              ) else { return nil }
        Logger.info(
            "Relocated workshop \(origin.workshopID) source for this session after its stored bookmark stopped resolving",
            category: .fileAccess
        )
        return (relocatedOrigin, resolved.url)
    }

    /// In-place provider when a `.cache` extract is gone but the import source still resolves.
    private func cacheFallbackSourceProvider(
        origin: WPEOrigin?,
        fileManager: FileManager,
        onOriginBookmarkRefresh: @escaping WPEOriginRefreshHandler
    ) -> (provider: (any WPESceneAssetProvider)?, projectRoot: URL)? {
        guard let source = resolveSourceFolder(
            origin: origin,
            onOriginBookmarkRefresh: onOriginBookmarkRefresh
        ) else { return nil }
        let packageURL = source.url.appendingPathComponent("scene.pkg", isDirectory: false)
        if fileManager.fileExists(atPath: packageURL.path),
           let pkg = try? WPEPackageSceneAssetProvider(packageURL: packageURL) {
            let provider = WPESecurityScopedSceneAssetProvider(
                wrapped: pkg, scopedURL: source.url, didStartAccessing: source.didStart
            )
            return (provider, source.url)
        }
        let provider = WPESecurityScopedSceneAssetProvider(
            wrapped: WPEDirectorySceneAssetProvider(rootURL: source.url),
            scopedURL: source.url,
            didStartAccessing: source.didStart
        )
        return (provider, source.url)
    }
    #endif

}
