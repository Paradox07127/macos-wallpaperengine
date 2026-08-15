import Foundation
import Security
import Testing

// Without LITE_BUILD this bundle would assert Pro semantics against a Lite host
// and report green. The build setting is easy to mistype (Xcode quotes a value
// typed into the plain-text field), so fail at compile time rather than trust it.
#if !LITE_BUILD
    #error("LiveWallpaperLiteTests must compile with LITE_BUILD")
#endif

/// Closes the gap `EntitlementAuditTests.liteSignedAuditIsNotPretendedByProTestHost`
/// documents: the Pro test host can only ever prove Pro's signature, so Lite's
/// signed grants had no test-time gate — only `check_entitlements.sh` at release.
@Suite("Lite SKU smoke — signed Lite host invariants")
struct LiteHostSmokeTests {
    private static let proOnlyEntitlement = "com.apple.security.device.audio-input"

    private static func runtimeEntitlement(_ key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }

    @Test("Tests are injected into the signed Lite host, not Pro")
    func hostIsTheLiteApp() {
        #expect(Bundle.main.bundleIdentifier == "com.loomscreen")
    }

    @Test("Signed Lite host withholds the Pro-only audio-input grant")
    func liteHostWithholdsProOnlyGrants() {
        #expect(Self.runtimeEntitlement(Self.proOnlyEntitlement) == nil)
    }

    @Test("Signed Lite host keeps the shared sandbox grants", arguments: [
        "com.apple.security.app-sandbox",
        "com.apple.security.files.bookmarks.app-scope",
        "com.apple.security.files.user-selected.read-write",
        "com.apple.security.network.client",
    ])
    func liteHostKeepsSharedGrants(key: String) {
        #expect(Self.runtimeEntitlement(key) as? Bool == true)
    }
}
