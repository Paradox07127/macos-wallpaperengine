import Foundation
import Testing
@testable import LiveWallpaperCore

/// Guards the three mechanisms that decide what a user's `runtime.log` actually
/// contains: which levels the file sink admits, which of those reach the bug
/// report excerpt, and the repeat-suppression on the screen-count breadcrumb.
@Suite("Log noise control")
struct LogNoiseControlTests {
    private static func makeSink() throws -> (LogFileSink, URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogNoiseControl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("runtime.log")
        _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        return (LogFileSink(fileURL: file), file, directory)
    }

    // MARK: - Sink admission

    @Test("The file sink admits notice and drops info")
    func sinkAdmitsNoticeDropsInfo() throws {
        let (sink, file, directory) = try Self.makeSink()
        defer { try? FileManager.default.removeItem(at: directory) }

        sink.record(category: .screenManager, level: .notice, message: "identity-line", file: "/s/A.swift", line: 1)
        sink.record(category: .screenManager, level: .info, message: "breadcrumb-line", file: "/s/A.swift", line: 2)
        sink.record(category: .screenManager, level: .debug, message: "debug-line", file: "/s/A.swift", line: 3)
        sink.record(category: .screenManager, level: .warning, message: "warning-line", file: "/s/A.swift", line: 4)

        let persisted = try String(contentsOf: file, encoding: .utf8)
        #expect(persisted.contains("identity-line"))
        #expect(persisted.contains("warning-line"))
        #expect(!persisted.contains("breadcrumb-line"))
        #expect(!persisted.contains("debug-line"))
    }

    @Test("Admission predicate is callable across module boundaries")
    func admissionPredicateIsPublic() {
        #expect(LogFileSink.admitsToFile(.notice))
        #expect(LogFileSink.admitsToFile(.warning))
        #expect(LogFileSink.admitsToFile(.error))
        #expect(LogFileSink.admitsToFile(.fault))
        #expect(!LogFileSink.admitsToFile(.info))
        #expect(!LogFileSink.admitsToFile(.debug))
    }

    // MARK: - Bug report excerpt

    @Test("recentDiagnosticLines carries NOTICE identity lines into the excerpt")
    func recentDiagnosticLinesIncludesNotice() throws {
        let (sink, _, directory) = try Self.makeSink()
        defer { try? FileManager.default.removeItem(at: directory) }

        sink.record(
            category: .screenManager,
            level: .notice,
            message: "Preparing scene wallpaper (workshop 123) for screen 1",
            file: "/s/ScreenManager+Monitor.swift",
            line: 360
        )

        let excerpt = sink.recentDiagnosticLines().joined(separator: "\n")
        #expect(excerpt.contains("[NOTICE]"))
        #expect(excerpt.contains("workshop 123"))
    }

    @Test("Identity notices never evict the failure they explain")
    func noticesDoNotCrowdOutFailures() throws {
        let (sink, _, directory) = try Self.makeSink()
        defer { try? FileManager.default.removeItem(at: directory) }

        sink.record(
            category: .wpeRender, level: .error, message: "Scene 999 failed: fileMissing",
            file: "/s/WPEMetalSceneRenderer+Load.swift", line: 124
        )
        // A playlist switching faster than the excerpt budget: under one shared
        // budget these push the error out entirely.
        for index in 0..<10 {
            sink.record(
                category: .screenManager, level: .notice,
                message: "Preparing scene wallpaper (workshop \(index)) for screen 1",
                file: "/s/ScreenManager+Monitor.swift", line: 360
            )
        }

        let excerpt = sink.recentDiagnosticLines().joined(separator: "\n")
        #expect(excerpt.contains("Scene 999 failed"))
        #expect(excerpt.contains("[NOTICE]"))
    }

    // MARK: - Screen count repeat suppression

    /// Serialized: the gate is one process-wide static, so parallel cases would
    /// consume each other's transitions.
    @Suite("Screen count repeat suppression", .serialized)
    struct ScreenCountGateTests {
        @Test("Screen count reports once per distinct count")
        func screenCountGateSuppressesRepeats() {
            Logger.resetScreenCountGateForTesting()

            #expect(Logger.shouldReportScreenCount(2))
            #expect(!Logger.shouldReportScreenCount(2))
            #expect(!Logger.shouldReportScreenCount(2))
            #expect(Logger.shouldReportScreenCount(3))
            #expect(!Logger.shouldReportScreenCount(3))
            #expect(Logger.shouldReportScreenCount(2))
        }

        @Test("The DEBUG reset hook makes the gate deterministic")
        func screenCountGateResets() {
            Logger.resetScreenCountGateForTesting()
            #expect(Logger.shouldReportScreenCount(1))
            #expect(!Logger.shouldReportScreenCount(1))

            Logger.resetScreenCountGateForTesting()
            #expect(Logger.shouldReportScreenCount(1))
        }
    }

    // MARK: - Untrusted title sanitizer

    @Test("Title sanitizer strips newlines so a title cannot forge a log line")
    func titleSanitizerStripsLineBreaks() {
        let forged = "Nice Scene\n2026-01-01T00:00:00Z [screenManager] [ERROR] fake.swift:1 — pwned"
        let sanitized = LogPrivacyRedactor.sanitizedTitle(forged)

        #expect(!sanitized.contains("\n"))
        #expect(!sanitized.contains("\r"))
        #expect(sanitized.hasPrefix("Nice Scene"))
    }

    @Test("Title sanitizer strips carriage returns, tabs and other control characters")
    func titleSanitizerStripsControlCharacters() {
        let sanitized = LogPrivacyRedactor.sanitizedTitle("a\r\nb\tc\u{0007}d\u{200B}e")

        #expect(!sanitized.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        #expect(sanitized == "a b c d e")
    }

    @Test("Title sanitizer truncates to the cap")
    func titleSanitizerTruncates() {
        let long = String(repeating: "x", count: 400)
        let sanitized = LogPrivacyRedactor.sanitizedTitle(long)

        #expect(sanitized.count <= 80)
        #expect(sanitized.hasSuffix("…"))
    }

    @Test("Title sanitizer leaves an ordinary title untouched")
    func titleSanitizerPreservesOrdinaryTitles() {
        #expect(LogPrivacyRedactor.sanitizedTitle("Cyberpunk Girl 4K") == "Cyberpunk Girl 4K")
    }

    /// The scene identity line must degrade to workshop-ID-only rather than
    /// printing a dangling separator or falling back to `"Scene <id>"`.
    @Test("Title fragment is empty when there is no usable title")
    func titleFragmentOmitsMissingTitles() {
        #expect(LogPrivacyRedactor.titleFragment(nil).isEmpty)
        #expect(LogPrivacyRedactor.titleFragment("").isEmpty)
        #expect(LogPrivacyRedactor.titleFragment("   ").isEmpty)
        #expect(LogPrivacyRedactor.titleFragment("Cyberpunk Girl 4K") == " — Cyberpunk Girl 4K")
    }
}
