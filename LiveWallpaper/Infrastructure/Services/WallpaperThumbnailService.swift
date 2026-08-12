import AppKit
@preconcurrency import AVFoundation
import WebKit

/// In-memory thumbnails for video (first frame) and HTML (`WKWebView.takeSnapshot`).
@MainActor
final class WallpaperThumbnailService {
    static let shared = WallpaperThumbnailService()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        // ~64 MB byte ceiling (count cap alone could pin ~125 MB of RGBA thumbs).
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    /// Dedup: re-entering for the same key returns the same task, not a parallel snapshot.
    private var inFlightVideoTasks: [String: Task<NSImage?, Never>] = [:]

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

    private init() {}

    func cachedThumbnail(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func videoPosterImage(for url: URL, cacheKey: String) async -> NSImage? {
        if let cached = cachedThumbnail(forKey: cacheKey) { return cached }
        if let inFlight = inFlightVideoTasks[cacheKey] { return await inFlight.value }

        let task = Task<NSImage?, Never> { [cache] in
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }

            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 270)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

            do {
                let (cgImage, _) = try await generator.image(at: .zero)
                let size = NSSize(width: cgImage.width, height: cgImage.height)
                let image = NSImage(cgImage: cgImage, size: size)
                cache.setObject(image, forKey: cacheKey as NSString, cost: Self.estimatedCost(of: cgImage))
                return image
            } catch {
                return nil
            }
        }

        inFlightVideoTasks[cacheKey] = task
        let result = await task.value
        inFlightVideoTasks.removeValue(forKey: cacheKey)
        return result
    }

    /// width × height × 4 (RGBA) — drives `NSCache.totalCostLimit` so the cache
    /// stays bounded in MB, not just object count.
    private static func estimatedCost(of image: CGImage) -> Int {
        image.width * image.height * 4
    }

    func htmlSnapshotImage(
        request: HTMLSnapshotRequest,
        targetSize: CGSize = CGSize(width: 480, height: 270),
        timeout: TimeInterval = 6
    ) async -> NSImage? {
        if let cached = cachedThumbnail(forKey: request.cacheKey) { return cached }
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
        // Thumbnail capture never needs cookies, service workers, local
        // storage, or other state to outlive this one offscreen web view.
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

        if let image {
            cache.setObject(
                image,
                forKey: request.cacheKey as NSString,
                cost: Self.estimatedCost(of: image)
            )
            return image
        }
        return nil
    }

    private func startHTMLSnapshotProducer(
        request: HTMLSnapshotRequest,
        targetSize: CGSize,
        timeout: TimeInterval,
        producerID: HTMLSnapshotLeaseState.ProducerID
    ) {
        let cacheKey = request.cacheKey
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let image = await self.captureHTMLSnapshot(
                request: request,
                targetSize: targetSize,
                timeout: timeout,
                producerID: producerID
            )
            self.completeHTMLSnapshotProducer(
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
        guard case .cancelProducer(let producerID) = action else { return }
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
