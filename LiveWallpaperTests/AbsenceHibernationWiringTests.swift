import Foundation
import Testing

/// Source contracts for the absence-dwell wiring. The player and view APIs have
/// behavioural tests of their own, but nothing production-side drove them: every
/// hibernation test pushes eligibility onto the object directly. Deleting the
/// `ScreenManager` calls — or moving them back inside `#if !LITE_BUILD` — used to
/// disable the twenty-second teardown for both SKUs with every test still green.
@Suite("Absence hibernation wiring contract")
struct AbsenceHibernationWiringTests {
    private static let observers = "LiveWallpaper/App/ScreenManager+Observers.swift"

    private static func resolveAndApplyPerformanceStateBody() throws -> String {
        let source = try RepositoryRoot.source(observers)
        let start = try #require(
            source.range(of: "private func resolveAndApplyPerformanceState"),
            "resolveAndApplyPerformanceState was renamed — re-point this contract"
        )
        let rest = source[start.lowerBound...]
        // Up to the next top-level declaration in the extension.
        guard let end = rest.range(of: "\n    /// Layers the adaptive background") else {
            return String(rest)
        }
        return String(rest[..<end.lowerBound])
    }

    @Test("Video and HTML sessions both receive the absence signal")
    func bothSessionKindsAreWired() throws {
        let body = try Self.resolveAndApplyPerformanceStateBody()
        #expect(body.contains("as? VideoWallpaperSession"))
        #expect(body.contains("as? AmbientWallpaperSession"))
        #expect(body.contains("setHibernationEligible(isAbsenceLikeSuspension)"))
    }

    /// Video and HTML wallpapers ship in both SKUs; only the scene runtime is
    /// Pro-only. A `#if !LITE_BUILD` around these two calls compiles clean and
    /// silently drops the feature from Loomscreen.
    @Test("The video and HTML calls sit outside the Pro-only block")
    func wiringIsNotGatedOnProOnlyBuilds() throws {
        let body = try Self.resolveAndApplyPerformanceStateBody()
        let liteGate = try #require(
            body.range(of: "#if !LITE_BUILD"),
            "the Pro-only block moved — re-point this contract"
        )
        let beforeGate = body[..<liteGate.lowerBound]
        #expect(
            beforeGate.contains("as? VideoWallpaperSession"),
            "video hibernation must be wired for Lite too"
        )
        #expect(
            beforeGate.contains("as? AmbientWallpaperSession"),
            "HTML hibernation must be wired for Lite too"
        )
        // Control: the scene session genuinely is Pro-only, so it must NOT appear
        // before the gate. Without this the assertions above would also pass on a
        // file that simply dropped the gate altogether.
        #expect(!beforeGate.contains("as? SceneWallpaperSession"))
    }

    /// The predicate feeding all three session kinds. Coverage inputs are only
    /// meaningful while the detector is rescanning, which is why the fallback
    /// polling flag is part of it rather than a bare hidden/occluded read.
    @Test("The absence predicate keeps its coverage-validity gate")
    func absencePredicateKeepsCoverageGate() throws {
        let body = try Self.resolveAndApplyPerformanceStateBody()
        #expect(body.contains("isFallbackPollingEnabled"))
        #expect(body.contains("profile == .suspended"))
        #expect(body.contains("isUserAbsent"))
    }
}
