import AppKit
import LiveWallpaperCore
import WebKit

/// Complete rendering contract for an offscreen HTML capture.
///
/// The service deliberately has no URL-only overload: every WebKit load must
/// carry the same already-normalized effective config as the live wallpaper.
struct HTMLSnapshotRequest: Sendable {
    let source: HTMLSource
    let loadURL: URL
    let cacheKey: String
    let effectiveConfig: HTMLConfig
    let localReadAccessRoot: URL?

    var remoteSourceOrigin: URL? {
        guard case .url(let url) = source else { return nil }
        return url
    }
}

/// Bridges WebKit load/snapshot callbacks to cancellation-safe async waiters.
@MainActor
final class PendingHTMLSnapshot: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private let request: HTMLSnapshotRequest
    private var continuation: CheckedContinuation<Bool, Never>?
    private var completedResult: Bool?
    private var snapshotContinuation: CheckedContinuation<NSImage?, Never>?
    private var snapshotCompleted = false
    private var isCancelled = false

    enum CompletionReason {
        case success
        case failure
        case timeout
    }

    init(webView: WKWebView, request: HTMLSnapshotRequest) {
        self.webView = webView
        self.request = request
    }

    func waitForLoadOutcome() async -> Bool {
        if let completedResult {
            return completedResult
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func complete(reason: CompletionReason) {
        guard completedResult == nil else { return }
        let result = reason == .success
        completedResult = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    func takeSnapshot(with configuration: WKSnapshotConfiguration) async -> NSImage? {
        guard !isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            guard !isCancelled, !snapshotCompleted else {
                continuation.resume(returning: nil)
                return
            }
            snapshotContinuation = continuation
            webView.takeSnapshot(with: configuration) { [weak self] image, _ in
                Task { @MainActor [weak self] in
                    self?.completeSnapshot(image)
                }
            }
        }
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        webView.stopLoading()
        complete(reason: .failure)
        completeSnapshot(nil)
    }

    private func completeSnapshot(_ image: NSImage?) {
        guard !snapshotCompleted else { return }
        snapshotCompleted = true
        let continuation = snapshotContinuation
        snapshotContinuation = nil
        continuation?.resume(returning: image)
    }

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                decisionHandler(.cancel)
                return
            }
            if navigationAction.targetFrame?.isMainFrame == false {
                decisionHandler(.allow)
                return
            }
            let decision = HTMLWallpaperView.navigationDecision(
                for: navigationAction.request.url,
                navigationType: navigationAction.navigationType,
                currentURL: webView.url,
                allowMouseInteraction: false,
                localReadAccessRoot: request.localReadAccessRoot,
                remoteSourceOrigin: request.remoteSourceOrigin
            )
            switch decision {
            case .allow:
                decisionHandler(.allow)
            case .cancel, .openExternally:
                decisionHandler(.cancel)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in self?.complete(reason: .success) }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor [weak self] in self?.complete(reason: .failure) }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor [weak self] in self?.complete(reason: .failure) }
    }
}
