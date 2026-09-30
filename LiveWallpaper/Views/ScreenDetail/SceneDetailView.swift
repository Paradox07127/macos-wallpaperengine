#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE
import SwiftUI

// MARK: - Render failure pieces

struct SceneRenderFailureBanner: View {
    let state: SceneRenderState
    let origin: WPEOrigin
    var surface: NoticeBannerSurface = .chrome
    let onRetry: () -> Void
    @State private var engineAssets = WPEEngineAssetsLibrary.shared

    var body: some View {
        if case let .error(reason) = state {
            let presentation = reason.presentation(
                origin: origin,
                engineAssetsAuthorized: engineAssets.isAuthorized
            )
            InlineNoticeBanner(
                tint: presentation.tint,
                symbol: presentation.symbol,
                title: presentation.title,
                message: presentation.message,
                detail: presentation.detail,
                code: presentation.code,
                surface: surface
            ) {
                WallpaperFailureRecoveryActions(
                    recovery: presentation.recovery,
                    onRetry: onRetry
                )
            }
            .transition(.opacity)
        }
    }
}

struct SceneDiagnosticsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PreviewControlLabel(systemImage: "terminal", title: "Diagnostics")
        }
        .buttonStyle(.borderless)
        .help(Text("Open renderer diagnostics"))
        .accessibilityLabel(Text("Open renderer diagnostics"))
    }
}

// MARK: - Diagnostic log window

@MainActor
struct DiagnosticLogSheet: View {
    let title: String
    let log: String
    let tint: Color
    let onDismiss: () -> Void

    @State private var didCopy = false
    @State private var rendered: AttributedString?

    var body: some View {
        VStack(spacing: 0) {
            header
            terminal
        }
        .frame(minWidth: 540, idealWidth: 680, minHeight: 380, idealHeight: 540)
        // Keyed on the log: without the id the sheet keeps the first colourised
        // text forever, so a log that grows while the sheet is open stops updating.
        .task(id: log) { rendered = Self.colourise(log) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.title3)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Diagnostic Log")
                    .font(.headline)
                Text(verbatim: title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                copy()
            } label: {
                Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .animation(.snappy, value: didCopy)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(didCopy ? DesignTokens.Colors.Status.active : tint)
            Button("Done", action: onDismiss)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
        .padding(DesignTokens.Spacing.cardInset)
        .background(tint.opacity(0.08))
    }

    private var terminal: some View {
        ScrollView(.vertical) {
            Text(rendered ?? AttributedString(log))
                .font(DesignTokens.Typography.codeCaption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignTokens.Spacing.cardInset)
        }
        .background(Color.black.opacity(0.8))
    }

    /// Single AttributedString so copy/selection spans the whole log.
    private static func colourise(_ log: String) -> AttributedString {
        let lines = log.components(separatedBy: "\n")
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            var piece = AttributedString(line)
            piece.foregroundColor = colour(for: line)
            result += piece
            if index < lines.count - 1 {
                result += AttributedString("\n")
            }
        }
        return result
    }

    private static func colour(for line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("[err") || lower.contains("error") || lower.contains("fail") {
            return DesignTokens.Colors.Log.error
        }
        if lower.contains("[warn") || lower.contains("warning") || lower.contains("legacy") {
            return DesignTokens.Colors.Log.warning
        }
        // Tight match so "permission"/"dismiss"/"transmission" don't read as misses.
        if lower.contains("[miss") || lower.contains("miss:") || lower.contains("missing") || lower.contains("missed") {
            return DesignTokens.Colors.Log.miss
        }
        if lower.contains("resolved") || lower.contains("success") || lower.contains("cleanly") {
            return DesignTokens.Colors.Log.success
        }
        return DesignTokens.Colors.Log.neutral
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(log, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
        }
    }
}

// MARK: - State machine

enum SceneRenderState: Equatable {
    case idle
    /// No live session (menu-bar master tears sessions down, doesn't suspend).
    case notRendering
    case loading(progress: String?)
    case ready
    case error(FallbackReason)

    static var loading: SceneRenderState { .loading(progress: nil) }
}

extension SceneRenderState {
    /// Reads only the session's cached fields; the session refreshes them when its renderer state is polled.
    @MainActor
    static func derivedState(session targetSession: SceneWallpaperSession?) -> SceneRenderState {
        guard let targetSession else { return .notRendering }
        if let error = targetSession.loadError {
            return .error(mapToFallbackReason(error))
        }
        guard let presented = targetSession.hasPresentedFrame else { return .idle }
        if !presented {
            return .loading(progress: targetSession.loadProgress)
        }
        return .ready
    }

    static func mapToFallbackReason(_ error: SceneRenderingError) -> FallbackReason {
        switch error {
        case .cacheRootMissing:
            .sceneResourceMissing
        case let .parseFailed(detail):
            .sceneParseFailed(detail)
        case let .resourceFailed(diagnostic):
            fallbackReason(for: diagnostic)
        case .metalRendererUnsupported:
            .sceneShaderUnsupported
        }
    }

    static func fallbackReason(for diagnostic: SceneLoadDiagnostic) -> FallbackReason {
        switch diagnostic {
        case let .texture(_, error):
            switch error {
            case let .unsupportedContainer(magic):
                .texContainerUnsupported(magic: magic)
            case let .unsupportedFormat(code):
                .texUnsupportedFormat(code: code)
            case .metalUnavailable, .unsupportedAnimation:
                .texUnsupportedFormat(code: -1)
            default:
                .texDecodeFailed(detail: error.errorDescription ?? "decode failed")
            }
        case .legacyUnsupportedTexture:
            .texUnsupportedFormat(code: -1)
        case .fileMissing, .crossPackageReference:
            .sceneResourceMissing
        case .materialUnresolved:
            .sceneShaderUnsupported
        case let .other(_, message):
            .sceneLoadFailed(detail: message)
        }
    }
}

#endif
