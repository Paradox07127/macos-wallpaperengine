import AppKit
import LiveWallpaperCore
import SwiftUI

/// Generation + cacheKey gate for async HTML preview completions.
struct HTMLPreviewLoadState: Equatable {
    struct Token: Equatable {
        fileprivate let generation: UInt64
        fileprivate let cacheKey: String
    }

    private(set) var generation: UInt64 = 0
    private(set) var activeCacheKey: String?
    private(set) var isLoading = false

    mutating func begin(cacheKey: String) -> Token {
        generation &+= 1
        activeCacheKey = cacheKey
        isLoading = true
        return Token(generation: generation, cacheKey: cacheKey)
    }

    mutating func invalidate() {
        generation &+= 1
        activeCacheKey = nil
        isLoading = false
    }

    func isCurrent(_ token: Token) -> Bool {
        isLoading
            && token.generation == generation
            && token.cacheKey == activeCacheKey
    }

    mutating func finish(_ token: Token) -> Bool {
        guard isCurrent(token) else { return false }
        isLoading = false
        return true
    }
}

/// Inspector HTML wallpaper preview.
struct HTMLPreviewSection: View {
    let screen: Screen
    let source: HTMLSource?
    let config: HTMLConfig
    /// WPE web project shipped preview; always nil in Lite.
    let wpePreviewURL: URL?
    let wpePreviewBookmark: Data?

    @State private var snapshot: NSImage?
    @State private var loadFailed = false
    @State private var loadState = HTMLPreviewLoadState()
    @State private var loadTask: Task<Void, Never>?

    init(
        screen: Screen,
        source: HTMLSource?,
        config: HTMLConfig,
        wpePreviewURL: URL? = nil,
        wpePreviewBookmark: Data? = nil
    ) {
        self.screen = screen
        self.source = source
        self.config = config
        self.wpePreviewURL = wpePreviewURL
        self.wpePreviewBookmark = wpePreviewBookmark
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            snapshotCard
                .screenPreviewChrome()

            if source != nil {
                HTMLInformationOverlay(source: source, config: config)
                    .padding(DesignTokens.Spacing.cardInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)

                // Both live in the top-right corner so the source capsule owns the
                // bottom edge of the preview outright — they used to collide there.
                HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                    HTMLRenderingDiagnosticsOverlay(screen: screen, source: source, config: config)
                    refreshButton
                }
                .padding(DesignTokens.Spacing.cardInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        // Reports the drawn 16:9 box, not the column width — an overlay hung on
        // this view has to be clipped to the picture, not to the page.
        .aspectRatio(16/9, contentMode: .fit)
        .onChange(of: cacheKey) { _, _ in
            cancelPreviewLoad()
            snapshot = nil
            loadFailed = false
            startLoadIfNeeded()
        }
        .onAppear { startLoadIfNeeded() }
        .onDisappear { cancelPreviewLoad() }
    }

    @ViewBuilder
    private func wpePreviewCard(url: URL) -> some View {
        #if !LITE_BUILD
        WPEPreviewView(
            imageURL: url,
            securityScopedBookmarkData: wpePreviewBookmark,
            aspectRatio: nil
        )
        #else
        placeholder(systemImage: "photo", title: "Preview unavailable")
        #endif
    }

    @ViewBuilder
    private var snapshotCard: some View {
        if let snapshot {
            Image(nsImage: snapshot)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else if loadState.isLoading {
            ZStack {
                Rectangle().fill(DesignTokens.Colors.pageBackground)
                LiquidGlassSpinner()
            }
        } else if let wpePreviewURL {
            wpePreviewCard(url: wpePreviewURL)
        } else if loadFailed {
            placeholder(systemImage: "exclamationmark.triangle", title: "Preview unavailable")
        } else if source != nil {
            placeholder(systemImage: "globe", title: "Tap refresh to capture preview")
        } else {
            placeholder(systemImage: "globe", title: "No web source")
        }
    }

    private func placeholder(systemImage: String, title: LocalizedStringKey) -> some View {
        ZStack {
            Rectangle().fill(Color(NSColor.windowBackgroundColor))
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var refreshButton: some View {
        Button {
            if let key = cacheKey {
                WallpaperThumbnailService.shared.invalidate(cacheKey: key)
            }
            snapshot = nil
            loadFailed = false
            startLoadIfNeeded(force: true)
        } label: {
            PreviewCornerGlyph("arrow.clockwise")
        }
        .buttonStyle(.plain)
        .help(Text("Refresh web snapshot"))
        .accessibilityLabel(Text("Refresh web preview"))
    }

    // MARK: - Loading

    private var cacheKey: String? {
        source.map { HTMLPreviewKey.key(for: $0, config: config) }
    }

    private func startLoadIfNeeded(force: Bool = false) {
        guard let source, let key = cacheKey else { return }
        if loadState.isLoading {
            guard force else { return }
            cancelPreviewLoad()
        }
        let token = loadState.begin(cacheKey: key)
        loadFailed = false
        loadTask = Task { @MainActor in
            let liveImage = await captureLiveHTMLSnapshot()
            guard !Task.isCancelled, loadState.isCurrent(token) else { return }

            let cachedImage = force ? nil : WallpaperThumbnailService.shared.cachedThumbnail(forKey: key)
            let image: NSImage?
            if let liveImage {
                image = liveImage
            } else if let cachedImage {
                image = cachedImage
            } else {
                image = await HTMLPreviewKey.fetchSnapshot(
                    for: source,
                    config: config,
                    cacheKey: key
                )
            }
            guard !Task.isCancelled, loadState.finish(token) else { return }
            loadTask = nil
            if let image {
                snapshot = image
            } else if wpePreviewURL == nil {
                loadFailed = true
            }
        }
    }

    private func cancelPreviewLoad() {
        loadState.invalidate()
        loadTask?.cancel()
        loadTask = nil
    }

    @MainActor
    private func captureLiveHTMLSnapshot() async -> NSImage? {
        guard let session = screen.runtimeSession as? AmbientWallpaperSession else { return nil }
        guard let source else { return nil }
        return await session.captureLiveHTMLSnapshot(
            matching: source,
            config: config
        )
    }
}

/// Resolves an `HTMLSource` into a `(URL, cacheKey)` pair that `WallpaperThumbnailService` can snapshot.
enum HTMLPreviewKey {
    static func key(for source: HTMLSource, config: HTMLConfig) -> String {
        let sourceKey: String
        switch source {
        case .url(let url):
            sourceKey = "html.url::" + url.absoluteString
        case .file(let bookmark):
            sourceKey = "html.file::" + String(bookmark.base64EncodedString().prefix(40))
        case .folder(let bookmark, let index):
            sourceKey = "html.folder::"
                + String(bookmark.base64EncodedString().prefix(40))
                + "::"
                + index
        case .inline(let html):
            sourceKey = "html.inline::" + String(html.hashValue)
        }
        return sourceKey + "::config::" + configurationFingerprint(config)
    }

    @MainActor
    static func fetchSnapshot(
        for source: HTMLSource,
        config: HTMLConfig,
        cacheKey: String
    ) async -> NSImage? {
        let compatibility = HTMLWallpaperCompatibilityPolicy.runtimeConfig(
            source: source,
            config: config,
            trustedOrigins: TrustedHostStore.shared.originSet
        )
        switch source {
        case .url(let url):
            return await WallpaperThumbnailService.shared.htmlSnapshotImage(
                request: HTMLSnapshotRequest(
                    source: source,
                    loadURL: url,
                    cacheKey: cacheKey,
                    effectiveConfig: compatibility.config,
                    localReadAccessRoot: nil
                )
            )
        case .file(let bookmarkData):
            return await snapshotFromBookmark(
                source: source,
                bookmarkData: bookmarkData,
                appendingIndex: nil,
                cacheKey: cacheKey,
                compatibility: compatibility
            )
        case .folder(let bookmarkData, let indexFileName):
            return await snapshotFromBookmark(
                source: source,
                bookmarkData: bookmarkData,
                appendingIndex: indexFileName,
                cacheKey: cacheKey,
                compatibility: compatibility
            )
        case .inline:
            return nil
        }
    }

    @MainActor
    private static func snapshotFromBookmark(
        source: HTMLSource,
        bookmarkData: Data,
        appendingIndex: String?,
        cacheKey: String,
        compatibility: HTMLWallpaperCompatibilityResult
    ) async -> NSImage? {
        guard case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
            bookmarkData,
            target: .transient
        ) else { return nil }
        let url = resolved.url
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        let target: URL
        if let index = appendingIndex {
            target = url.appendingPathComponent(index)
            guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        } else {
            target = url
        }
        return await WallpaperThumbnailService.shared.htmlSnapshotImage(
            request: HTMLSnapshotRequest(
                source: source,
                loadURL: target,
                cacheKey: cacheKey,
                effectiveConfig: compatibility.config,
                localReadAccessRoot: appendingIndex == nil
                    ? target.deletingLastPathComponent()
                    : url
            )
        )
    }

    private static func configurationFingerprint(_ config: HTMLConfig) -> String {
        guard let data = try? JSONEncoder().encode(config) else {
            return String(describing: config)
        }
        // The thumbnail cache is process-local, so Swift's randomized hash is
        // sufficient and avoids retaining potentially large WPE properties in
        // every cache key.
        return String(data.hashValue)
    }
}

/// Web preview source + runtime-mode badges (HTTP / JS / PHYS PX / CLICKS).
struct HTMLInformationOverlay: View {
    let source: HTMLSource?
    let config: HTMLConfig

    @ViewBuilder
    var body: some View {
        if let source {
            content(for: source)
        }
    }

    private func content(for source: HTMLSource) -> some View {
        HStack(spacing: 10) {
            if source.isInsecureURL {
                tag(Text(verbatim: "HTTP"), background: DesignTokens.Colors.Status.warning.opacity(0.55))
            }

            HStack(spacing: 4) {
                Image(systemName: icon(for: source))
                Text(verbatim: identifier(for: source))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 200, alignment: .leading)

            if case .url = source {
                if config.allowJavaScript {
                    tag(Text(verbatim: "JS"))
                } else {
                    tag(Text("No JS"), background: DesignTokens.Colors.Status.danger.opacity(0.55))
                }
            } else if !config.allowJavaScript {
                tag(Text("No JS"), background: DesignTokens.Colors.Status.danger.opacity(0.55))
            }

            if config.physicalPixelLayout {
                tag(Text("Phys PX"))
            }
            if config.allowMouseInteraction {
                tag(Text("Clicks"))
            }
        }
        .font(DesignTokens.Typography.code)
        .foregroundStyle(DesignTokens.Colors.overlayForeground)
        .padding(.horizontal, DesignTokens.Spacing.cardInset)
        .padding(.vertical, 8)
        .thumbnailBadgeGlass()
        .accessibilityElement(children: .combine)
    }

    /// Secondary pill inside the glass info panel; padding matches the shared
    /// flat-pill standard (`TypeBadge`), and the default background is the
    /// over-media foreground token at panel-tag strength.
    private func tag(
        _ text: Text,
        background: Color = DesignTokens.Colors.overlayForeground.opacity(0.18)
    ) -> some View {
        text
            .font(DesignTokens.Typography.badge)
            .textCase(.uppercase)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
    }

    private func icon(for source: HTMLSource) -> String {
        switch source {
        case .url:    return "globe"
        case .file:   return "doc.richtext"
        case .folder: return "folder"
        case .inline: return "curlybraces"
        }
    }

    private func identifier(for source: HTMLSource) -> String {
        switch source {
        case .url(let url):
            return url.host ?? url.absoluteString
        case .file, .folder:
            return source.displayName
        case .inline:
            return String(localized: "Inline web content", bundle: .appLanguage, comment: "HTML source identifier for inline HTML content.")
        }
    }
}

/// Render-geometry badges on the web preview (not the inspector list).
/// The preview's two corner controls sit side by side, so their glyph frame and
/// backing live in one place — spelled twice, they drift the first time one moves.
/// A view rather than a function so each control carries its own hover state
/// for the interactive-corner-glyph glass API.
private struct PreviewCornerGlyph: View {
    private let systemImage: String

    @State private var isHovering = false

    init(_ systemImage: String) {
        self.systemImage = systemImage
    }

    var body: some View {
        Image(systemName: systemImage)
            .imageScale(.medium)
            .foregroundStyle(DesignTokens.Colors.overlayForeground)
            .frame(width: 26, height: 26)
            .floatingGlyphGlass(hovered: isHovering, opacity: 0.7)
            .onHover { isHovering = $0 }
    }
}

struct HTMLRenderingDiagnosticsOverlay: View {
    let screen: Screen
    let source: HTMLSource?
    let config: HTMLConfig

    /// Collapsed by default. Expanded, this is seven rows of numbers sitting on
    /// top of the frame those numbers describe — useful on demand, noise otherwise.
    @State private var isExpanded = false

    @ViewBuilder
    var body: some View {
        if source != nil {
            if isExpanded {
                let diagnostics = HTMLRenderingDiagnostics(screen: screen, source: source, config: config)
                content(diagnostics: diagnostics)
                    .foregroundStyle(DesignTokens.Colors.overlayForeground)
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, DesignTokens.Spacing.sm)
                    // A panel of label/value rows, not a badge: the capsule's end caps
                    // wasted its corners and read as one oversized pill.
                    .thumbnailBadgeGlass(opacity: 0.7, in: .roundedRectangle(DesignTokens.Corner.md))
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text("Hide details"))
                    .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous))
                    .onTapGesture { toggle() }
            } else {
                Button(action: toggle) {
                    PreviewCornerGlyph("info.circle")
                }
                .buttonStyle(.plain)
                .help(Text("Web Rendering"))
                .accessibilityLabel(Text("Web Rendering"))
            }
        }
    }

    private func toggle() {
        withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
    }

    /// Two columns rather than one: seven stacked rows in the corner covered a
    /// third of the frame being measured, which is what collapsing it fixed.
    private let columns = [
        GridItem(.adaptive(minimum: 172), spacing: DesignTokens.Spacing.md, alignment: .leading)
    ]

    private func content(diagnostics: HTMLRenderingDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "ruler")
                    .imageScale(.small)
                Text("Web Rendering")
                    .font(DesignTokens.Typography.captionEmphasized)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
                diagnosticCell("Measurement", diagnostics.measurementText)
                diagnosticCell("Points", diagnostics.pointSizeText)
                diagnosticCell("Backing", diagnostics.backingPixelSizeText)
                diagnosticCell("Scale", diagnostics.scaleText)
                diagnosticCell("Viewport", diagnostics.viewportText)
                // "DPR" stays verbatim: it is the web platform's own acronym for
                // `window.devicePixelRatio`, not prose.
                diagnosticCell(verbatimLabel: "DPR", diagnostics.devicePixelRatioText)
                diagnosticCell("Mode", diagnostics.modeText)
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    /// `value` is verbatim on purpose: it is either a measurement with units or
    /// a string the diagnostics already localized at the point it was computed.
    private func diagnosticCell(_ label: LocalizedStringKey, _ value: String) -> some View {
        cell(label: Text(label), value: value)
    }

    private func diagnosticCell(verbatimLabel: String, _ value: String) -> some View {
        cell(label: Text(verbatim: verbatimLabel), value: value)
    }

    private func cell(label: Text, value: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            label
                .font(DesignTokens.Typography.badge)
                .opacity(0.65)
            Text(verbatim: value)
                .font(DesignTokens.Typography.metric)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}
