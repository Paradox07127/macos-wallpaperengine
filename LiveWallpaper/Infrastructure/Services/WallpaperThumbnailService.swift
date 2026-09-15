import AppKit
@preconcurrency import AVFoundation
import LiveWallpaperCore
import WebKit

@MainActor
final class WallpaperThumbnailService {
    static let shared = WallpaperThumbnailService()

    /// Internal, not private, only so `LocalImageCacheReclaimerTests` can
    /// observe the purge; every production reader stays in this file.
    let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        // ~64 MB byte ceiling (count cap alone could pin ~125 MB of RGBA thumbs).
        c.totalCostLimit = 64 * 1024 * 1024
        WPEImageCacheMeter.attach(c, as: .wallpaperThumbnail)
        LocalImageCacheRegistry.shared.register(c)
        return c
    }()

    private let videoRequests: PreviewRequestPool<NSImage>
    private let formatRequests: PreviewRequestPool<VideoFormatInfo>
    private let htmlGate: PreviewWorkGate
    private var cacheGenerations: [String: UUID] = [:]

    /// Held strong until snapshot completion — WKWebView fails silently if released mid-load.
    private var pendingWebViews: [
        HTMLSnapshotLeaseState.ProducerID: PendingHTMLSnapshot
    ] = [:]
    private var htmlSnapshotLeaseState = HTMLSnapshotLeaseState()
    private var htmlProducerTasks: [
        HTMLSnapshotLeaseState.ProducerID: Task<Void, Never>
    ] = [:]
    private var htmlWaiters: [
        HTMLSnapshotLeaseState.LeaseID: HTMLSnapshotWaiter
    ] = [:]

    init(videoGate: PreviewWorkGate = .video, htmlGate: PreviewWorkGate = .html) {
        videoRequests = PreviewRequestPool(gate: videoGate)
        formatRequests = PreviewRequestPool(gate: videoGate)
        self.htmlGate = htmlGate
    }

    func cachedThumbnail(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func videoPosterImage(
        for url: URL,
        cacheKey: String,
        tolerance: (before: CMTime, after: CMTime) = (.zero, CMTime(seconds: 1, preferredTimescale: 600))
    ) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        if let cached = cachedThumbnail(forKey: cacheKey) {
            return cached
        }
        let generation = cacheGeneration(for: cacheKey)
        let image = await videoRequests.value(for: cacheKey) {
            let didStart = url.startAccessingSecurityScopedResource()
            defer {
                if didStart {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 270)
            generator.requestedTimeToleranceBefore = tolerance.before
            generator.requestedTimeToleranceAfter = tolerance.after
            return await withTaskCancellationHandler {
                do {
                    let (cgImage, _) = try await generator.image(at: .zero)
                    guard !Task.isCancelled else { return nil }
                    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                } catch { return nil }
            } onCancel: {
                generator.cancelAllCGImageGeneration()
            }
        }
        return cacheGeneratedPreview(image, forKey: cacheKey, generation: generation)
    }

    func videoFormatInfo(for url: URL, cacheKey: String) async -> VideoFormatInfo? {
        await formatRequests.value(for: cacheKey) {
            let didStart = url.startAccessingSecurityScopedResource()
            defer {
                if didStart {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            return try? await PlayableVideoLoader.detectFormat(at: url)
        }
    }

    private func cacheGeneration(for key: String) -> UUID {
        if let generation = cacheGenerations[key] {
            return generation
        }
        let generation = UUID()
        cacheGenerations[key] = generation
        return generation
    }

    private func cacheGeneratedPreview(_ image: NSImage?, forKey key: String, generation: UUID) -> NSImage? {
        guard !Task.isCancelled, cacheGenerations[key] == generation, let image else { return nil }
        let cost = Self.estimatedCost(of: image)
        WPEImageCacheMeter.recordInsert(image, cost: cost, in: .wallpaperThumbnail)
        cache.setObject(image, forKey: key as NSString, cost: cost)
        return image
    }

    func htmlSnapshotImage(
        request: HTMLSnapshotRequest,
        targetSize: CGSize = CGSize(width: 480, height: 270),
        timeout: TimeInterval = 6
    ) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        if let cached = cachedThumbnail(forKey: request.cacheKey) {
            return cached
        }
        let acquisition = htmlSnapshotLeaseState.acquire(cacheKey: request.cacheKey)
        let lease = acquisition.lease
        let waiter = HTMLSnapshotWaiter()
        htmlWaiters[lease.leaseID] = waiter

        if case .start = acquisition {
            startHTMLSnapshotProducer(
                request: request,
                targetSize: targetSize,
                timeout: timeout,
                producerID: lease.producerID
            )
        }

        let image = await withTaskCancellationHandler {
            await waiter.wait()
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelHTMLSnapshotLease(lease)
            }
        }
        return Task.isCancelled ? nil : image
    }

    func invalidate(cacheKey: String) {
        cacheGenerations.removeValue(forKey: cacheKey)
        videoRequests.invalidate(cacheKey)
        formatRequests.invalidate(cacheKey)
        if let invalidated = htmlSnapshotLeaseState.invalidate(cacheKey: cacheKey) {
            htmlProducerTasks.removeValue(forKey: invalidated.producerID)?.cancel()
            cancelPendingHTMLSnapshot(producerID: invalidated.producerID)
            for leaseID in invalidated.leaseIDs {
                htmlWaiters.removeValue(forKey: leaseID)?.resolve(nil)
            }
        }
        cache.removeObject(forKey: cacheKey as NSString)
    }

    // MARK: - HTML snapshot internals

    static func htmlWebViewConfiguration(
        for request: HTMLSnapshotRequest
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = request.effectiveConfig.allowJavaScript
        configuration.defaultWebpagePreferences = preferences
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = false
        return configuration
    }

    private func captureHTMLSnapshot(
        request: HTMLSnapshotRequest,
        targetSize: CGSize,
        timeout: TimeInterval,
        producerID: HTMLSnapshotLeaseState.ProducerID
    ) async -> NSImage? {
        await withTaskCancellationHandler {
            await performHTMLSnapshotCapture(
                request: request,
                targetSize: targetSize,
                timeout: timeout,
                producerID: producerID
            )
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingHTMLSnapshot(producerID: producerID)
            }
        }
    }

    private func performHTMLSnapshotCapture(
        request: HTMLSnapshotRequest,
        targetSize: CGSize,
        timeout: TimeInterval,
        producerID: HTMLSnapshotLeaseState.ProducerID
    ) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let configuration = Self.htmlWebViewConfiguration(for: request)
        if request.effectiveConfig.blockTrackers,
           let trackerRules = await HTMLWallpaperView.preparedTrackerRuleList() {
            configuration.userContentController.add(trackerRules)
        }
        guard !Task.isCancelled else { return nil }
        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: targetSize),
            configuration: configuration
        )

        let pending = PendingHTMLSnapshot(webView: webView, request: request)
        pendingWebViews[producerID] = pending
        webView.navigationDelegate = pending

        let didStart = request.loadURL.isFileURL
            ? request.loadURL.startAccessingSecurityScopedResource()
            : false
        defer {
            pending.cancel()
            if pendingWebViews[producerID] === pending {
                pendingWebViews[producerID] = nil
            }
            webView.navigationDelegate = nil
            if didStart {
                request.loadURL.stopAccessingSecurityScopedResource()
            }
        }

        if request.loadURL.isFileURL {
            let readRoot = request.localReadAccessRoot
                ?? request.loadURL.deletingLastPathComponent()
            webView.loadFileURL(request.loadURL, allowingReadAccessTo: readRoot)
        } else {
            webView.load(URLRequest(url: request.loadURL))
        }

        let timeoutTask = Task<Void, Never> { [weak pending] in
            try? await Task.sleep(for: .seconds(timeout))
            pending?.complete(reason: .timeout)
        }

        let didLoad = await pending.waitForLoadOutcome()
        timeoutTask.cancel()
        guard didLoad, !Task.isCancelled else { return nil }

        do {
            try await Task.sleep(for: .milliseconds(250))
        } catch {
            return nil
        }
        guard !Task.isCancelled else { return nil }

        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.rect = CGRect(origin: .zero, size: targetSize)
        snapshotConfig.afterScreenUpdates = true

        let image = await pending.takeSnapshot(with: snapshotConfig)
        guard !Task.isCancelled else { return nil }

        return image
    }

    private func startHTMLSnapshotProducer(
        request: HTMLSnapshotRequest,
        targetSize: CGSize,
        timeout: TimeInterval,
        producerID: HTMLSnapshotLeaseState.ProducerID
    ) {
        let cacheKey = request.cacheKey
        let generation = cacheGeneration(for: cacheKey)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let captured = await htmlGate.run { @MainActor in
                guard !Task.isCancelled else { return nil as NSImage? }
                return await self.captureHTMLSnapshot(
                    request: request,
                    targetSize: targetSize,
                    timeout: timeout,
                    producerID: producerID
                )
            }
            let image = cacheGeneratedPreview(captured, forKey: cacheKey, generation: generation)
            completeHTMLSnapshotProducer(
                cacheKey: cacheKey,
                producerID: producerID,
                image: image
            )
        }
        htmlProducerTasks[producerID] = task
    }

    private func cancelHTMLSnapshotLease(
        _ lease: HTMLSnapshotLeaseState.Lease
    ) {
        let action = htmlSnapshotLeaseState.release(lease)
        htmlWaiters.removeValue(forKey: lease.leaseID)?.resolve(nil)
        guard case let .cancelProducer(producerID) = action else { return }
        htmlProducerTasks.removeValue(forKey: producerID)?.cancel()
        cancelPendingHTMLSnapshot(producerID: producerID)
    }

    private func completeHTMLSnapshotProducer(
        cacheKey: String,
        producerID: HTMLSnapshotLeaseState.ProducerID,
        image: NSImage?
    ) {
        let leaseIDs = htmlSnapshotLeaseState.complete(
            cacheKey: cacheKey,
            producerID: producerID
        )
        htmlProducerTasks[producerID] = nil
        for leaseID in leaseIDs {
            htmlWaiters.removeValue(forKey: leaseID)?.resolve(image)
        }
    }

    private func cancelPendingHTMLSnapshot(
        producerID: HTMLSnapshotLeaseState.ProducerID
    ) {
        pendingWebViews.removeValue(forKey: producerID)?.cancel()
    }

    /// width × height × 4 (RGBA) — the WebKit snapshot path only exposes an `NSImage`.
    private static func estimatedCost(of image: NSImage) -> Int {
        let pixels = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .map { $0.pixelsWide * $0.pixelsHigh }
            .max()
            ?? Int(image.size.width * image.size.height)
        return pixels * 4
    }
}
