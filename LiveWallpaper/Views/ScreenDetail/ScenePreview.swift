#if !LITE_BUILD
import SwiftUI
import AppKit
import ImageIO
import LiveWallpaperCore

/// How large this preview has to be decoded.
///
/// One cap could not serve both: a gallery tile is ~220 pt, while the detail
/// pane takes `aspectRatio: nil` and fills the window, so on a 2× display it can
/// want several thousand pixels. `.pane` is the default precisely because the
/// expensive mistake is the silent one — a tile that decodes too much only
/// wastes work, a pane that decodes too little visibly softens.
enum WPEPreviewSize {
    /// Gallery tiles: 220 pt square, `resizeAspectFill` from 16:9, 2×.
    case tile
    /// Detail/inspector panes that fill their container.
    case pane

    var maxPixelSize: Int {
        switch self {
        case .tile: return 800
        case .pane: return 2560
        }
    }
}

/// `.autoPlay` is the back-compatible default; grid / list call sites pass `.hoverToPlay`.
enum WPEPreviewPlaybackMode {
    case staticPoster
    case autoPlay
    case hoverToPlay
}

/// CALayer-backed with manual `CGImageSource` frame stepping — NSImageView
/// can't pair its built-in `.animates` with aspect-fill scaling.
struct WPEPreviewView: View {
    let imageURL: URL?
    let securityScopedBookmarkData: Data?
    let playbackMode: WPEPreviewPlaybackMode
    /// `1` (default) yields the square gallery / history tile; `nil` lets the
    /// preview fill the parent's bounds (16:9 inspector cards) and aspect-fill crop.
    let aspectRatio: CGFloat?
    let previewSize: WPEPreviewSize

    @State private var loadAttempt: Int = 0
    @State private var loadFailed: Bool = false
    @State private var isHovering: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        imageURL: URL?,
        securityScopedBookmarkData: Data? = nil,
        playbackMode: WPEPreviewPlaybackMode = .autoPlay,
        aspectRatio: CGFloat? = 1,
        previewSize: WPEPreviewSize = .pane
    ) {
        self.imageURL = imageURL
        self.securityScopedBookmarkData = securityScopedBookmarkData
        self.playbackMode = playbackMode
        self.aspectRatio = aspectRatio
        self.previewSize = previewSize
    }

    private var shouldAnimate: Bool {
        guard !reduceMotion else { return false }
        switch playbackMode {
        case .staticPoster: return false
        case .autoPlay: return true
        case .hoverToPlay: return isHovering
        }
    }

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).opacity(0.5)
            if imageURL == nil {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            } else {
                AspectFillImage(
                    imageURL: imageURL,
                    securityScopedBookmarkData: securityScopedBookmarkData,
                    loadAttempt: loadAttempt,
                    shouldAnimate: shouldAnimate,
                    previewSize: previewSize,
                    onLoadResult: { success in
                        loadFailed = !success
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .modifier(OptionalAspectRatio(aspectRatio))
        .clipped()
        .onHover { hovering in
            if playbackMode == .hoverToPlay { isHovering = hovering }
        }
        .overlay(alignment: .bottomTrailing) {
            if loadFailed {
                retryBadge
                    .padding(6)
            }
        }
        .onChange(of: imageURL) { _, _ in
            loadFailed = false
        }
    }

    /// Tap-gesture'd view, not a `Button`: the parent grid cell is itself a `Button`, and AppKit-bridged buttons nested inside another SwiftUI button race for hit-tests + confuse VoiceOver focus.
    @ViewBuilder
    private var retryBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignTokens.Colors.Status.warning)
            Image(systemName: "arrow.clockwise")
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .contentShape(Capsule())
        .onTapGesture {
            retryLoad()
        }
        .help(Text(
            "Preview unavailable. Tap to retry.",
            comment: "Tooltip on the WPE preview retry badge that surfaces when the preview image failed to load."
        ))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(
            "Retry preview",
            comment: "A11y label for the corner badge that retries a failed preview load."
        ))
        .accessibilityHint(Text(
            "Re-attempt to load this preview",
            comment: "A11y hint describing what the retry preview badge does."
        ))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { retryLoad() }
    }

    private func retryLoad() {
        loadFailed = false
        loadAttempt &+= 1
    }
}

/// The ratio is constant per call site, so the `if`/`else` never flips at runtime and the CALayer-backed image view keeps a stable identity.
private struct OptionalAspectRatio: ViewModifier {
    let ratio: CGFloat?

    init(_ ratio: CGFloat?) { self.ratio = ratio }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let ratio {
            content.aspectRatio(ratio, contentMode: .fit)
        } else {
            content
        }
    }
}

// MARK: - Aspect-fill bridge

/// In-memory cache of *decoded* previews keyed by URL. Caching the raw bytes
/// instead meant every cache hit paid a synchronous main-thread decode, which is
/// exactly the cost a cache is supposed to remove.
///
/// Internal, not private, only so `LocalImageCacheReclaimerTests` can observe
/// the purge; every production reader stays in this file.
enum WPEPreviewDecodedCache {
    // NSCache is thread-safe internally; `nonisolated(unsafe)` just suppresses
    // the Swift 6 Sendable diagnostic since NSCache isn't formally Sendable.
    nonisolated(unsafe) static let shared: NSCache<NSString, WPEPreviewDecodedImage> = {
        let cache = NSCache<NSString, WPEPreviewDecodedImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 64 * 1024 * 1024
        WPEImageCacheMeter.attach(cache, as: .scenePreviewDecoded)
        LocalImageCacheRegistry.shared.register(cache)
        return cache
    }()
}

/// A preview decoded once, off the main thread, and replayed from there.
/// `@unchecked Sendable`: every stored value is immutable, and `CGImageSource`
/// reads are free-threaded.
final class WPEPreviewDecodedImage: @unchecked Sendable {
    let posterFrame: CGImage
    let frameCount: Int
    let frameDelays: [TimeInterval]
    /// `nil` for stills and for animations that blew the pixel budget.
    private let source: CGImageSource?
    private let decodeOptions: CFDictionary
    let estimatedCost: Int

    fileprivate init(
        posterFrame: CGImage,
        frameCount: Int,
        frameDelays: [TimeInterval],
        source: CGImageSource?,
        decodeOptions: CFDictionary,
        encodedByteCount: Int
    ) {
        self.posterFrame = posterFrame
        self.frameCount = frameCount
        self.frameDelays = frameDelays
        self.source = source
        self.decodeOptions = decodeOptions
        let posterBytes = posterFrame.bytesPerRow * posterFrame.height
        let (total, overflow) = posterBytes.addingReportingOverflow(source == nil ? 0 : encodedByteCount)
        estimatedCost = overflow ? Int.max : total
    }

    func frame(at index: Int) -> CGImage? {
        guard index > 0, index < frameCount, let source else { return posterFrame }
        return CGImageSourceCreateThumbnailAtIndex(source, index, decodeOptions)
    }

    /// Runs on a cooperative-pool thread; nothing here touches the main actor.
    static func decode(
        _ data: Data,
        maxPixelSize: Int = WPEPreviewImageDecodeBudget.defaultMaxPixelSize
    ) -> WPEPreviewDecodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, WPEPreviewImageDecodeBudget.sourceOptions) else {
            return nil
        }
        let options = WPEPreviewImageDecodeBudget.thumbnailOptions(maxPixelSize: maxPixelSize)
        let count = CGImageSourceGetCount(source)
        guard count > 0,
              let dimensions = WPEPreviewImageDecodeBudget.imageDimensions(from: source, index: 0),
              // The bomb check stays on the *source* dimensions: that is what a
              // malicious file inflates, and it is known before any decode.
              WPEPreviewImageDecodeBudget.isWithinPixelBudget(
                  width: dimensions.width, height: dimensions.height, frameCount: 1
              ),
              let poster = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }

        // Priced against what playback will actually decode, not the source. A
        // 1080p GIF over ~12 frames used to fall back to a still even though the
        // frames it would decode are now capped at `maxPixelSize`.
        let animates = count > 1 && WPEPreviewImageDecodeBudget.allowsAnimation(
            width: poster.width,
            height: poster.height,
            frameCount: count
        )
        return WPEPreviewDecodedImage(
            posterFrame: poster,
            frameCount: animates ? count : 1,
            frameDelays: animates ? readFrameDelays(from: source, frameCount: count) : [],
            source: animates ? source : nil,
            decodeOptions: options,
            encodedByteCount: data.count
        )
    }

    private static func readFrameDelays(from source: CGImageSource, frameCount: Int) -> [TimeInterval] {
        (0..<frameCount).map { idx in
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, idx, nil) as? [String: Any] else {
                return 0.1
            }
            if let gif = props[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
                if let unclamped = (gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber)?.doubleValue, unclamped > 0 {
                    return max(unclamped, WPEPreviewImageDecodeBudget.minFrameDelay)
                }
                if let delay = (gif[kCGImagePropertyGIFDelayTime as String] as? NSNumber)?.doubleValue, delay > 0 {
                    return max(delay, WPEPreviewImageDecodeBudget.minFrameDelay)
                }
            }
            if let png = props[kCGImagePropertyPNGDictionary as String] as? [String: Any] {
                if let delay = (png[kCGImagePropertyAPNGUnclampedDelayTime as String] as? NSNumber)?.doubleValue, delay > 0 {
                    return max(delay, WPEPreviewImageDecodeBudget.minFrameDelay)
                }
                if let delay = (png[kCGImagePropertyAPNGDelayTime as String] as? NSNumber)?.doubleValue, delay > 0 {
                    return max(delay, WPEPreviewImageDecodeBudget.minFrameDelay)
                }
            }
            return 0.1
        }
    }
}

enum WPEPreviewImageDecodeBudget {
    static let maxFrameCount = 120
    static let maxDecodedPixelBytes = 96 * 1024 * 1024
    static let minFrameDelay: TimeInterval = 0.033
    /// Callers that don't say. `.pane` rather than `.tile`, for the same reason
    /// `WPEPreviewSize.pane` is the view's default.
    static let defaultMaxPixelSize = WPEPreviewSize.pane.maxPixelSize
    nonisolated(unsafe) static let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    /// `ShouldCacheImmediately: true` is what actually moves the decode off the
    /// main thread: without it Image I/O hands back an undecoded `CGImage` and
    /// the pixels are produced later, on whichever thread draws the layer.
    static func thumbnailOptions(maxPixelSize: Int) -> CFDictionary {
        [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
    }

    static func allowsAnimation(width: Int, height: Int, frameCount: Int) -> Bool {
        frameCount <= maxFrameCount && isWithinPixelBudget(width: width, height: height, frameCount: frameCount)
    }

    static func isWithinPixelBudget(width: Int, height: Int, frameCount: Int) -> Bool {
        guard width > 0, height > 0, frameCount > 0 else { return false }
        let w = UInt64(width)
        let h = UInt64(height)
        let n = UInt64(frameCount)
        guard w <= UInt64.max / h else { return false }
        let pixelsPerFrame = w * h
        guard pixelsPerFrame <= UInt64.max / n else { return false }
        let totalPixels = pixelsPerFrame * n
        guard totalPixels <= UInt64.max / 4 else { return false }
        return totalPixels * 4 <= UInt64(maxDecodedPixelBytes)
    }

    static func imageDimensions(from source: CGImageSource, index: Int) -> (width: Int, height: Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
              let width = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue else {
            return nil
        }
        return (width, height)
    }
}

private struct AspectFillImage: NSViewRepresentable {
    let imageURL: URL?
    let securityScopedBookmarkData: Data?
    let loadAttempt: Int
    let shouldAnimate: Bool
    let previewSize: WPEPreviewSize
    let onLoadResult: (Bool) -> Void

    func makeNSView(context: Context) -> AspectFillAnimatedImageView {
        AspectFillAnimatedImageView()
    }

    static func dismantleNSView(_ nsView: AspectFillAnimatedImageView, coordinator: Coordinator) {
        coordinator.cancelInflight()
        coordinator.reset()
        nsView.clearImage()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func updateNSView(_ nsView: AspectFillAnimatedImageView, context: Context) {
        nsView.setAnimating(shouldAnimate)

        guard let url = imageURL else {
            context.coordinator.cancelInflight()
            context.coordinator.reset()
            nsView.clearImage()
            return
        }

        if context.coordinator.currentURL == url,
           context.coordinator.lastAttempt == loadAttempt {
            return
        }

        context.coordinator.currentURL = url
        context.coordinator.lastAttempt = loadAttempt
        context.coordinator.cancelInflight()

        let cacheKey = Self.cacheKey(for: url, size: previewSize)
        if let cacheKey, let cached = WPEPreviewDecodedCache.shared.object(forKey: cacheKey) {
            nsView.apply(cached)
            let resultHandler = onLoadResult
            Task { @MainActor in resultHandler(true) }
            return
        }

        let bookmarkData = securityScopedBookmarkData
        let size = previewSize
        let coordinator = context.coordinator
        let resultHandler = onLoadResult
        let task = Task { @MainActor in
            let decoded = await Self.loadAndDecode(url: url, bookmarkData: bookmarkData, size: size)
            guard !Task.isCancelled, coordinator.currentURL == url else { return }
            if let decoded {
                if let cacheKey {
                    WPEImageCacheMeter.recordInsert(
                        decoded, cost: decoded.estimatedCost, in: .scenePreviewDecoded
                    )
                    WPEPreviewDecodedCache.shared.setObject(decoded, forKey: cacheKey, cost: decoded.estimatedCost)
                }
                nsView.apply(decoded)
                resultHandler(true)
            } else {
                nsView.clearImage()
                resultHandler(false)
            }
        }
        coordinator.inflightTask = task
    }

    /// Carries the modification date, because a Workshop update rewrites
    /// `preview.jpg` at the same path: keyed by URL alone the grid would serve
    /// the pre-update pixels until the entry was evicted, which on a 256-entry
    /// cache is "for the rest of the session".
    ///
    /// `nil` — and therefore no caching at all — when the date cannot be read.
    /// That happens for a security-scoped URL whose scope is only opened inside
    /// `loadAndDecode`, and an entry nothing can invalidate is worse than a
    /// re-decode. The `stat` runs on the main actor, but only when the URL or
    /// the retry counter actually changed, not per frame.
    private static func cacheKey(for url: URL, size: WPEPreviewSize) -> NSString? {
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate else { return nil }
        return "\(modified.timeIntervalSinceReferenceDate)|\(size.maxPixelSize)|\(url.absoluteString)" as NSString
    }

    /// Disk read *and* decode on the cooperative pool. The main actor only ever
    /// assigns the finished `CGImage` to `layer.contents`.
    private static func loadAndDecode(
        url: URL,
        bookmarkData: Data?,
        size: WPEPreviewSize
    ) async -> WPEPreviewDecodedImage? {
        // Shares the Workshop grid's budget: both feed the same library screens,
        // and a Scene tab scrolling next to a downloading Workshop page should
        // not double the number of decodes in flight.
        await PreviewWorkGate.shared.run {
            guard !Task.isCancelled else { return nil }
            let reading = PreviewSignpost.begin("installed.readAndDecode")
            defer { PreviewSignpost.end("installed.readAndDecode", reading) }
            // `Task.detached` does not inherit cancellation; without forwarding
            // it, a preview that scrolled away kept its gate slot until the read
            // and decode finished.
            let work = Task.detached(priority: .userInitiated) { () -> WPEPreviewDecodedImage? in
                guard !Task.isCancelled else { return nil }
                var scopedURL: URL?
                if let bookmarkData {
                    scopedURL = try? SecurityScopedBookmarkResolver.shared
                        .resolve(bookmarkData, target: .transient).get().url
                }
                let didStart = scopedURL?.startAccessingSecurityScopedResource() ?? false
                defer { if didStart { scopedURL?.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url), !Task.isCancelled else { return nil }
                return WPEPreviewDecodedImage.decode(data, maxPixelSize: size.maxPixelSize)
            }
            return await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
        }
    }

    @MainActor
    final class Coordinator {
        var currentURL: URL?
        var lastAttempt: Int = 0
        var inflightTask: Task<Void, Never>?

        func reset() {
            currentURL = nil
            lastAttempt = 0
        }

        func cancelInflight() {
            inflightTask?.cancel()
            inflightTask = nil
        }
    }
}

/// Used instead of `NSImageView` because the latter only offers fit-style scaling — we need fill-with-crop so square 512×512 WPE previews don't render with horizontal letterbox bars.
private final class AspectFillAnimatedImageView: NSView {
    private var decoded: WPEPreviewDecodedImage?
    private var currentFrameIndex: Int = 0
    private var playbackTask: Task<Void, Never>?
    /// Toggled by `setAnimating` so a hover-driven host can freeze the loop on
    /// the poster frame without reloading the image.
    private var wantsAnimation = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let imageLayer = CALayer()
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.frame = bounds
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer = imageLayer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize { .zero }

    /// Main-thread work is one `layer.contents` assignment — the decode already
    /// happened on the cooperative pool.
    func apply(_ image: WPEPreviewDecodedImage) {
        stopPlayback()
        decoded = image
        currentFrameIndex = 0
        layer?.contents = image.posterFrame
        if wantsAnimation, image.frameCount > 1 { startPlayback() }
    }

    /// Starts or freezes playback without reloading the image. Freezing
    /// restores the poster (frame 0) so a hovered-out tile reads as static.
    func setAnimating(_ animate: Bool) {
        guard wantsAnimation != animate else {
            if animate, (decoded?.frameCount ?? 0) > 1, playbackTask == nil { startPlayback() }
            return
        }
        wantsAnimation = animate
        if animate {
            if (decoded?.frameCount ?? 0) > 1, playbackTask == nil { startPlayback() }
        } else {
            stopPlayback()
            if let decoded, decoded.frameCount > 1, currentFrameIndex != 0 {
                currentFrameIndex = 0
                layer?.contents = decoded.posterFrame
            }
        }
    }

    func clearImage() {
        stopPlayback()
        decoded = nil
        currentFrameIndex = 0
        layer?.contents = nil
    }

    private func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
    }

    /// A `Task` rather than a `Timer`: each frame has to be decoded off the main
    /// thread, and a timer callback would have to hop out and back anyway.
    private func startPlayback() {
        guard let decoded, decoded.frameCount > 1 else { return }
        playbackTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let index = self.currentFrameIndex
                let delay = decoded.frameDelays.indices.contains(index)
                    ? decoded.frameDelays[index]
                    : 0.1
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                let next = (index + 1) % decoded.frameCount
                let frame = await Task.detached(priority: .userInitiated) {
                    decoded.frame(at: next)
                }.value
                guard !Task.isCancelled else { return }
                self.currentFrameIndex = next
                if let frame { self.layer?.contents = frame }
            }
        }
    }
}
#endif
