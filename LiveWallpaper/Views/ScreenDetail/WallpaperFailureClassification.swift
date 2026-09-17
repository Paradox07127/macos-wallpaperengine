import AppKit
import LiveWallpaperCore
import SwiftUI

/// What the user can still do about a failure decides the tier — not how alarming
/// the error sounds.
enum WallpaperFailureClass: Equatable {
    /// Nothing on this Mac can render it, ever. No recovery action exists.
    case fatal
    /// It will not run, but there is a way out.
    case blocked
    /// Something is missing; supplying it fixes the wallpaper.
    case needsParts
    /// One layer was skipped — the wallpaper is still playing.
    case degraded

    /// Follows the DESIGN.md tint gloss.
    var tint: Color {
        switch self {
        case .fatal: DesignTokens.Colors.Status.danger
        case .blocked: DesignTokens.Colors.Status.warning
        case .needsParts, .degraded: DesignTokens.Colors.Status.caution
        }
    }

    /// The glyph a surface uses when it has nothing finer. `FallbackReason`
    /// overrides it per reason; a `WallpaperFailureCause` has only its class.
    var symbol: String {
        switch self {
        case .fatal: "xmark.octagon.fill"
        case .blocked: "exclamationmark.triangle.fill"
        case .needsParts: "folder.badge.questionmark"
        case .degraded: "photo.badge.exclamationmark"
        }
    }

    /// Carries the meaning the tint alone must never carry (DESIGN.md rule 6).
    var kicker: LocalizedStringKey {
        switch self {
        case .fatal: "Can't run on this Mac"
        case .blocked: "This wallpaper didn't load"
        case .needsParts: "Something is missing"
        case .degraded: "Some layers were skipped"
        }
    }
}

enum WallpaperFailureRecovery: Equatable, Hashable {
    case retry
    /// Re-point at content we can no longer open. Distinct from `.retry`:
    /// trying the same unreachable path again cannot succeed.
    case chooseSource
    case copyDependencyIDs([String])
    case openWorkshop(String)
    case configureEngineAssets
}

extension WallpaperFailureCause {
    /// Deliberately short: `code` is an open namespace (an unmapped `NSError` arrives as
    /// "<domain>.<code>"), so anything unlisted stays `.blocked`.
    private static let fatalCodes: Set<String> = [
        "scene.metal_unsupported",
        "scene.unsafe_path",
        "scene.windows_plugin",
        "texture.metal_compression",
        "texture.metal_format",
        "texture.metal_unavailable",
        "web.blocked_port",
    ]

    /// The content is gone or unreadable; pointing us at it again is the fix,
    /// and retrying the same unreachable path is not.
    private static let sourceRelinkCodes: Set<String> = [
        "NSCocoaErrorDomain.257",
        "runtime.fileAccessDenied",
        "runtime.sandboxRevoked",
        "scene.cache_missing",
        "scene.source_unavailable",
        "web.entry_missing",
        "web.resource_denied",
    ]

    /// Present but incomplete — a named file the project expects is absent.
    private static let missingPartCodes: Set<String> = [
        "graph.file_missing",
        "scene.cross_package",
        "scene.file_missing",
    ]

    var failureClass: WallpaperFailureClass {
        if Self.fatalCodes.contains(code) {
            return .fatal
        }
        if Self.sourceRelinkCodes.contains(code) || Self.missingPartCodes.contains(code) {
            return .needsParts
        }
        return .blocked
    }

    var needsSourceRelink: Bool {
        Self.sourceRelinkCodes.contains(code)
    }

    func recovery(workshopID: String?, canChooseSource: Bool) -> [WallpaperFailureRecovery] {
        var actions: [WallpaperFailureRecovery] = []
        // `canRetry` is the producers' call but cannot outvote a fatal code:
        // `WPEImportCoordinator` emits `scene.windows_plugin` with `canRetry: true`.
        if failureClass != .fatal {
            if needsSourceRelink, canChooseSource {
                actions.append(.chooseSource)
            } else if canRetry {
                actions.append(.retry)
            }
        }
        if let workshopID, !workshopID.isEmpty, workshopID.allSatisfy(\.isNumber) {
            actions.append(.openWorkshop(workshopID))
        }
        return actions
    }
}

struct WallpaperFailureRecoveryActions: View {
    let recovery: [WallpaperFailureRecovery]
    let onRetry: (() -> Void)?
    var onChooseSource: (() -> Void)?
    var isCompact = true

    @State private var didCopy = false

    var body: some View {
        ForEach(Array(recovery.enumerated()), id: \.element) { index, action in
            // Only the first action can be prominent (DESIGN.md rule 8).
            control(for: action, isPrimary: index == 0)
        }
    }

    @ViewBuilder
    private func control(for action: WallpaperFailureRecovery, isPrimary: Bool) -> some View {
        switch action {
        case .retry:
            if let onRetry {
                emphasised(isPrimary) {
                    Button(action: onRetry) {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .accessibilityHint(Text("Reloads the current scene."))
                }
            }
        case .chooseSource:
            if let onChooseSource {
                emphasised(isPrimary) {
                    Button(action: onChooseSource) {
                        Label("Apply Project Folder", systemImage: "folder.badge.plus")
                    }
                    .accessibilityHint(Text("Opens a folder chooser to link and apply a local project in place"))
                }
            }
        case let .copyDependencyIDs(ids):
            emphasised(isPrimary) {
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(ids.joined(separator: "\n"), forType: .string)
                    didCopy = true
                } label: {
                    // Two literal Labels rather than a ternary inside one: a
                    // ternary's type is inferred, and which Label overload wins
                    // then decides whether the string is localised at all.
                    if didCopy {
                        Label("Copied", systemImage: "checkmark")
                    } else {
                        Label("Copy IDs", systemImage: "doc.on.doc")
                    }
                }
                .task(id: didCopy) {
                    guard didCopy else { return }
                    try? await Task.sleep(for: .seconds(2))
                    didCopy = false
                }
                .accessibilityHint(Text("Copies every missing workshop ID to your clipboard so you can subscribe in Steam"))
            }
        case let .openWorkshop(id):
            Button {
                openWorkshop(workshopID: id)
            } label: {
                Label("Workshop", systemImage: "safari")
            }
            .buttonStyle(.bordered)
            .controlSize(isCompact ? .small : .regular)
            .accessibilityHint(Text("Opens this wallpaper's Steam Workshop page in your browser"))
        case .configureEngineAssets:
            emphasised(isPrimary) {
                Button {
                    NotificationCenter.default.post(
                        name: .openSettingsSection,
                        object: nil,
                        userInfo: [
                            "destination": SettingsNavigation.workshopSetup.rawValue,
                            "anchor": SettingsSearchAnchor.workshopAssets.rawValue,
                        ]
                    )
                } label: {
                    Label("Set Up Assets", systemImage: "shippingbox.and.arrow.backward")
                }
                .accessibilityHint(Text("Opens the Workshop settings page to download or link Wallpaper Engine assets"))
            }
        }
    }

    /// `buttonStyle` takes a concrete type, so the prominent/plain choice has to
    /// branch on whole views rather than on the style value.
    @ViewBuilder
    private func emphasised(_ isPrimary: Bool, @ViewBuilder content: () -> some View) -> some View {
        if isPrimary {
            content().buttonStyle(.borderedProminent).controlSize(isCompact ? .small : .regular)
        } else {
            content().buttonStyle(.bordered).controlSize(isCompact ? .small : .regular)
        }
    }

    private func openWorkshop(workshopID: String) {
        var components = URLComponents(string: "https://steamcommunity.com/sharedfiles/filedetails/")
        components?.queryItems = [URLQueryItem(name: "id", value: workshopID)]
        guard let url = components?.url else { return }
        NSWorkspace.shared.open(url)
    }
}
