import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

/// Which GitHub issue form the in-app **Report a Bug** row's Open button uses.
@Suite("Bug report template selection")
struct BugReporterTemplateTests {
    @Test("Simplified Chinese is the only language with its own form")
    func simplifiedChineseGetsItsOwnTemplate() {
        #expect(
            BugReporter.issueForm(preference: .simplifiedChinese, systemLocalizations: ["en"]).templateName
                == BugReporter.simplifiedChineseTemplateName
        )
    }

    @Test("Traditional Chinese, Japanese and English all get the English form")
    func everyOtherLanguageGetsTheEnglishTemplate() {
        for preference in [
            AppLanguagePreference.english,
            .traditionalChinese,
            .japanese
        ] {
            #expect(
                BugReporter.issueForm(preference: preference, systemLocalizations: ["zh-Hans"]).templateName
                    == BugReporter.englishTemplateName,
                "\(preference.rawValue) should use the English form"
            )
        }
    }

    /// An explicit language override has to win over the system's: the reporter
    /// is describing the UI they are looking at, not the one macOS would pick.
    @Test("An explicit override outranks the system localization")
    func explicitPreferenceBeatsSystemLocalization() {
        #expect(
            BugReporter.issueForm(preference: .english, systemLocalizations: ["zh-Hans"]).templateName
                == BugReporter.englishTemplateName
        )
        #expect(
            BugReporter.issueForm(preference: .simplifiedChinese, systemLocalizations: ["ja"]).templateName
                == BugReporter.simplifiedChineseTemplateName
        )
    }

    @Test("Following the system resolves through the bundle's localizations")
    func systemPreferenceFollowsResolvedLocalization() {
        #expect(
            BugReporter.issueForm(preference: .system, systemLocalizations: ["zh-Hans", "en"]).templateName
                == BugReporter.simplifiedChineseTemplateName
        )
        #expect(
            BugReporter.issueForm(preference: .system, systemLocalizations: ["zh-Hant", "en"]).templateName
                == BugReporter.englishTemplateName
        )
        // No resolved localization at all must not crash into the Chinese form.
        #expect(
            BugReporter.issueForm(preference: .system, systemLocalizations: []).templateName
                == BugReporter.englishTemplateName
        )
    }

    /// The names are strings in Swift and file names on disk; nothing but this
    /// keeps them equal. A rename shows up as a GitHub 404 for users only.
    @Test("Both templates exist under .github/ISSUE_TEMPLATE")
    func referencedTemplatesExistOnDisk() {
        for name in [BugReporter.englishTemplateName, BugReporter.simplifiedChineseTemplateName] {
            let url = RepositoryRoot.url(".github/ISSUE_TEMPLATE/\(name)")
            #expect(FileManager.default.fileExists(atPath: url.path), "missing \(name)")
        }
    }
}

/// The pre-filled issue body has to be written in the same language as the form
/// it is pasted into — a Chinese form holding an English outline is the bug this
/// suite exists to catch.
@Suite("Bug report body language")
struct BugReporterBodyLanguageTests {
    private static func snapshot(
        displays: [SystemSnapshot.DisplayDescriptor] = [
            SystemSnapshot.DisplayDescriptor(pixelWidth: 3456, pixelHeight: 2234, backingScaleFactor: 2)
        ],
        activeWallpapers: [String] = ["scene"]
    ) -> SystemSnapshot {
        SystemSnapshot(
            appVersion: "0.6.0",
            appBuild: "1",
            sku: .pro,
            macOSVersion: "15.2",
            macOSBuild: "24C101",
            hardwareModel: "Mac17,8",
            chip: "Apple M4 Pro",
            physicalMemoryGiB: 24,
            displays: displays,
            activeWallpapers: activeWallpapers,
            bundleIdentifier: "com.loomscreen.pro",
            localeIdentifier: "zh_CN"
        )
    }

    @Test("The Chinese form gets a Chinese outline")
    func chineseFormGetsChineseBody() {
        let body = BugReporter.formatMarkdown(
            snapshot: Self.snapshot(),
            recentLogLines: ["ERROR: boom"],
            form: .simplifiedChinese
        )
        #expect(body.contains("### 发生了什么？"))
        #expect(body.contains("### 复现步骤"))
        #expect(body.contains("### 期望结果 vs 实际结果"))
        #expect(body.contains("**最近活动 — 先是应用的壁纸，然后是警告 / 错误**（最近 1 条）"))
        #expect(!body.contains("### What happened?"))
        #expect(!body.contains("Recent activity"))
    }

    @Test("The English form is unchanged")
    func englishFormGetsEnglishBody() {
        let body = BugReporter.formatMarkdown(
            snapshot: Self.snapshot(),
            recentLogLines: ["ERROR: boom"],
            form: .english
        )
        #expect(body.contains("### What happened?"))
        #expect(body.contains("### Steps to reproduce"))
        #expect(body.contains("### Expected vs actual"))
        #expect(body.contains("**Recent activity — wallpapers applied, then warnings/errors** (last 1)"))
        #expect(!body.contains("发生了什么"))
    }

    /// The empty-state and display fragments are interpolated separately from
    /// the outline, so they can go stale on their own.
    @Test("Empty states follow the form's language too")
    func emptyStatesAreLocalized() {
        let empty = Self.snapshot(displays: [], activeWallpapers: [])

        let chinese = BugReporter.formatMarkdown(snapshot: empty, recentLogLines: [], form: .simplifiedChinese)
        #expect(chinese.contains("（没有检测到）"))
        #expect(chinese.contains("**正在播放的壁纸**：（无）"))
        #expect(chinese.contains("**最近活动**：（没有记录）"))

        let english = BugReporter.formatMarkdown(snapshot: empty, recentLogLines: [], form: .english)
        #expect(english.contains("(none detected)"))
        #expect(english.contains("**Active wallpapers**: (none)"))
        #expect(english.contains("(none recorded)"))
    }

    @Test("Both display lists keep the same measurements")
    func displayCountsMatchAcrossForms() {
        let snapshot = Self.snapshot()
        for form in [BugReporter.IssueForm.english, .simplifiedChinese] {
            let body = BugReporter.formatMarkdown(snapshot: snapshot, recentLogLines: [], form: form)
            #expect(body.contains("3456×2234 @2x"), "\(form) dropped the display measurements")
        }
    }

    /// One decision drives both halves; this is what stops them drifting apart.
    @Test("Form choice drives the template name and the body together")
    func formDrivesTemplateAndBody() {
        let chineseForm = BugReporter.issueForm(preference: .simplifiedChinese, systemLocalizations: ["en"])
        #expect(chineseForm.templateName == BugReporter.simplifiedChineseTemplateName)
        #expect(
            BugReporter.formatMarkdown(snapshot: Self.snapshot(), recentLogLines: [], form: chineseForm)
                .contains("### 发生了什么？")
        )

        let japaneseForm = BugReporter.issueForm(preference: .japanese, systemLocalizations: ["zh-Hans"])
        #expect(japaneseForm.templateName == BugReporter.englishTemplateName)
        #expect(
            BugReporter.formatMarkdown(snapshot: Self.snapshot(), recentLogLines: [], form: japaneseForm)
                .contains("### What happened?")
        )
    }
}
