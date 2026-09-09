import CoreGraphics
import Foundation
import LiveWallpaperCore
import Observation

struct WallpaperFailureCause: Equatable, Sendable {
    let code: String
    let reason: String
    let canRetry: Bool
    let details: String

    init(code: String, reason: String, canRetry: Bool = true, details: String = "") {
        self.code = code
        self.reason = LogPrivacyRedactor.scrub(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "The specific cause is not yet known.", bundle: .appLanguage) : reason)
        self.canRetry = canRetry
        self.details = LogPrivacyRedactor.scrub(details)
    }

    static func runtime(_ error: WallpaperRuntimeError) -> Self {
        Self(code: "runtime.\(String(describing: error).split(separator: "(").first ?? "unknown")", reason: error.userMessage, canRetry: error.canRetry)
    }
}

struct WallpaperFailureSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let workshopID: String?
    let displayName: String
    let stage: String
    let cause: WallpaperFailureCause
    let previousWallpaper: String?
    let timestamp: Date
    let diagnostics: String
    var wallpaperType: WallpaperType?

    /// The browser URL has a fixed budget. Author-controlled names and logs
    /// cannot push the failure code and reason out of its prefilled body.
    var issueDiagnosticText: String {
        LogPrivacyRedactor.scrub("""
        Diagnostic excerpt — use Copy Diagnostics for the complete local report.
        Attempt: \(id.uuidString)
        Stage: \(stage.prefix(80))
        Code: \(cause.code.prefix(160))
        Reason: \(cause.reason.prefix(700))
        Failed wallpaper: \(title.prefix(160))
        Workshop ID: \(workshopID?.prefix(40) ?? "—")
        Display: \(displayName.prefix(100))
        Desktop at failure: \(previousWallpaper?.prefix(160) ?? "—")
        Time: \(timestamp.ISO8601Format())
        \(cause.details.prefix(300))
        \(diagnostics.prefix(300))
        """)
    }

    var diagnosticText: String {
        LogPrivacyRedactor.scrub("""
        Failed wallpaper: \(title)
        Workshop ID: \(workshopID ?? "—")
        Display: \(displayName)
        Attempt: \(id.uuidString)
        Time: \(timestamp.ISO8601Format())
        Stage: \(stage)
        Code: \(cause.code)
        Reason: \(cause.reason)
        Desktop at failure: \(previousWallpaper ?? "—")
        \(cause.details)

        \(diagnostics)
        """)
    }
}

struct WallpaperLoadAttempt: Identifiable {
    enum Phase { case importing, preparing, failed }
    let id: UUID
    let screenID: CGDirectDisplayID
    let screenIdentity: ObjectIdentifier
    let displayFingerprint: String
    var title: String
    var sourceURL: URL?
    var origin: WPEOrigin?
    var configuration: ScreenConfiguration?
    var phase: Phase = .importing
    var failure: WallpaperFailureSnapshot?
    var isInspecting = true
}

/// Holds proposals separately from committed configuration. A result must own
/// both the display object and attempt ID before it can change presentation.
@MainActor
@Observable
final class WallpaperLoadState {
    private(set) var attempts: [CGDirectDisplayID: WallpaperLoadAttempt] = [:]

    func begin(for screen: Screen, title: String, sourceURL: URL? = nil, origin: WPEOrigin? = nil) -> UUID {
        let id = UUID()
        attempts[screen.id] = WallpaperLoadAttempt(id: id, screenID: screen.id, screenIdentity: ObjectIdentifier(screen), displayFingerprint: screen.displayFingerprint, title: title, sourceURL: sourceURL, origin: origin)
        return id
    }

    func attempt(for screen: Screen) -> WallpaperLoadAttempt? {
        guard let attempt = attempts[screen.id], attempt.displayFingerprint == screen.displayFingerprint,
              attempt.phase == .failed || attempt.screenIdentity == ObjectIdentifier(screen) else { return nil }
        return attempt
    }

    @discardableResult
    func update(_ id: UUID, for screen: Screen, _ edit: (inout WallpaperLoadAttempt) -> Void) -> Bool {
        guard var attempt = attempt(for: screen), attempt.id == id else { return false }
        edit(&attempt)
        attempts[screen.id] = attempt
        return true
    }

    func clear(for screen: Screen, matching id: UUID? = nil) {
        guard let attempt = attempt(for: screen), id == nil || attempt.id == id else { return }
        attempts.removeValue(forKey: screen.id)
    }
}
