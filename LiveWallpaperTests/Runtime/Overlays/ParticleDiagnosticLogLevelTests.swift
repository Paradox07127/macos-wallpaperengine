import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Testing

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

}
