import AppKit
import LiveWallpaperCore
import WebKit
// HTMLWebView lives in LiveWallpaperCore (warn-long importer cost).

/// WKWebView-backed HTML wallpaper host.
@MainActor
final class HTMLWallpaperView: NSView, HTMLWallpaperConfigApplying {

    // MARK: - Properties
    let webView: HTMLWebView
    private let folderHandler: FolderURLSchemeHandler
    private let bookmarkResolver: SecurityScopedBookmarkResolver
    private let onBookmarkRefresh: @MainActor (_ original: Data, _ refreshed: Data) -> Void
    private var allowMouseInteraction = false
    /// Re-entry guard: forwarding gestures to `webView` bubbles back through
    /// our nextResponder (`self`) and would stack-overflow without this latch
    /// (`EXC_BAD_ACCESS` first hit in `magnify`; swipe/rotate were latent).
    private var isForwardingGesture = false
    var compiledTrackerRuleList: WKContentRuleList?
    var hasTrackerRulesAttached = false
    var trackerBlockingRequested = false
    private var activeSecurityScopedURL: URL?
    /// `WKWebsiteDataStore` is locked at WKWebView init; track live vs requested
    /// so `apply` can warn that a store swap only takes effect on rebuild.
    private var currentDataStoreIsEphemeral: Bool
    private var pendingEphemeral: Bool
    var lastAppliedConfig: HTMLConfig?
    private var wallpaperEnginePropertyBootstrapScript: String?
    /// Cached `project.json` schema; re-read only on folder swap so slider
    /// applies re-serialize without disk I/O.
    private var wallpaperEnginePropertySchema: WallpaperEngineProjectPropertySchema?
    private var wallpaperEnginePropertySchemaFolder: URL?
    private var wallpaperEngineProjectKey: String?
    var lastSource: HTMLSource?
    /// Capped by `HTMLConfig.maxRetries`; drives exponential backoff.
    var consecutiveFailureCount: Int = 0
    /// PKGV index load is blocking I/O — off MainActor, generation-scoped.
    var packageBackingTask: Task<Void, Never>?
    var packageBackingGeneration: UInt64 = 0
    var restartPackageBackingAfterResume = false
    /// Outside the WebKit host so suspend cancels timers without catch-up.
    lazy var reloadScheduler = HTMLReloadScheduler { [weak self] in
        self?.reloadCurrentSource()
    }
    var isCleaningUp = false
    /// Matches `SceneWallpaperSession`'s absence dwell so both wallpaper kinds
    /// release at the same point in an absence.
    static let hibernationDwell: Duration = .seconds(20)
    /// Generous enough for a cold reload of a heavy WebGL page off a slow volume;
    /// past it a frozen pre-absence snapshot is worse than the live document.
    static let restoreCoverDeadline: Duration = .seconds(15)
    var restoreCoverDeadlineTask: Task<Void, Never>?
    var hibernationState = HibernationPhase()
    let hibernationDwell = AbsenceDwell()
    var mediaLifecycleState = HTMLMediaLifecycleState()
    var mediaPlaybackSuspended: Bool {
        mediaLifecycleState.desiredSuspended
    }
    /// Local `.file`/`.folder` read root; nil for remote/inline so navigation
    /// policy can deny `file://` from untrusted content.
    private var currentLocalReadAccessRoot: URL?
    /// Declared origin for remote `.url` sources; gates same-host scripted
    /// redirects and blocks external `.other` swaps for local/inline.
    private var currentRemoteSourceOrigin: URL?

    /// Last-frame overlay while suspended so the desktop stays static.
    let snapshotOverlay: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleAxesIndependently
        view.imageAlignment = .alignCenter
        view.isHidden = true
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }()
    /// Drops stale `takeSnapshot` replies after a later resume/suspend flip.
    var snapshotGeneration: UInt64 = 0
    /// Drives `.fair` RAF throttle independent of ScreenManager suspend/quality.
    ///
    /// `nonisolated(unsafe)`: only mutated from MainActor code, but deinit
    /// (released on an arbitrary queue) also removes the observer, which Swift 6
    /// can't prove safe.
    nonisolated(unsafe) var thermalObserver: NSObjectProtocol?
    var lastRafThrottleRatio: Int = 1

    var onError: (@MainActor (WallpaperRuntimeError) -> Void)?
    var preparationGeneration: UInt64 = 0
    var completedNavigationGeneration: UInt64?
    var failedPreparationGeneration: UInt64?
    var navigationGenerationState = HTMLNavigationGenerationState()

    // MARK: - Initialization

    init(
        frame frameRect: NSRect,
        initialEphemeral: Bool = false,
        bookmarkResolver: SecurityScopedBookmarkResolver = .shared,
        onBookmarkRefresh: @escaping @MainActor (_ original: Data, _ refreshed: Data) -> Void = { _, _ in }
    ) {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = initialEphemeral
            ? .nonPersistent()
            : .default()

        let handler = FolderURLSchemeHandler()
        configuration.setURLSchemeHandler(handler, forURLScheme: FolderURLSchemeHandler.scheme)
        self.folderHandler = handler
        self.bookmarkResolver = bookmarkResolver
        self.onBookmarkRefresh = onBookmarkRefresh
        self.currentDataStoreIsEphemeral = initialEphemeral
        self.pendingEphemeral = initialEphemeral

        webView = HTMLWebView(frame: NSRect(origin: .zero, size: frameRect.size), configuration: configuration)

        super.init(frame: frameRect)

        configureWebView()
        addSubview(webView)
        snapshotOverlay.frame = bounds
        snapshotOverlay.autoresizingMask = [.width, .height]
        addSubview(snapshotOverlay)
        startObservingThermalState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        packageBackingTask?.cancel()
        hibernationDwell.cancel()
        restoreCoverDeadlineTask?.cancel()
        let url = activeSecurityScopedURL
        if let url {
            Task { @MainActor in
                url.stopAccessingSecurityScopedResource()
            }
        }
        if let token = thermalObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Configuration

    private func configureWebView() {
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.setValue(false, forKey: "drawsBackground")

        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false

        installBaselineUserScripts(for: nil)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]
    }

    private func installBaselineUserScripts(for config: HTMLConfig?) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()

        // Every frame gets the lifecycle controller: an ad or embedded-player
        // iframe owns its own timers, rAF and canvases, none of which the main
        // frame's hooks can reach. The main frame relays the phase down.
        controller.addUserScript(WKUserScript(
            source: HTMLWallpaperRuntimeScript.lifecycleController(
                aggressiveSuspend: config?.aggressiveSuspend ?? false
            ),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        let baseline = makeBaselineScript(for: config)
        controller.addUserScript(WKUserScript(
            source: baseline,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        if let wallpaperEnginePropertyBootstrapScript {
            controller.addUserScript(WKUserScript(
                source: wallpaperEnginePropertyBootstrapScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
    }

    private func makeBaselineScript(for config: HTMLConfig?) -> String {
        let cssLiteral = jsStringLiteral(config?.customCSS ?? "")
        let isBrowsing = (config?.allowMouseInteraction ?? false) ? "true" : "false"
        let physicalPixel = config?.physicalPixelLayout ?? false
        let physicalPixelBootstrap = physicalPixel
            ? HTMLWallpaperRuntimeScript.physicalPixelState(
                enabled: true,
                backingScale: effectiveBackingScaleFactor
            )
            : ""
        let canvasUpgrader = physicalPixel
            ? HTMLWallpaperRuntimeScript.canvasBackingStoreUpgrader()
            : ""
        let cspInjection = (config?.cspEnforcementEnabled ?? false)
            ? HTMLWallpaperRuntimeScript.cspInjection()
            : ""

        let audioController = HTMLWallpaperRuntimeScript.masterAudioController(
            initialVolume: config?.audioVolume ?? 1.0,
            initialMuted: config?.muteAudio ?? false
        )
        let transformController = HTMLWallpaperRuntimeScript.transformController(
            scale: config?.transformScale ?? 1.0,
            translateX: config?.transformTranslateX ?? 0,
            translateY: config?.transformTranslateY ?? 0,
            rotation: config?.transformRotationDegrees ?? 0
        )

        let msaaForcer = HTMLWallpaperRuntimeScript.gpuCanvasMSAAForcer()

        return """
        \(cspInjection)
        \(msaaForcer)
        (function () {
            \(physicalPixelBootstrap)
            \(canvasUpgrader)

            function bootstrap() {
                if (!document.documentElement) return;
                document.documentElement.classList.add('is-livewallpaper');
                document.documentElement.classList.toggle('lw-browsing-mode', \(isBrowsing));

                if (!document.getElementById('lw-base-css')) {
                    var base = document.createElement('style');
                    base.id = 'lw-base-css';
                    base.textContent = '::-webkit-scrollbar{display:none;}html,body{overflow:hidden;}';
                    (document.head || document.documentElement).appendChild(base);
                }
                if (!document.getElementById('lw-user-css')) {
                    var user = document.createElement('style');
                    user.id = 'lw-user-css';
                    user.textContent = \(cssLiteral);
                    (document.head || document.documentElement).appendChild(user);
                }
            }
            bootstrap();
            // documentStart may run before <head>; re-run once it appears.
            if (!document.head) {
                var mo = new MutationObserver(function () {
                    if (document.head) { bootstrap(); mo.disconnect(); }
                });
                mo.observe(document.documentElement, { childList: true });
            }
        })();
        \(audioController)
        \(transformController)
        """
    }

    // MARK: - Hit Testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard allowMouseInteraction else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Scroll Forwarding

    // Wallpaper windows don't reliably deliver trackpad events into WKWebView.

    override func scrollWheel(with event: NSEvent) {
        guard allowMouseInteraction else {
            super.scrollWheel(with: event)
            return
        }

        // Avoid `webView.scrollWheel` (unreliable + re-entry via responder
        // chain); scroll via JS with natural-scroll sign.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 40.0
        let dx = -Double(event.scrollingDeltaX * scale)
        let dy = -Double(event.scrollingDeltaY * scale)
        guard abs(dx) > 0.1 || abs(dy) > 0.1 else { return }
        let dxLit = HTMLWallpaperRuntimeScript.jsNumber(dx)
        let dyLit = HTMLWallpaperRuntimeScript.jsNumber(dy)
        webView.evaluateJavaScript(
            "window.scrollBy(\(dxLit), \(dyLit));",
            completionHandler: nil
        )
    }

    override func swipe(with event: NSEvent) {
        guard allowMouseInteraction, !isForwardingGesture else {
            super.swipe(with: event)
            return
        }
        isForwardingGesture = true
        defer { isForwardingGesture = false }
        webView.swipe(with: event)
    }

    override func magnify(with event: NSEvent) {
        guard allowMouseInteraction, !isForwardingGesture else {
            super.magnify(with: event)
            return
        }
        isForwardingGesture = true
        defer { isForwardingGesture = false }
        webView.magnify(with: event)
    }

    override func rotate(with event: NSEvent) {
        guard allowMouseInteraction, !isForwardingGesture else {
            super.rotate(with: event)
            return
        }
        isForwardingGesture = true
        defer { isForwardingGesture = false }
        webView.rotate(with: event)
    }

    // MARK: - Public API

    func apply(_ config: HTMLConfig) {
        pendingEphemeral = config.requiresEphemeralStorage
        if let previous = lastAppliedConfig, previous == config {
            return
        }

        let previous = lastAppliedConfig

        // Data store is locked at init; originKind changes require rebuild.
        if let previous, previous.originKind != config.originKind {
            let message = "HTMLWallpaperView.apply called across an originKind change (\(previous.originKind.rawValue) → \(config.originKind.rawValue)); the session must be torn down instead of hot-swapped."
            assertionFailure(message)
            Logger.error(message, category: .screenManager)
        }

        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = config.allowJavaScript
        allowMouseInteraction = config.allowMouseInteraction
        // CSP is opt-in; flip triggers documentStart reload below.
        folderHandler.cspEnforcementEnabled = config.cspEnforcementEnabled

        if currentDataStoreIsEphemeral != pendingEphemeral {
            let requested = pendingEphemeral ? "ephemeral" : "persistent"
            let active = currentDataStoreIsEphemeral ? "ephemeral" : "persistent"
            let reason = config.originKind == .workshopImport
                ? "Workshop content requires ephemeral storage"
                : "user toggled the ephemeral storage preference"
            Logger.warning(
                "HTML wallpaper requested \(requested) storage (\(reason)) but the live WKWebView still uses the \(active) data store; the change applies on next session rebuild.",
                category: .screenManager
            )
        }

        applyRuntimeState(previous: previous, current: config)

        if wallpaperEnginePropertySchema != nil {
            let previousProjectOverrides = previous?.projectWallpaperEngineProperties(
                forProjectKey: wallpaperEngineProjectKey
            ) ?? [:]
            let currentProjectOverrides = config.projectWallpaperEngineProperties(
                forProjectKey: wallpaperEngineProjectKey
            )
            if previous?.muteAudio != config.muteAudio
                || previous?.audioVolume != config.audioVolume
                || previousProjectOverrides != currentProjectOverrides {
                updateWallpaperEnginePropertyBridge(
                    for: wallpaperEnginePropertySchemaFolder,
                    config: config
                )
            }
        }

        let needsScriptRebuild = (previous?.customCSS != config.customCSS)
            || (previous?.allowMouseInteraction != config.allowMouseInteraction)
            || (previous?.allowJavaScript != config.allowJavaScript)
            || (previous?.requiresEphemeralStorage != config.requiresEphemeralStorage)
            || (previous?.physicalPixelLayout != config.physicalPixelLayout)
            || (previous?.cspEnforcementEnabled != config.cspEnforcementEnabled)
            || (previous?.aggressiveSuspend != config.aggressiveSuspend)

        if needsScriptRebuild {
            installBaselineUserScripts(for: config)
        }

        if previous?.blockTrackers != config.blockTrackers {
            applyTrackerBlocking(enabled: config.blockTrackers)
        }

        if previous?.refreshIntervalSeconds != config.refreshIntervalSeconds {
            applyRefreshInterval(config.refreshIntervalSeconds)
        }

        if config.allowMouseInteraction, let host = webView.window {
            host.makeFirstResponder(webView)
        }

        let needsDocumentStartReload = previous != nil && (
            previous?.physicalPixelLayout != config.physicalPixelLayout
            || previous?.cspEnforcementEnabled != config.cspEnforcementEnabled
            || previous?.aggressiveSuspend != config.aggressiveSuspend
        )
        lastAppliedConfig = config

        if needsDocumentStartReload {
            // documentStart hooks (CSP, canvas upgrader, GPU release) need a reload.
            reloadCurrentSource()
        }
    }

    func applyHTMLConfig(_ config: HTMLConfig) -> Bool {
        if currentDataStoreIsEphemeral != config.requiresEphemeralStorage {
            return false
        }
        if let previous = lastAppliedConfig,
           previous.requiresEphemeralStorage != config.requiresEphemeralStorage {
            return false
        }
        // Data store locked at init — originKind change forces rebuild.
        if let previous = lastAppliedConfig, previous.originKind != config.originKind {
            return false
        }
        apply(config)
        return true
    }

    func captureLivePreviewSnapshot(maxWidth: CGFloat = 960) async -> NSImage? {
        if !snapshotOverlay.isHidden, let image = snapshotOverlay.image {
            return image
        }

        let snapshotBounds = webView.bounds
        guard snapshotBounds.width > 0, snapshotBounds.height > 0 else { return nil }

        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.rect = snapshotBounds
        snapshotConfig.snapshotWidth = NSNumber(value: Double(min(maxWidth, snapshotBounds.width)))
        snapshotConfig.afterScreenUpdates = false

        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: snapshotConfig) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private func applyRuntimeState(previous: HTMLConfig?, current: HTMLConfig) {
        var statements: [String] = []
        let audioChanged = previous?.muteAudio != current.muteAudio
            || previous?.audioVolume != current.audioVolume
        let previousProjectOverrides = previous?.projectWallpaperEngineProperties(
            forProjectKey: wallpaperEngineProjectKey
        ) ?? [:]
        let currentProjectOverrides = current.projectWallpaperEngineProperties(
            forProjectKey: wallpaperEngineProjectKey
        )
        let projectOverridesChanged = previousProjectOverrides != currentProjectOverrides

        if previous?.customCSS != current.customCSS {
            let literal = jsStringLiteral(current.customCSS ?? "")
            statements.append("""
            (function(){var el=document.getElementById('lw-user-css');if(el){el.textContent=\(literal);}})();
            """)
        }

        if previous?.allowMouseInteraction != current.allowMouseInteraction {
            let flag = current.allowMouseInteraction ? "true" : "false"
            statements.append("""
            document.documentElement&&document.documentElement.classList.toggle('lw-browsing-mode',\(flag));
            """)
        }

        if audioChanged {
            let volumeLiteral = HTMLWallpaperRuntimeScript.jsNumber(current.audioVolume)
            let mutedLiteral = current.muteAudio ? "true" : "false"
            statements.append("""
            if (typeof window.__lwUpdateAudio__ === 'function') { window.__lwUpdateAudio__(\(volumeLiteral), \(mutedLiteral)); }
            """)
        }

        if previous?.transformScale != current.transformScale
            || previous?.transformTranslateX != current.transformTranslateX
            || previous?.transformTranslateY != current.transformTranslateY
            || previous?.transformRotationDegrees != current.transformRotationDegrees {
            let scaleLiteral = HTMLWallpaperRuntimeScript.jsNumber(current.transformScale)
            let txLiteral = HTMLWallpaperRuntimeScript.jsNumber(current.transformTranslateX)
            let tyLiteral = HTMLWallpaperRuntimeScript.jsNumber(current.transformTranslateY)
            let rLiteral = HTMLWallpaperRuntimeScript.jsNumber(current.transformRotationDegrees)
            statements.append("""
            if (typeof window.__lwUpdateTransform__ === 'function') { window.__lwUpdateTransform__(\(scaleLiteral), \(txLiteral), \(tyLiteral), \(rLiteral)); }
            """)
        }

        if projectOverridesChanged,
           let schema = wallpaperEnginePropertySchema,
           let script = WallpaperEngineWebPropertyBridge.applyScript(
               schema: schema,
               previousOverrides: previousProjectOverrides,
               overrides: currentProjectOverrides
        ) {
            statements.append(script)
        }
        if (audioChanged || (projectOverridesChanged && (current.muteAudio || current.audioVolume < 0.999))),
           let script = wallpaperEngineAudioControlScript(for: current) {
            statements.append(script)
        }

        if previous?.physicalPixelLayout != current.physicalPixelLayout {
            statements.append(HTMLWallpaperRuntimeScript.physicalPixelState(
                enabled: current.physicalPixelLayout,
                backingScale: effectiveBackingScaleFactor
            ))
        }

        guard !statements.isEmpty else { return }
        webView.evaluateJavaScript(statements.joined(separator: "\n"), completionHandler: nil)
    }

    // MARK: - Auto-Refresh

    /// Scheduler adds ±10% jitter so multi-screen dashboards don't lockstep-hit APIs.
    private func applyRefreshInterval(_ seconds: Int) {
        guard !isCleaningUp else { return }
        reloadScheduler.setRefreshInterval(seconds: TimeInterval(seconds))
    }

    func loadSource(_ source: HTMLSource) {
        loadSource(source, resetFailureCount: true)
    }

    /// User-driven loads reset the retry budget; `scheduleRetry` keeps it.
    private func loadSource(
        _ source: HTMLSource,
        resetFailureCount: Bool,
        allowsPackageBackingWhileSuspended: Bool = false
    ) {
        hibernationState.noteRebuildStarted()
        preparationGeneration &+= 1
        let navigationGeneration = preparationGeneration
        completedNavigationGeneration = nil
        failedPreparationGeneration = nil
        packageBackingTask?.cancel()
        packageBackingTask = nil
        packageBackingGeneration &+= 1
        let packageGeneration = packageBackingGeneration
        lastSource = source
        wallpaperEngineProjectKey = WallpaperEngineProjectIdentity.key(source: source)
        if resetFailureCount {
            resetNavigationFailureState()
        }
        stopActiveSecurityScope()
        var effectiveSource = source
        var resolvedLocalURL: URL?
        if source.localBookmarkData != nil {
            guard let resolved = resolveLocalSource(source) else {
                reportError(.sandboxRevoked)
                return
            }
            effectiveSource = resolved.source
            resolvedLocalURL = resolved.url
            // Bookmark refresh: keep recreated Data, not the stale input.
            lastSource = effectiveSource
            wallpaperEngineProjectKey = WallpaperEngineProjectIdentity.key(source: effectiveSource)
        }
        if case .folder = effectiveSource {
        } else {
            updateWallpaperEnginePropertyBridge(for: nil)
            folderHandler.folderURL = nil
        }
        switch effectiveSource {
        case .file:
            guard let url = resolvedLocalURL else { return }
            activeSecurityScopedURL = url
            let readRoot = Self.readAccessRoot(forFileURL: url)
            currentLocalReadAccessRoot = readRoot
            currentRemoteSourceOrigin = nil
            navigationGenerationState.registerHostNavigation(
                webView.loadFileURL(url, allowingReadAccessTo: readRoot),
                generation: navigationGeneration
            )
        case .folder(_, let indexFileName):
            guard let folderURL = resolvedLocalURL else { return }
            activeSecurityScopedURL = folderURL
            currentLocalReadAccessRoot = folderURL
            currentRemoteSourceOrigin = nil
            updateWallpaperEnginePropertyBridge(for: folderURL)
            folderHandler.folderURL = folderURL
            // Optional scene.pkg backend; set after folderURL (which clears it).
            guard let nonce = folderHandler.currentSessionNonce else {
                Logger.error("HTML folder load: missing session nonce for \(indexFileName)", category: .screenManager)
                return
            }
            let escapedIndex = indexFileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? indexFileName
            let urlString = "\(FolderURLSchemeHandler.scheme)://\(FolderURLSchemeHandler.host)/\(escapedIndex)?n=\(nonce)"
            guard let url = URL(string: urlString) else {
                Logger.error("HTML folder load: failed to build scheme URL for \(indexFileName)", category: .screenManager)
                return
            }
            let request = URLRequest(url: url)
            let pkgURL = folderURL.appendingPathComponent("scene.pkg")
            guard FileManager.default.fileExists(atPath: pkgURL.path) else {
                navigationGenerationState.registerHostNavigation(
                    webView.load(request),
                    generation: navigationGeneration
                )
                return
            }
            guard !mediaPlaybackSuspended || allowsPackageBackingWhileSuspended else {
                restartPackageBackingAfterResume = true
                return
            }
            // User retry may load while suspended; clears the resume-pending flag.
            restartPackageBackingAfterResume = false

            packageBackingTask = Task { [weak self] in
                let backing: FolderURLSchemeHandler.PackageBacking?
                do {
                    backing = try await Self.packageBacking(forPackageURL: pkgURL)
                } catch is CancellationError {
                    return
                } catch {
                    let reasonCode = (error as? WPEPackageError)?.stableReasonCode
                        ?? "PKG_INDEX_LOAD_FAILED"
                    Logger.info(
                        "HTML folder load: scene.pkg rejected [\(reasonCode)] — serving loose files only",
                        category: .screenManager
                    )
                    backing = nil
                }
                guard !Task.isCancelled,
                      let self,
                      !self.isCleaningUp,
                      self.packageBackingGeneration == packageGeneration,
                      self.folderHandler.folderURL == folderURL else { return }
                self.packageBackingTask = nil
                self.folderHandler.setPackageBacking(backing)
                self.navigationGenerationState.registerHostNavigation(
                    self.webView.load(request),
                    generation: navigationGeneration
                )
            }
        case .url(let url):
            guard HTMLWallpaperView.isAllowedRemoteURL(url) else { return }
            currentLocalReadAccessRoot = nil
            currentRemoteSourceOrigin = url
            navigationGenerationState.registerHostNavigation(
                webView.load(URLRequest(url: url)),
                generation: navigationGeneration
            )
        case .inline(let html):
            currentLocalReadAccessRoot = nil
            currentRemoteSourceOrigin = nil
            navigationGenerationState.registerHostNavigation(
                webView.loadHTMLString(html, baseURL: nil),
                generation: navigationGeneration
            )
        }
    }

    /// User retry may prepare package backing while suspended; auto refresh does not.
    func loadSourceForUserRetry(_ source: HTMLSource) {
        loadSource(
            source,
            resetFailureCount: true,
            allowsPackageBackingWhileSuspended: true
        )
    }

    /// Utility-queue PKGV parse; typed rejection → loose-file fallback by caller.
    private static func packageBacking(
        forPackageURL pkgURL: URL
    ) async throws -> FolderURLSchemeHandler.PackageBacking {
        let prepared = try await WPEPackageIndexLoader.load(from: pkgURL)
        defer { try? prepared.handle.close() }
        try Task.checkCancellation()
        return FolderURLSchemeHandler.PackageBacking(url: pkgURL, package: prepared.package)
    }

    private func updateWallpaperEnginePropertyBridge(for folderURL: URL?, config: HTMLConfig? = nil) {
        // Re-parse project.json only on folder change.
        if folderURL != wallpaperEnginePropertySchemaFolder {
            wallpaperEnginePropertySchemaFolder = folderURL
            wallpaperEnginePropertySchema = folderURL.flatMap {
                WallpaperEngineWebPropertyBridge.parseSchema(forFolder: $0)
            }
        }

        let activeConfig = config ?? lastAppliedConfig
        let nextScript: String? = {
            guard let schema = wallpaperEnginePropertySchema else { return nil }
            var overrides = activeConfig?.projectWallpaperEngineProperties(
                forProjectKey: wallpaperEngineProjectKey
            ) ?? [:]
            if let activeConfig {
                overrides.merge(WallpaperEngineWebPropertyBridge.audioBootstrapOverrides(
                    schema: schema,
                    projectOverrides: overrides,
                    volume: activeConfig.audioVolume,
                    muted: activeConfig.muteAudio
                )) { _, audioOverride in audioOverride }
            }
            return WallpaperEngineWebPropertyBridge.bootstrapScript(
                schema: schema,
                overrides: overrides
            )
        }()
        guard wallpaperEnginePropertyBootstrapScript != nextScript else { return }
        wallpaperEnginePropertyBootstrapScript = nextScript
        installBaselineUserScripts(for: activeConfig)
    }

    private func wallpaperEngineAudioControlScript(for config: HTMLConfig?) -> String? {
        guard let config,
              let schema = wallpaperEnginePropertySchema else { return nil }
        return WallpaperEngineWebPropertyBridge.audioControlScript(
            schema: schema,
            projectOverrides: config.projectWallpaperEngineProperties(
                forProjectKey: wallpaperEngineProjectKey
            ),
            volume: config.audioVolume,
            muted: config.muteAudio
        )
    }

    func reloadCurrentSource() {
        guard let lastSource else { return }
        loadSource(lastSource, resetFailureCount: false)
    }

    private func stopActiveSecurityScope() {
        activeSecurityScopedURL?.stopAccessingSecurityScopedResource()
        activeSecurityScopedURL = nil
        currentLocalReadAccessRoot = nil
        currentRemoteSourceOrigin = nil
    }

    nonisolated static let aboutBlank = URL(string: "about:blank")!

    nonisolated static func isAllowedRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    nonisolated static func isSameOrigin(navigationURL: URL, current: URL?) -> Bool {
        guard let current,
              let lhsScheme = navigationURL.scheme?.lowercased(),
              let rhsScheme = current.scheme?.lowercased(),
              let lhsHost = navigationURL.host?.lowercased(),
              let rhsHost = current.host?.lowercased(),
              lhsScheme == rhsScheme,
              lhsHost == rhsHost else { return false }

        return effectivePort(for: navigationURL, scheme: lhsScheme)
            == effectivePort(for: current, scheme: rhsScheme)
    }

    static func readAccessRoot(forFileURL url: URL) -> URL {
        url.deletingLastPathComponent()
    }

    /// Pure policy result; `.openExternally` keeps `decidePolicyFor` side-effect-free.
    enum NavigationDecision: Equatable {
        case allow
        case cancel
        case openExternally(URL)
    }

    /// Security-scope containment after symlink resolution (blocks `../` escapes).
    nonisolated static func fileURL(_ url: URL, isContainedIn root: URL?) -> Bool {
        guard let root, url.isFileURL, root.isFileURL else { return false }
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let normalizedBase = base.hasSuffix("/") ? base : base + "/"
        return target == base || target.hasPrefix(normalizedBase)
    }

    /// Navigation policy: local `file://` only inside read root; remote `.other`
    /// stays same-origin to `remoteSourceOrigin`; local/inline never swap to http(s).
    nonisolated static func navigationDecision(
        for url: URL?,
        navigationType: WKNavigationType,
        currentURL: URL?,
        allowMouseInteraction: Bool,
        localReadAccessRoot: URL?,
        remoteSourceOrigin: URL? = nil
    ) -> NavigationDecision {
        switch navigationType {
        case .other, .reload:
            guard let url else { return .cancel }
            // `about:blank` is what WebKit reports for `loadHTMLString` (every
            // inline wallpaper) and for the hibernation teardown. Cancelling it
            // left inline sources as a permanently empty document, silently:
            // the resulting `NSURLErrorCancelled` is swallowed by
            // `shouldIgnoreNavigationFailure`. Exact match, not the `about:`
            // scheme — a page navigating itself blank is the worst it allows.
            if url == Self.aboutBlank { return .allow }
            if url.isFileURL {
                return fileURL(url, isContainedIn: localReadAccessRoot) ? .allow : .cancel
            }
            if url.scheme?.lowercased() == FolderURLSchemeHandler.scheme { return .allow }
            if isAllowedRemoteURL(url) {
                if let remoteSourceOrigin {
                    return isSameOrigin(
                        navigationURL: url,
                        current: remoteSourceOrigin
                    ) ? .allow : .cancel
                }
                return isSameOrigin(navigationURL: url, current: currentURL) ? .allow : .cancel
            }
            return .cancel

        case .linkActivated:
            guard allowMouseInteraction, let url else { return .cancel }
            if url.isFileURL {
                return fileURL(url, isContainedIn: localReadAccessRoot) ? .allow : .cancel
            }
            if isSameOrigin(navigationURL: url, current: currentURL) { return .allow }
            if isAllowedRemoteURL(url) { return .openExternally(url) }
            return .cancel

        case .formSubmitted, .backForward, .formResubmitted:
            return .cancel

        @unknown default:
            return .cancel
        }
    }

    private func reportError(_ error: WallpaperRuntimeError) {
        failedPreparationGeneration = preparationGeneration
        onError?(error)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        webView.frame = bounds
        snapshotOverlay.frame = bounds
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyPhysicalPixelRuntimeStateIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPhysicalPixelRuntimeStateIfNeeded()
    }

    // MARK: - Physical-pixel layout (WPE compatibility)

    private var effectiveBackingScaleFactor: CGFloat {
        webView.window?.backingScaleFactor
            ?? window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
    }

    private func applyPhysicalPixelRuntimeStateIfNeeded() {
        guard lastAppliedConfig?.physicalPixelLayout == true else { return }
        webView.evaluateJavaScript(
            HTMLWallpaperRuntimeScript.physicalPixelState(
                enabled: true,
                backingScale: effectiveBackingScaleFactor
            ),
            completionHandler: nil
        )
    }

    // MARK: - Cleanup

    func cleanup() {
        isCleaningUp = true
        hibernationDwell.cancel()
        restoreCoverDeadlineTask?.cancel()
        restoreCoverDeadlineTask = nil
        hibernationState.invalidate()
        mediaLifecycleState.invalidate()
        navigationGenerationState.invalidate()
        packageBackingGeneration &+= 1
        packageBackingTask?.cancel()
        packageBackingTask = nil
        restartPackageBackingAfterResume = false
        trackerBlockingRequested = false
        reloadScheduler.invalidate()
        onError = nil
        if let token = thermalObserver {
            NotificationCenter.default.removeObserver(token)
            thermalObserver = nil
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
        if let list = compiledTrackerRuleList, hasTrackerRulesAttached {
            webView.configuration.userContentController.remove(list)
            hasTrackerRulesAttached = false
        }
        folderHandler.folderURL = nil
        stopActiveSecurityScope()
        snapshotOverlay.image = nil
        snapshotOverlay.isHidden = true
    }

    // MARK: - Bookmark Resolution

    private struct ResolvedLocalSource {
        let source: HTMLSource
        let url: URL
    }

    /// Resolve + start security scope once; fail-open is not used — missing
    /// scope returns nil. Refreshed bookmark is pushed to the owner before load.
    private func resolveLocalSource(_ source: HTMLSource) -> ResolvedLocalSource? {
        guard let original = source.localBookmarkData else { return nil }
        let resolved: SecurityScopedBookmarkResolver.Resolved
        switch bookmarkResolver.resolve(original, target: .transient) {
        case .success(let value):
            resolved = value
        case .failure(let failure):
            Logger.warning(
                "HTMLWallpaperView: bookmark resolution failed — \(failure.localizedDescription)",
                category: .screenManager
            )
            return nil
        }
        let effectiveSource: HTMLSource
        if resolved.didRefresh,
           let refreshed = source.replacingLocalBookmark(
            matching: original,
            with: resolved.bookmarkData
           ) {
            effectiveSource = refreshed
            onBookmarkRefresh(original, resolved.bookmarkData)
        } else {
            effectiveSource = source
        }
        let url = resolved.url
        guard url.startAccessingSecurityScopedResource() else {
            Logger.warning("HTMLWallpaperView: startAccessingSecurityScopedResource failed for \(url.lastPathComponent) — sandbox extension is no longer valid; user must re-pick the source.", category: .screenManager)
            return nil
        }
        return ResolvedLocalSource(source: effectiveSource, url: url)
    }

}

extension HTMLWallpaperView: WallpaperPerformanceConfigurable {}

extension HTMLWallpaperView: WallpaperResourceCleanable {}

// MARK: - WKNavigationDelegate

extension HTMLWallpaperView: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation!
    ) {
        navigationGenerationState.registerWebKitNavigationIfNeeded(
            navigation,
            currentGeneration: preparationGeneration
        )
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        // Subframes keep WebKit isolation; only the main frame is privileged.
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
            return
        }
        let decision = HTMLWallpaperView.navigationDecision(
            for: navigationAction.request.url,
            navigationType: navigationAction.navigationType,
            currentURL: webView.url,
            allowMouseInteraction: allowMouseInteraction,
            localReadAccessRoot: currentLocalReadAccessRoot,
            remoteSourceOrigin: currentRemoteSourceOrigin
        )
        switch decision {
        case .allow:
            decisionHandler(.allow)
        case .cancel:
            decisionHandler(.cancel)
        case .openExternally(let url):
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigationGenerationState.consumeIfCurrent(
            navigation,
            currentGeneration: preparationGeneration
        ) else { return }
        resetNavigationFailureState()
        completedNavigationGeneration = preparationGeneration
        let volume = HTMLWallpaperRuntimeScript.jsNumber(lastAppliedConfig?.audioVolume ?? 1.0)
        let muted = lastAppliedConfig?.muteAudio == true ? "true" : "false"
        let wallpaperEngineAudioNudge = wallpaperEngineAudioControlScript(for: lastAppliedConfig) ?? ""
        let nudge = """
        (function() {
            if (typeof window.__lwUpdateAudio__ === 'function') {
                try { window.__lwUpdateAudio__(\(volume), \(muted)); } catch (e) {}
            }
            var elements = document.querySelectorAll('video, audio');
            elements.forEach(function(el) {
                if (el.paused && el.autoplay !== false) {
                    try {
                        var promise = el.play();
                        if (promise && typeof promise.catch === 'function') {
                            promise.catch(function() {});
                        }
                    } catch (e) {}
                }
            });
        })();
        \(wallpaperEngineAudioNudge)
        """
        webView.evaluateJavaScript(nudge, completionHandler: nil)
        notifyWallpaperEngineGeneralProperties(fps: mediaPlaybackSuspended ? 1 : 60)
        // Suspended reload re-inits user scripts — re-apply lifecycle + snapshot.
        if mediaPlaybackSuspended {
            invokeLifecycleHook(.suspend)
            captureSuspendSnapshot()
        } else if hibernationState.didRestore() {
            restoreCoverDeadlineTask?.cancel()
            restoreCoverDeadlineTask = nil
            hideSnapshotOverlay()
        }
        lastRafThrottleRatio = 1
        applyRafThrottleRatio(rafThrottleRatio(for: ProcessInfo.processInfo.thermalState))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        let isCurrent = navigationGenerationState.consumeIfCurrent(
            navigation,
            currentGeneration: preparationGeneration
        )
        guard isCurrent, !shouldIgnoreNavigationFailure(nsError) else { return }
        Logger.error(
            "HTML wallpaper didFail [domain=\(nsError.domain) code=\(nsError.code)] url=\(webView.url?.absoluteString ?? "<no url>") — \(nsError.localizedDescription)",
            category: .screenManager
        )
        if shouldRetryNavigationFailure() { return }
        reportError(.webNavigationFailed(
            navigationFailureURL(webView: webView, error: nsError),
            code: nsError.code,
            description: nsError.localizedDescription
        ))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        let isCurrent = navigationGenerationState.consumeIfCurrent(
            navigation,
            currentGeneration: preparationGeneration
        )
        guard isCurrent, !shouldIgnoreNavigationFailure(nsError) else { return }
        Logger.error(
            "HTML wallpaper didFailProvisionalNavigation [domain=\(nsError.domain) code=\(nsError.code)] url=\(webView.url?.absoluteString ?? "<no url>") — \(nsError.localizedDescription)",
            category: .screenManager
        )
        if shouldRetryNavigationFailure() { return }
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorNotConnectedToInternet {
            reportError(.networkOffline)
        } else {
            reportError(.webNavigationFailed(
                navigationFailureURL(webView: webView, error: nsError),
                code: nsError.code,
                description: nsError.localizedDescription
            ))
        }
    }

    /// No `didFail` on process death — recover via shared retry budget (not a hot loop).
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isCleaningUp else { return }
        Logger.error(
            "HTML wallpaper WebContent process terminated; reloading source. url=\(webView.url?.absoluteString ?? "<no url>")",
            category: .screenManager
        )
        if shouldRetryNavigationFailure() { return }
        reportError(.webNavigationFailed(
            webView.url ?? Self.aboutBlank,
            code: nil,
            description: String(
                localized: "The web renderer process crashed repeatedly.",
                comment: "Runtime error detail shown when an HTML wallpaper's WebKit content process keeps crashing and the retry budget is exhausted."
            )
        ))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
            Logger.warning("HTML wallpaper response: HTTP \(response.statusCode) for host \(response.url?.host ?? "?")", category: .screenManager)
            let failingURL = response.url ?? webView.url ?? Self.aboutBlank
            reportError(.webNavigationFailed(failingURL, code: response.statusCode, description: "HTTP \(response.statusCode)"))
        }
        decisionHandler(.allow)
    }
}

// MARK: - WKUIDelegate

extension HTMLWallpaperView: WKUIDelegate {
    /// `window.open` has no user-gesture guarantee — always refuse.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // scheme+host only — full URLs may carry tokens into persistent logs.
        let target = navigationAction.request.url
        Logger.warning(
            "HTML wallpaper blocked window.open() to \(target.map { "\($0.scheme ?? "?")://\($0.host ?? "?")" } ?? "<no url>")",
            category: .screenManager
        )
        return nil
    }
}

// MARK: - JS literal helper

private func jsStringLiteral(_ value: String) -> String {
    if let data = try? JSONEncoder().encode(value),
       let literal = String(data: data, encoding: .utf8) {
        return literal
    }
    return "\"\""
}

private func effectivePort(for url: URL, scheme: String) -> Int? {
    if let port = url.port { return port }
    switch scheme {
    case "http": return 80
    case "https": return 443
    default: return nil
    }
}
