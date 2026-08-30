import AppKit
import Foundation
import LiveWallpaperCore

/// `Identifiable` so SwiftUI's `.sheet(item:)` can present the report; the id changes on every fresh `makeReport(...)` call so re-opening the sheet re-renders even if the diagnostic content happens to be byte-identical.
struct BugReport: Identifiable, Sendable {
    let id = UUID()
    let diagnosticMarkdown: String
    let issueURL: URL
    let logFileURL: URL?
    let logFileExists: Bool
}

enum BugReporter {
    /// Hardcoded rather than read from a build setting because the issue URL
    /// must survive even if `Bundle` lookups fail.
    private static let newIssueURLString = "https://github.com/Paradox07127/macos-wallpaperengine/issues/new"

    /// File names under `.github/ISSUE_TEMPLATE/`. `BugReporterTemplateTests`
    /// checks both still exist, because a renamed template fails as a GitHub
    /// 404 long after the rename, with nothing on this side to notice.
    static let englishTemplateName = "bug_report.yml"
    static let simplifiedChineseTemplateName = "bug_report_zh.yml"

    /// The two issue forms that exist. Both the GitHub template and the
    /// pre-filled body follow this one choice, so a reporter never lands on a
    /// Chinese form holding an English body.
    enum IssueForm: Sendable {
        case english
        case simplifiedChinese

        var templateName: String {
            switch self {
            case .english: BugReporter.englishTemplateName
            case .simplifiedChinese: BugReporter.simplifiedChineseTemplateName
            }
        }
    }

    /// Which form the in-app report opens. Simplified Chinese is the only language with a form of its own,
    /// so it is the only one that gets it; Traditional Chinese and Japanese readers land on the English
    /// form because that is the only other one that exists. Following the app's own language rather than
    /// the system's matters when someone has overridden it — the form should match the UI they are
    /// describing.
    static func issueForm(
        preference: AppLanguagePreference = .current,
        systemLocalizations: [String] = Bundle.main.preferredLocalizations
    ) -> IssueForm {
        let language = preference == .system ? systemLocalizations.first : preference.rawValue
        return language == AppLanguagePreference.simplifiedChinese.rawValue
            ? .simplifiedChinese
            : .english
    }

    private static func issueTemplateURL(named template: String) -> URL {
        URL(string: "\(newIssueURLString)?template=\(template)")!
    }

    /// How many recent warning/error lines we lift from the runtime log into the markdown preview.
    private static let recentLogLineCount = 5
    private static let maxLogLineLength = 500
    /// Hard cap on the markdown body before URL encoding.
    private static let maxBodyLength = 6 * 1024

    @MainActor
    static func makeReport(activeWallpapers: [String]) -> BugReport {
        let snapshot = SystemSnapshot.capture(activeWallpapers: activeWallpapers)
        let recentLog = sanitizedRecentLogLines()
        let form = issueForm()
        let markdown = capped(
            formatMarkdown(snapshot: snapshot, recentLogLines: recentLog, form: form),
            to: maxBodyLength,
            form: form
        )
        return BugReport(
            diagnosticMarkdown: markdown,
            issueURL: makeIssueURL(prefilledBody: markdown, template: form.templateName),
            logFileURL: Logger.persistentLogFileURL,
            logFileExists: logFileExists()
        )
    }

    // MARK: - Markdown

    static func formatMarkdown(
        snapshot: SystemSnapshot,
        recentLogLines: [String],
        form: IssueForm
    ) -> String {
        switch form {
        case .english:
            englishMarkdown(snapshot: snapshot, recentLogLines: recentLogLines)
        case .simplifiedChinese:
            simplifiedChineseMarkdown(snapshot: snapshot, recentLogLines: recentLogLines)
        }
    }

    private static func englishMarkdown(snapshot: SystemSnapshot, recentLogLines: [String]) -> String {
        var sections: [String] = []

        sections.append("""
        <details><summary>Diagnostic snapshot — auto-generated, please review before posting</summary>

        - **App**: \(BundleIdentity.productDisplayName) \(snapshot.appVersion) (Build \(snapshot.appBuild)) — \(snapshot.sku.rawValue) SKU
        - **macOS**: \(snapshot.macOSVersion) (\(snapshot.macOSBuild))
        - **Hardware**: \(snapshot.hardwareModel) · \(snapshot.chip) · \(snapshot.physicalMemoryGiB) GB
        - **Displays**: \(formatDisplays(snapshot.displays, form: .english))
        - **Active wallpapers**: \(snapshot.activeWallpapers.isEmpty ? "(none)" : snapshot.activeWallpapers.joined(separator: ", "))
        - **Locale**: \(snapshot.localeIdentifier)
        - **Bundle**: `\(snapshot.bundleIdentifier)`
        """)

        if recentLogLines.isEmpty {
            sections.append("- **Recent activity**: (none recorded)")
        } else {
            sections.append("""
            - **Recent activity — wallpapers applied, then warnings/errors** (last \(recentLogLines.count)):

            \(fencedLog(recentLogLines))
            """)
        }

        sections.append("</details>")

        sections.append("""

        ### What happened?
        <!-- describe the bug here -->

        ### Steps to reproduce
        1.&nbsp;
        2.&nbsp;
        3.&nbsp;

        ### Expected vs actual
        <!-- what did you expect? what happened instead? -->
        """)

        return sections.joined(separator: "\n\n")
    }

    /// Mirrors `englishMarkdown` line for line. Kept as a separate template
    /// rather than a table of localized fragments because the body is prose
    /// pasted into a GitHub form, and the two forms under
    /// `.github/ISSUE_TEMPLATE/` are maintained the same way.
    private static func simplifiedChineseMarkdown(snapshot: SystemSnapshot, recentLogLines: [String]) -> String {
        var sections: [String] = []

        sections.append("""
        <details><summary>诊断信息 — 自动生成，提交前请自行过目</summary>

        - **应用**：\(BundleIdentity.productDisplayName) \(snapshot.appVersion)（Build \(snapshot.appBuild)）— \(snapshot.sku.rawValue) 版
        - **macOS**：\(snapshot.macOSVersion)（\(snapshot.macOSBuild)）
        - **硬件**：\(snapshot.hardwareModel) · \(snapshot.chip) · \(snapshot.physicalMemoryGiB) GB
        - **显示器**：\(formatDisplays(snapshot.displays, form: .simplifiedChinese))
        - **正在播放的壁纸**：\(snapshot.activeWallpapers.isEmpty ? "（无）" : snapshot.activeWallpapers.joined(separator: "、"))
        - **语言区域**：\(snapshot.localeIdentifier)
        - **Bundle**：`\(snapshot.bundleIdentifier)`
        """)

        if recentLogLines.isEmpty {
            sections.append("- **最近活动**：（没有记录）")
        } else {
            sections.append("""
            - **最近活动 — 先是应用的壁纸，然后是警告 / 错误**（最近 \(recentLogLines.count) 条）：

            \(fencedLog(recentLogLines))
            """)
        }

        sections.append("</details>")

        sections.append("""

        ### 发生了什么？
        <!-- 在这里描述问题 -->

        ### 复现步骤
        1.&nbsp;
        2.&nbsp;
        3.&nbsp;

        ### 期望结果 vs 实际结果
        <!-- 你本来期待看到什么？实际看到的又是什么？ -->
        """)

        return sections.joined(separator: "\n\n")
    }

    private static func formatDisplays(
        _ displays: [SystemSnapshot.DisplayDescriptor],
        form: IssueForm
    ) -> String {
        guard !displays.isEmpty else {
            return form == .simplifiedChinese ? "（没有检测到）" : "(none detected)"
        }
        let parts = displays.map { d in
            "\(d.pixelWidth)×\(d.pixelHeight) @\(d.backingScaleFactor)x"
        }
        let joined = parts.joined(separator: " · ")
        return form == .simplifiedChinese
            ? "\(displays.count) 台（\(joined)）"
            : "\(displays.count) connected (\(joined))"
    }

    /// Fenced code block: a single ``` boundary is safer than per-line backticks because it survives `` ` `` characters embedded in the log line itself.
    private static func fencedLog(_ lines: [String]) -> String {
        let fence = safeCodeFence(for: lines)
        return "\(fence)\n\(lines.joined(separator: "\n"))\n\(fence)"
    }

    /// Picks the shortest fence (`` ``` ``, `` ```` ``, …) that does not appear inside any of the lines — preventing user content from prematurely closing the code block.
    private static func safeCodeFence(for lines: [String]) -> String {
        var fence = "```"
        while lines.contains(where: { $0.contains(fence) }) {
            fence += "`"
        }
        return fence
    }

    private static func capped(_ text: String, to maxBytes: Int, form: IssueForm) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let limit = maxBytes - 32
        var index = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        while index > text.startIndex && text[..<index].utf8.count > limit {
            index = text.index(before: index)
        }
        let notice = form == .simplifiedChinese ? "…(诊断信息已截断)" : "…(diagnostic truncated)"
        return String(text[..<index]) + "\n\n" + notice
    }

    // MARK: - GitHub URL

    private static func makeIssueURL(prefilledBody: String, template: String) -> URL {
        let templateURL = issueTemplateURL(named: template)
        var components = URLComponents(url: templateURL, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "body", value: prefilledBody))
        components.queryItems = items
        return components.url ?? templateURL
    }

    // MARK: - Runtime log scan

    private static func logFileExists() -> Bool {
        guard let url = Logger.persistentLogFileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Pulls the most recent WARNING/ERROR/FAULT lines from `LogFileSink` (which holds the lock so we never observe a torn write or stale rotation).
    private static func sanitizedRecentLogLines() -> [String] {
        LogFileSink.shared
            .recentDiagnosticLines(maxLines: recentLogLineCount, maxLineLength: maxLogLineLength)
    }

    // MARK: - Side-effecting helpers (called from the sheet's button actions)

    @MainActor
    static func revealLogInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor
    static func openIssueInBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
