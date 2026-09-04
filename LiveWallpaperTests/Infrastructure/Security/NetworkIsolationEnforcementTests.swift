import Foundation
@testable import LiveWallpaper
import Testing
import WebKit

/// The other isolation tests assert that the CSP *header is emitted*. That is a
/// different claim from "WebKit enforces it", and on a custom URL scheme the
/// second does not follow from the first — if it did not hold, every Workshop
/// page would still be free to phone home while the whole suite stayed green.
/// So this loads a real page in a real `WKWebView` through the real handler and
/// watches for the `securitypolicyviolation` the browser itself raises.
@MainActor
@Suite("Workshop network isolation actually blocks egress")
struct NetworkIsolationEnforcementTests {
    /// Reports that it ran (via the collector's `localStorage` hook) and then
    /// attempts one remote fetch. `.invalid` is reserved by RFC 2606 and never
    /// resolves, so an unblocked attempt fails at DNS — which is not a CSP
    /// violation and keeps the control group unambiguous.
    private static let probePage = """
    <!doctype html><meta charset="utf-8"><body><script>
    try { localStorage.getItem('lw-probe-ran'); } catch (e) {}
    fetch('https://example.invalid/probe').catch(function () {});
    </script></body>
    """

    private func makeProbeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lw-isolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(Self.probePage.utf8).write(to: folder.appendingPathComponent("index.html"))
        return folder
    }

    private func observations(
        networkIsolated: Bool,
        cspEnforced: Bool
    ) async throws -> [CSPViolationCollector.Observation] {
        let folder = try makeProbeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let collector = CSPViolationCollector()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(
            WKUserScript(
                source: CSPViolationCollector.instrumentationSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        config.userContentController.add(collector, name: CSPViolationCollector.messageHandlerName)

        let handler = FolderURLSchemeHandler()
        handler.networkIsolationEnabled = networkIsolated
        handler.cspEnforcementEnabled = cspEnforced
        config.setURLSchemeHandler(handler, forURLScheme: FolderURLSchemeHandler.scheme)

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
        handler.folderURL = folder
        let nonce = try #require(handler.currentSessionNonce)
        let entry = try #require(
            URL(string: "\(FolderURLSchemeHandler.scheme)://\(FolderURLSchemeHandler.host)/index.html?n=\(nonce)")
        )
        webView.load(URLRequest(url: entry))

        // Poll rather than dwell: the blocked case reports within a frame or two,
        // and the control still has to prove its script ran before we call it quiet.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            let seen = collector.observations
            if seen.contains(where: { $0.kind == .storageAccess }),
               networkIsolated == false || seen.contains(where: { $0.kind == .cspViolation }) {
                break
            }
        }
        return collector.observations
    }

    @Test("An isolated page's remote fetch is blocked by the browser")
    func isolatedRemoteFetchRaisesACSPViolation() async throws {
        let seen = try await observations(networkIsolated: true, cspEnforced: false)

        #expect(
            seen.contains { $0.kind == .storageAccess },
            "probe script never ran, so the absence of a fetch proves nothing: \(seen.map(\.message))"
        )
        let violations = seen.filter { $0.kind == .cspViolation }
        #expect(
            violations.contains { ($0.directive ?? "").contains("connect-src") },
            "no connect-src violation; WebKit is not enforcing the header on this scheme: \(seen.map(\.message))"
        )
        #expect(
            violations.contains { ($0.blockedURI ?? "").contains("example.invalid") },
            "violation did not name the remote target: \(violations.map { $0.blockedURI ?? "<nil>" })"
        )
    }

    /// Control group. Without isolation and without the opt-in toggle no policy
    /// is served at all, so the identical page must produce no violation — that
    /// is what makes the assertion above a measurement of the policy rather than
    /// of `example.invalid` being unreachable.
    @Test("The same page with no policy raises no violation")
    func unpolicedRemoteFetchRaisesNoViolation() async throws {
        let seen = try await observations(networkIsolated: false, cspEnforced: false)

        #expect(
            seen.contains { $0.kind == .storageAccess },
            "probe script never ran, so the control proves nothing: \(seen.map(\.message))"
        )
        #expect(
            !seen.contains { $0.kind == .cspViolation },
            "a page served no policy still reported a CSP violation: \(seen.map(\.message))"
        )
    }

    // MARK: - WebRTC

    /// Loads a page that reports whether `RTCPeerConnection` exists, optionally
    /// with the production blocker injected exactly as `makeBaselineScript` does.
    /// Reported through a rejected promise because that is the one channel the
    /// collector passes through verbatim.
    private func peerConnectionAvailability(withBlocker: Bool) async throws -> [String] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lw-rtc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = """
        <!doctype html><meta charset="utf-8"><body><script>
        Promise.reject(new Error('RTC type=' + (typeof RTCPeerConnection)));
        </script></body>
        """
        try Data(page.utf8).write(to: folder.appendingPathComponent("index.html"))

        let collector = CSPViolationCollector()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(
            WKUserScript(
                source: CSPViolationCollector.instrumentationSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        if withBlocker {
            config.userContentController.addUserScript(
                WKUserScript(
                    source: HTMLWallpaperRuntimeScript.peerConnectionBlocker(),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }
        config.userContentController.add(collector, name: CSPViolationCollector.messageHandlerName)

        let handler = FolderURLSchemeHandler()
        handler.networkIsolationEnabled = true
        config.setURLSchemeHandler(handler, forURLScheme: FolderURLSchemeHandler.scheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
        handler.folderURL = folder
        let nonce = try #require(handler.currentSessionNonce)
        let entry = try #require(
            URL(string: "\(FolderURLSchemeHandler.scheme)://\(FolderURLSchemeHandler.host)/index.html?n=\(nonce)")
        )
        webView.load(URLRequest(url: entry))

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            if collector.observations.contains(where: { $0.message.hasPrefix("RTC type=") }) {
                break
            }
        }
        return collector.observations.map(\.message)
    }

    /// Measured 2026-08-31: under the isolation CSP alone a page still constructed
    /// an `RTCPeerConnection`, offered, and gathered an `srflx` candidate from
    /// `stun.l.google.com` — real UDP egress plus the user's public IP. CSP has no
    /// say over ICE, so the constructor has to go.
    @Test("An isolated page has no peer-connection constructor")
    func isolationRemovesPeerConnection() async throws {
        let seen = try await peerConnectionAvailability(withBlocker: true)
        #expect(seen.contains("RTC type=undefined"), "\(seen)")
    }

    /// Control, and the reason the blocker exists: the CSP by itself leaves the
    /// constructor in place. If WebKit ever gains `webrtc`-directive support this
    /// goes red, which is the right moment to revisit.
    @Test("The CSP alone leaves the constructor in place")
    func cspAloneDoesNotRemovePeerConnection() async throws {
        let seen = try await peerConnectionAvailability(withBlocker: false)
        #expect(seen.contains("RTC type=function"), "\(seen)")
    }

    /// The two tests above prove the blocker works when it is injected. This pins
    /// that the shipping path injects it, and gates it on provenance — a unit test
    /// on the script itself cannot see `makeBaselineScript` dropping the call.
    @Test("The baseline script injects the blocker, gated on isolation")
    func baselineScriptWiresTheBlockerToIsolation() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/VideoPlayback/HTMLWallpaperView.swift")
        let gate = source
            .split(separator: "\n")
            .first { $0.contains("HTMLWallpaperRuntimeScript.peerConnectionBlocker()") }
        #expect(gate != nil, "the baseline script no longer builds the blocker at all")
        let gateIndex = try #require(source.range(of: "HTMLWallpaperRuntimeScript.peerConnectionBlocker()"))
        let preamble = source[source.startIndex ..< gateIndex.lowerBound].suffix(200)
        #expect(
            preamble.contains("requiresNetworkIsolation"),
            "the blocker is no longer gated on Workshop provenance"
        )
        #expect(
            source.contains("\\(peerConnectionBlocker)"),
            "the blocker is built but never interpolated into the injected script"
        )
    }
}
