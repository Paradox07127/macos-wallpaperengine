import Foundation
@testable import LiveWallpaper
import Testing
import WebKit

@Suite("HTML wallpaper transform keeps author layout")
struct HTMLWebTransformLayoutTests {
    @MainActor
    @Test("Scaled page keeps a fixed full-viewport canvas sized and centred on the viewport", .timeLimit(.minutes(1)))
    func fixedCanvasSurvivesScale() async throws {
        let webView = try await loadTransformed("""
        <!DOCTYPE html><html><head></head><body>
        <canvas id="c" style="position:fixed;top:0;left:0;width:100%;height:100%"></canvas>
        </body></html>
        """)
        defer { webView.stopLoading() }
        let result = try await measure(webView, """
        const rect = document.getElementById('c').getBoundingClientRect();
        return { height: rect.height, centerY: rect.top + rect.height / 2, viewport: window.innerHeight };
        """)
        let height = try #require(result["height"])
        let centerY = try #require(result["centerY"])
        let viewport = try #require(result["viewport"])
        #expect(viewport > 0)
        #expect(abs(height - viewport * 1.2) < 1, "canvas collapsed or mis-sized: \(height) vs viewport \(viewport)")
        #expect(abs(centerY - viewport / 2) < 1, "scale origin is not the viewport centre: \(centerY)")
    }

    @MainActor
    @Test("Scaled page taller than the viewport keeps a non-collapsed fixed canvas", .timeLimit(.minutes(1)))
    func fixedCanvasSurvivesScaleOnTallPage() async throws {
        let webView = try await loadTransformed("""
        <!DOCTYPE html><html><head></head><body>
        <div style="height:600px"></div>
        <canvas id="c" style="position:fixed;top:0;left:0;width:100%;height:100%"></canvas>
        </body></html>
        """)
        defer { webView.stopLoading() }
        let result = try await measure(webView, """
        const rect = document.getElementById('c').getBoundingClientRect();
        return { height: rect.height, viewport: window.innerHeight };
        """)
        let height = try #require(result["height"])
        let viewport = try #require(result["viewport"])
        #expect(viewport > 0)
        #expect(height >= viewport, "canvas collapsed on a tall page: \(height) vs viewport \(viewport)")
    }

    @MainActor
    @Test("Transform leaves an author height:100% element's layout height unchanged", .timeLimit(.minutes(1)))
    func percentHeightChildUnchangedByTransform() async throws {
        let webView = try await loadTransformed("""
        <!DOCTYPE html><html><head></head><body>
        <div id="p" style="height:100%"><div style="height:50px"></div></div>
        </body></html>
        """)
        defer { webView.stopLoading() }
        let probe = "return { height: document.getElementById('p').offsetHeight };"
        let scaled = try #require(try await measure(webView, probe)["height"])
        _ = try await webView.callAsyncJavaScript(
            "window.__lwUpdateTransform__(1, 0, 0, 0);", arguments: [:], in: nil, contentWorld: .page
        )
        let identity = try #require(try await measure(webView, probe)["height"])
        #expect(scaled == identity, "transform changed author percentage height: \(scaled) vs identity \(identity)")
    }

    @MainActor
    private func loadTransformed(_ html: String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: HTMLWallpaperRuntimeScript.transformController(
                scale: 1.2, translateX: 0, translateY: 0, rotation: 0
            ),
            injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 200), configuration: configuration)
        webView.loadHTMLString(html, baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(5)
        var ready = false
        while !ready, ContinuousClock.now < deadline {
            let probe = "document.readyState === 'complete' && document.documentElement.classList.contains('lw-transformed')"
            ready = await (try? webView.evaluateJavaScript(probe)) as? Bool == true
            if !ready {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(ready)
        return webView
    }

    @MainActor
    private func measure(_ webView: WKWebView, _ body: String) async throws -> [String: Double] {
        let raw = try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
        let result = try #require(raw as? [String: Any])
        return result.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }
}
