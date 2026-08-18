import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

/// Which GitHub issue form the in-app **Report a Bug…** button opens.
@Suite("Bug report template selection")
struct BugReporterTemplateTests {
    @Test("Simplified Chinese is the only language with its own form")
    func simplifiedChineseGetsItsOwnTemplate() {
        #expect(
            BugReporter.issueTemplateName(preference: .simplifiedChinese, systemLocalizations: ["en"])
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
                BugReporter.issueTemplateName(preference: preference, systemLocalizations: ["zh-Hans"])
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
            BugReporter.issueTemplateName(preference: .english, systemLocalizations: ["zh-Hans"])
                == BugReporter.englishTemplateName
        )
        #expect(
            BugReporter.issueTemplateName(preference: .simplifiedChinese, systemLocalizations: ["ja"])
                == BugReporter.simplifiedChineseTemplateName
        )
    }

    @Test("Following the system resolves through the bundle's localizations")
    func systemPreferenceFollowsResolvedLocalization() {
        #expect(
            BugReporter.issueTemplateName(preference: .system, systemLocalizations: ["zh-Hans", "en"])
                == BugReporter.simplifiedChineseTemplateName
        )
        #expect(
            BugReporter.issueTemplateName(preference: .system, systemLocalizations: ["zh-Hant", "en"])
                == BugReporter.englishTemplateName
        )
        // No resolved localization at all must not crash into the Chinese form.
        #expect(
            BugReporter.issueTemplateName(preference: .system, systemLocalizations: [])
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
