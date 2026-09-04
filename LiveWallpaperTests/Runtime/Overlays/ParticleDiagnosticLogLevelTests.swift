import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Testing

/// `WPEParticleDefinition.parse(dictionary:)` logs every collected diagnostic,
/// but all of its own construction sites carry `severity: .info`. Hard-coding
/// `Logger.warning` there published each of them into the user's runtime log —
/// one operator note accounted for ~10% of a real 893-line report.
@Suite("Particle diagnostic log level")
struct ParticleDiagnosticLogLevelTests {
    @Test("An info-severity diagnostic never reaches the runtime log file")
    func infoSeverityStaysOffTheFileSink() {
        let level = WPESceneDiagnostic.Severity.info.logLevel

        #expect(level == .info)
        #expect(!LogFileSink.admitsToFile(level))
    }

    @Test("A warning-severity diagnostic still reaches the runtime log file")
    func warningSeverityStillReachesTheFileSink() {
        let level = WPESceneDiagnostic.Severity.warning.logLevel

        #expect(level == .warning)
        #expect(LogFileSink.admitsToFile(level))
    }

    @Test("The severity a diagnostic is built with is the severity it logs at")
    func diagnosticCarriesItsOwnSeverity() {
        let note = WPESceneDiagnostic(severity: .info, message: "unsupported operator 'foo'")
        let problem = WPESceneDiagnostic(severity: .warning, message: "malformed particle")

        #expect(!LogFileSink.admitsToFile(note.severity.logLevel))
        #expect(LogFileSink.admitsToFile(problem.severity.logLevel))
    }
}
