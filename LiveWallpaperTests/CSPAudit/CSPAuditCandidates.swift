@testable import LiveWallpaper

/// CSP candidates ordered from a restrictive baseline through the shipping policy to a compatibility fallback.
/// `v1Strict` and `v2Current` are the two policies that actually ship — the audit must measure the
/// live strings, not copies of them, or a drifted copy certifies a policy nobody serves.
enum CSPAuditCandidate: String, CaseIterable, Sendable {
    case v1Strict
    case v2Current
    case v3Relaxed

    var directives: String {
        switch self {
        case .v1Strict:
            FolderURLSchemeHandler.networkIsolatedContentSecurityPolicy
        case .v2Current:
            FolderURLSchemeHandler.contentSecurityPolicy
        case .v3Relaxed:
            [
                "default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob: livewallpaper:;",
                "script-src 'self' https: 'unsafe-inline' 'unsafe-eval' data: blob: livewallpaper:;",
                "connect-src 'self' https: livewallpaper: data: blob:;",
                "img-src 'self' https: data: blob: livewallpaper:;",
                "media-src 'self' https: data: blob: livewallpaper:;",
                "font-src 'self' https: data: livewallpaper:;",
                "frame-src 'none';",
                "object-src 'none';",
                "base-uri 'none';",
                "form-action 'none';"
            ].joined(separator: " ")
        }
    }

    var displayName: String {
        switch self {
        case .v1Strict: "v1-strict (= shipping Workshop network isolation)"
        case .v2Current: "v2-current (ship config)"
        case .v3Relaxed: "v3-relaxed (script-src https:)"
        }
    }
}
