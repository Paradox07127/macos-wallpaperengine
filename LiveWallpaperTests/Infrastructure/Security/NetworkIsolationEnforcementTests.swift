import Foundation
@testable import LiveWallpaper
import Testing
import WebKit

@MainActor
@Suite("Workshop network isolation actually blocks egress")
struct NetworkIsolationEnforcementTests {
    /// `.invalid` is reserved by RFC 2606 and never resolves, so an unblocked fetch fails
    /// at DNS — not a CSP violation, which keeps the control group unambiguous.
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

    /// Control group: with no policy served the identical page must produce no violation —
    /// that is what makes the test above measure the policy, not an unreachable host.
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

    /// Reported through a rejected promise because that is the one channel the collector
    /// passes through verbatim.
    private func peerConnectionAvailability(
        withBlocker: Bool,
        blockerMainFrameOnly: Bool = false,
        probeChildFrame: Bool = false
    ) async throws -> [String] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lw-rtc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A src-less iframe gets its initial about:blank realm without a load, so frame-src never sees it.
        let probe = probeChildFrame
            ? """
            var f = document.createElement('iframe');
            document.body.appendChild(f);
            var t; try { t = typeof f.contentWindow.RTCPeerConnection; } catch (e) { t = 'threw'; }
            Promise.reject(new Error('RTC type=' + t));
            """
            : "Promise.reject(new Error('RTC type=' + (typeof RTCPeerConnection)));"
        let page = """
        <!doctype html><meta charset="utf-8"><body><script>
        \(probe)
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
                    forMainFrameOnly: blockerMainFrameOnly
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

    @Test("An isolated page has no peer-connection constructor")
    func isolationRemovesPeerConnection() async throws {
        let seen = try await peerConnectionAvailability(withBlocker: true)
        #expect(seen.contains("RTC type=undefined"), "\(seen)")
    }

    @Test("A src-less child iframe of an isolated page has no peer-connection constructor")
    func isolationRemovesPeerConnectionInChildFrame() async throws {
        let seen = try await peerConnectionAvailability(withBlocker: true, probeChildFrame: true)
        #expect(seen.contains("RTC type=undefined"), "\(seen)")
    }

    /// Control group: proves the child-frame probe can see a surviving constructor at all.
    @Test("A main-frame-only blocker leaves the child realm's constructor in place")
    func mainFrameOnlyBlockerMissesChildFrame() async throws {
        let seen = try await peerConnectionAvailability(withBlocker: true, blockerMainFrameOnly: true, probeChildFrame: true)
        #expect(seen.contains("RTC type=function"), "\(seen)")
    }

    @Test("The CSP alone leaves the constructor in place")
    func cspAloneDoesNotRemovePeerConnection() async throws {
        let seen = try await peerConnectionAvailability(withBlocker: false)
        #expect(seen.contains("RTC type=function"), "\(seen)")
    }

    @Test("The live view injects the blocker into every frame, gated on isolation")
    func liveViewWiresTheBlockerToIsolation() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Playback/Web/HTMLWallpaperView.swift")
        let gateIndex = try #require(
            source.range(of: "HTMLWallpaperRuntimeScript.peerConnectionBlocker()"),
            "the live view no longer installs the blocker at all"
        )
        let preamble = source[source.startIndex ..< gateIndex.lowerBound].suffix(200)
        #expect(
            preamble.contains("requiresNetworkIsolation"),
            "the blocker is no longer gated on Workshop provenance"
        )
        let installation = source[gateIndex.upperBound...].prefix(120)
        #expect(
            installation.contains("forMainFrameOnly: false"),
            "the blocker is main-frame only, so a src-less child iframe keeps RTCPeerConnection"
        )
    }
}
