import Foundation
import Testing

/// Sheets separate their title area and button row from the content with padding, as `SheetFooterBar` does
/// for its buttons, not with a rule.
@Suite("Sheets — no rule between title, content and buttons")
struct SheetSeparatorSourceTests {
    struct Boundary: Sendable, CustomTestStringConvertible {
        let path: String
        let from: String
        let to: String

        var testDescription: String {
            let file = path.split(separator: "/").last.map(String.init) ?? path
            let trim = { (anchor: String) in anchor.trimmingCharacters(in: .whitespacesAndNewlines) }
            return "\(file): \(trim(from)) → \(trim(to))"
        }
    }

    /// `Divider()` calls in `path` between the first `from` and the first `to` after it.
    static func rules(in path: String, from: String, to: String) throws -> Int {
        let source = try RepositoryRoot.source(path)
        let start = try #require(source.range(of: from), Comment(rawValue: "\(path) lost the anchor \(from)"))
        let end = try #require(
            source.range(of: to, range: start.upperBound ..< source.endIndex),
            Comment(rawValue: "\(path) lost the anchor \(to) after \(from)")
        )
        return source[start.upperBound ..< end.lowerBound].components(separatedBy: "Divider()").count - 1
    }

    static let boundaries: [Boundary] = [
        Boundary(path: "LiveWallpaper/Views/SystemWallpaper/SystemWallpaperAddSheet.swift", from: "chooseFilesRow\n", to: "body(for: candidates)"),
        Boundary(path: "LiveWallpaper/Views/SystemWallpaper/SystemWallpaperAddSheet.swift", from: "body(for: candidates)", to: "SheetFooterBar("),
        Boundary(path: "LiveWallpaper/Views/Playlist/WallpaperAutomationSheet.swift", from: ".pickerStyle(.segmented)", to: "queuePage"),
        Boundary(path: "LiveWallpaper/Views/Playlist/WallpaperAutomationSheet.swift", from: "schedulePage\n", to: #"Button("Cancel")"#),
        Boundary(path: "LiveWallpaper/Views/ScreenDetail/SceneDetailView.swift", from: "struct DiagnosticLogSheet", to: "private var header"),
        Boundary(path: "LiveWallpaper/Views/Monitor/AgentActivityPanel.swift", from: "sourceHealth\n", to: "HSplitView {"),
        Boundary(path: "LiveWallpaper/Views/Settings/SetupComponents.swift", from: "struct WorkshopPrivacySheet", to: "ScrollView {"),
        Boundary(path: "LiveWallpaper/Views/Settings/AppExceptionsSheet.swift", from: "var body: some View {", to: "footer\n"),
        Boundary(path: "LiveWallpaper/Views/Settings/ReportBugSheet.swift", from: "header\n", to: "diagnosticPreview\n"),
    ]

    @Test("No rule between a sheet's title area, its content and its buttons", arguments: Self.boundaries)
    func noRule(at boundary: Boundary) throws {
        let count = try Self.rules(in: boundary.path, from: boundary.from, to: boundary.to)
        #expect(count == 0, Comment(rawValue: "\(boundary.testDescription) still has \(count) Divider()"))
    }

    @Test("Control: the checker sees the failure page's kept rule and passes a sheet that never had one")
    func checkerSeesRules() throws {
        let kept = try Self.rules(in: "LiveWallpaper/Views/ScreenDetail/WallpaperFailureView.swift", from: "diagnosis\n", to: "displayOutcome\n")
        #expect(kept == 1, Comment(rawValue: "the checker counts \(kept) rules where the failure page keeps one"))
        let none = try Self.rules(in: "LiveWallpaper/Views/Workshop/SteamSignInSheet.swift", from: "var body: some View {", to: "SheetFooterBar(")
        #expect(none == 0, Comment(rawValue: "the checker counts \(none) rules in a sheet that has none"))
    }
}
