import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// `WallpaperFailureCause.code` is an open namespace: unmapped `NSError`s arrive
/// as "<domain>.<code>".
@Suite("Wallpaper failure classification")
struct WallpaperFailureClassificationTests {
    private func cause(_ code: String, canRetry: Bool = true) -> WallpaperFailureCause {
        WallpaperFailureCause(code: code, reason: "reason", canRetry: canRetry)
    }

    /// Losing one of these would downgrade an unreachable file into a Retry that
    /// re-walks the same path.
    private let relinkCodes = [
        "NSCocoaErrorDomain.257",
        "runtime.fileAccessDenied",
        "runtime.sandboxRevoked",
        "scene.cache_missing",
        "scene.source_unavailable",
    ]

    @Test("Unreachable content asks to be re-linked, never to be retried")
    func relinkCodesOfferChooseSource() {
        for code in relinkCodes {
            let subject = cause(code)
            #expect(subject.failureClass == .needsParts, "\(code)")
            let actions = subject.recovery(workshopID: nil, canChooseSource: true)
            #expect(actions.first == .chooseSource, "\(code)")
            #expect(!actions.contains(.retry), "\(code)")
        }
    }

    /// Lite ships no project importer.
    @Test("With no source chooser the dead button is absent, not inert")
    func relinkWithoutChooserOffersNoDeadButton() {
        let actions = cause("runtime.fileAccessDenied", canRetry: false)
            .recovery(workshopID: nil, canChooseSource: false)
        #expect(actions.isEmpty)
    }

    @Test("Permanently unsupported codes are fatal whatever the producer said about retrying")
    func fatalCodes() {
        for code in ["scene.metal_unsupported", "scene.unsafe_path", "scene.windows_plugin",
                     "texture.metal_compression", "texture.metal_format", "texture.metal_unavailable"] {
            #expect(cause(code, canRetry: false).failureClass == .fatal, "\(code)")
            #expect(cause(code, canRetry: true).failureClass == .fatal, "\(code)")
            #expect(cause(code, canRetry: false).recovery(workshopID: nil, canChooseSource: true).isEmpty, "\(code)")
            // `WPEImportCoordinator` emits `scene.windows_plugin` with `canRetry: true` when
            // the same project also has missing dependencies, so the page must still offer no Retry.
            let retryable = cause(code, canRetry: true).recovery(workshopID: "1234567890", canChooseSource: true)
            #expect(!retryable.contains(.retry), "\(code)")
            #expect(!retryable.contains(.chooseSource), "\(code)")
            #expect(retryable == [.openWorkshop("1234567890")], "\(code)")
        }
    }

    /// The safe default. Promoting an unrecognised code to `.fatal` would tell a
    /// user their Mac can never run something over a typo in an error domain.
    @Test("An unmapped code keeps the recoverable treatment it has today")
    func unknownCodeStaysBlocked() {
        let subject = cause("SomeFrameworkErrorDomain.42")
        #expect(subject.failureClass == .blocked)
        #expect(subject.failureClass.tint == DesignTokens.Colors.Status.warning)
        #expect(subject.recovery(workshopID: nil, canChooseSource: true) == [.retry])
    }

    @Test("Tint and kicker are pure functions of the class, so one code cannot carry two colours")
    func appearanceFollowsClass() {
        let expected: [(WallpaperFailureClass, Color)] = [
            (.fatal, DesignTokens.Colors.Status.danger),
            (.blocked, DesignTokens.Colors.Status.warning),
            (.needsParts, DesignTokens.Colors.Status.caution),
            (.degraded, DesignTokens.Colors.Status.caution),
        ]
        for (failureClass, tint) in expected {
            #expect(failureClass.tint == tint)
            #expect(!failureClass.symbol.isEmpty)
        }
        // Colour never carries the meaning alone (DESIGN.md rule 6): the two
        // classes that share `caution` must still differ by glyph.
        #expect(WallpaperFailureClass.needsParts.symbol != WallpaperFailureClass.degraded.symbol)
    }

    @Test("Only a real Steam id earns a Workshop link")
    func workshopLinkRequiresNumericID() {
        let subject = cause("scene.parse", canRetry: false)
        #expect(subject.recovery(workshopID: "1234567890", canChooseSource: true) == [.openWorkshop("1234567890")])
        #expect(subject.recovery(workshopID: "local-folder", canChooseSource: true).isEmpty)
        #expect(subject.recovery(workshopID: "", canChooseSource: true).isEmpty)
        #expect(subject.recovery(workshopID: nil, canChooseSource: true).isEmpty)
    }

    @Test("Workshop never leads the recovery row when a real recovery exists")
    func workshopNeverLeads() {
        let actions = cause("scene.cache_missing").recovery(workshopID: "1234567890", canChooseSource: true)
        #expect(actions.first == .chooseSource)
        #expect(actions.last == .openWorkshop("1234567890"))
    }
}
