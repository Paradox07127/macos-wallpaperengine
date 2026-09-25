#if !LITE_BUILD
import SwiftUI
import AppKit
import LiveWallpaperCore

enum FallbackReason: Equatable, Sendable {
    case unsupportedType
    case sceneParseFailed(String)
    case sceneLoadFailed(detail: String)
    case sceneShaderUnsupported
    case sceneResourceMissing
    /// Steam workshop IDs to subscribe before retry.
    case missingDependency(workshopIDs: [String])
    /// Windows `.dll` under `bin/` — permanent on macOS.
    case requiresWindowsPlugin
    case texContainerUnsupported(magic: String)
    case texUnsupportedFormat(code: Int)
    case texDecodeFailed(detail: String)
}

struct FallbackCard: View {
    let origin: WPEOrigin
    let reason: FallbackReason
    @State private var engineAssets = WPEEngineAssetsLibrary.shared

    init(origin: WPEOrigin, reason: FallbackReason = .unsupportedType) {
        self.origin = origin
        self.reason = reason
    }

    static func reason(for origin: WPEOrigin) -> FallbackReason {
        if origin.requiresWindowsPlugin { return .requiresWindowsPlugin }
        if !origin.missingDependencyIDs.isEmpty {
            return .missingDependency(workshopIDs: origin.missingDependencyIDs)
        }
        return .unsupportedType
    }

    /// The banner's title as one line, for toasts and status lines that name the reason.
    static func cannotRunSummary(for origin: WPEOrigin) -> String {
        reason(for: origin).localizedTitle(originalType: origin.originalType)
    }

    var body: some View {
        let presentation = reason.presentation(
            origin: origin,
            engineAssetsAuthorized: engineAssets.isAuthorized
        )
        VStack(spacing: DesignTokens.Spacing.xl) {
            WPEPreviewView(
                imageURL: origin.sourcePreviewURL,
                securityScopedBookmarkData: origin.sourceFolderBookmark,
                previewSize: .tile
            )
                .frame(width: 280)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.preview, style: .continuous))
                .shadow(color: Color.black.opacity(DesignTokens.Card.shadowOpacity), radius: 8, y: 4)

            VStack(spacing: DesignTokens.Spacing.sm) {
                Text(verbatim: origin.title)
                    .font(DesignTokens.Typography.pageTitle)
                    .multilineTextAlignment(.center)
                Text("Workshop ID \(origin.workshopID) · \(origin.localizedDisplayTypeName) type", comment: "Wallpaper Engine metadata line. Placeholders are Workshop ID and project type.")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
            }

            UnsupportedProjectNotice(origin: origin, reason: reason, showsIdentity: false)

            // `onRetry: nil` — this card has no session to reload, so Retry drops out
            // of the shared action list.
            HStack(spacing: DesignTokens.Spacing.sm) {
                WallpaperFailureRecoveryActions(
                    recovery: presentation.recovery,
                    onRetry: nil,
                    isCompact: false
                )
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(maxWidth: 480)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.xl, style: .continuous)
                .fill(DesignTokens.Colors.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.xl, style: .continuous)
                .strokeBorder(DesignTokens.Colors.separator.opacity(0.55), lineWidth: 0.5)
        )
    }
}

/// Why a Workshop project can't run here: the failure banner, an optional Workshop ID line and the
/// missing dependencies with open and copy. `FallbackCard` and the library modal both draw it.
struct UnsupportedProjectNotice: View {
    let origin: WPEOrigin
    let reason: FallbackReason
    /// False where the host already shows the ID and type, as `FallbackCard`'s header does.
    let showsIdentity: Bool
    @State private var engineAssets = WPEEngineAssetsLibrary.shared

    /// `reason` nil derives it from the origin.
    init(origin: WPEOrigin, reason: FallbackReason? = nil, showsIdentity: Bool) {
        self.origin = origin
        self.reason = reason ?? FallbackCard.reason(for: origin)
        self.showsIdentity = showsIdentity
    }

    var body: some View {
        let presentation = reason.presentation(
            origin: origin,
            engineAssetsAuthorized: engineAssets.isAuthorized
        )
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if showsIdentity {
                Text("Workshop ID \(origin.workshopID) · \(origin.localizedDisplayTypeName) type", comment: "Wallpaper Engine metadata line. Placeholders are Workshop ID and project type.")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
            }
            InlineNoticeBanner(
                tint: presentation.tint,
                symbol: presentation.symbol,
                title: presentation.title,
                message: presentation.message,
                detail: presentation.detail,
                code: presentation.code,
                surface: .content
            )
            if case let .missingDependency(ids) = reason {
                dependencyList(ids: ids)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func dependencyList(ids: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ids, id: \.self) { id in
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(verbatim: id)
                            .font(DesignTokens.Typography.codeCaption)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            openWorkshop(workshopID: id)
                        } label: {
                            Label("Open", systemImage: "safari")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help(Text("Open workshop \(id) in browser"))
                        .accessibilityLabel(Text("Open workshop \(id) in browser"))
                        Button {
                            copyToPasteboard(id)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help(Text("Copy workshop ID to clipboard"))
                        .accessibilityLabel(Text("Copy workshop ID \(id)"))
                    }
                }
            }
        }
        .frame(maxHeight: 160)
    }

    private func openWorkshop(workshopID: String) {
        var components = URLComponents(string: "https://steamcommunity.com/sharedfiles/filedetails/")
        components?.queryItems = [URLQueryItem(name: "id", value: workshopID)]
        guard let url = components?.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

#endif
