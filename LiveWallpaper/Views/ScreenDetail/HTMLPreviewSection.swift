import AppKit
import LiveWallpaperCore
import SwiftUI

enum HTMLPreviewKey {
    /// Process-local: `hashValue` changes every launch, so this key must never be persisted.
    static func key(for source: HTMLSource, config: HTMLConfig) -> String {
        let sourceKey = switch source {
        case .url(let url):
            "html.url::" + url.absoluteString
        case .file(let bookmark):
            "html.file::" + String(bookmark.hashValue)
        case .folder(let bookmark, let index):
            "html.folder::" + String(bookmark.hashValue) + "::" + index
        case .inline(let html):
            "html.inline::" + String(html.hashValue)
        }
        return sourceKey + "::config::" + configurationFingerprint(config)
    }

    @MainActor
    static func fetchSnapshot(
        for source: HTMLSource,
        config: HTMLConfig,
        cacheKey: String
    ) async -> NSImage? {
        let trustedOrigins = TrustedHostStore.shared.originSet
        guard let effectiveConfig = await PreviewWorkGate.shared.runDetached({
            HTMLWallpaperCompatibilityPolicy.runtimeConfig(
                source: source, config: config, trustedOrigins: trustedOrigins
            ).config
        }), !Task.isCancelled else { return nil }
        switch source {
        case .url(let url):
            return await WallpaperThumbnailService.shared.htmlSnapshotImage(
                request: HTMLSnapshotRequest(
                    source: source,
                    loadURL: url,
                    cacheKey: cacheKey,
                    effectiveConfig: effectiveConfig,
                    localReadAccessRoot: nil
                )
            )
        case .file(let bookmarkData):
            return await snapshotFromBookmark(
                source: source,
                bookmarkData: bookmarkData,
                appendingIndex: nil,
                cacheKey: cacheKey,
                effectiveConfig: effectiveConfig
            )
        case .folder(let bookmarkData, let indexFileName):
            return await snapshotFromBookmark(
                source: source,
                bookmarkData: bookmarkData,
                appendingIndex: indexFileName,
                cacheKey: cacheKey,
                effectiveConfig: effectiveConfig
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
        effectiveConfig: HTMLConfig
    ) async -> NSImage? {
        guard let resolved = await LibraryContentLocator.resolvePreviewBookmark(bookmarkData),
              !Task.isCancelled else { return nil }
        let url = resolved.url
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        let target: URL
        if let index = appendingIndex {
            target = url.appendingPathComponent(index)
            guard await PreviewWorkGate.shared.runDetached({
                FileManager.default.fileExists(atPath: target.path)
            }) == true, !Task.isCancelled else { return nil }
        } else {
            target = url
        }
        return await WallpaperThumbnailService.shared.htmlSnapshotImage(
            request: HTMLSnapshotRequest(
                source: source,
                loadURL: target,
                cacheKey: cacheKey,
                effectiveConfig: effectiveConfig,
                localReadAccessRoot: appendingIndex == nil
                    ? target.deletingLastPathComponent()
                    : url
            )
        )
    }

    private static func configurationFingerprint(_ config: HTMLConfig) -> String {
        let encoder = JSONEncoder()
        // Without `.sortedKeys` the key order varies between encodes of one value, so the key would flap.
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(config) else {
            return String(describing: config)
        }
        // Process-local cache, so Swift's per-process randomized hash is fine and
        // avoids retaining large WPE properties in every key.
        return String(data.hashValue)
    }
}

extension Text {
    func informationOverlayTag(
        background: Color = DesignTokens.Colors.overlayForeground.opacity(0.18)
    ) -> some View {
        font(DesignTokens.Typography.badge)
            .textCase(.uppercase)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
    }
}

struct HTMLRenderingDiagnosticsGrid: View {
    let diagnostics: HTMLRenderingDiagnostics

    private let columns = [
        GridItem(.adaptive(minimum: 172), spacing: DesignTokens.Spacing.md, alignment: .leading)
    ]

    var body: some View {
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
