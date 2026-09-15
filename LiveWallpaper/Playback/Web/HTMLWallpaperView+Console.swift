import Foundation
import LiveWallpaperCore
import WebKit

extension HTMLWallpaperView {
    nonisolated static let consoleMessageName = "lwConsole"
}

#if DEBUG

/// Same weak seam as the audio handler: the content controller retains what it is given.
@MainActor
final class ConsoleForwarderMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var target: HTMLWallpaperView?

    init(target: HTMLWallpaperView) {
        self.target = target
        super.init()
    }

    nonisolated func userContentController(
        _: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            target?.logPageConsoleMessage(message.body)
        }
    }
}

extension HTMLWallpaperView {
    var consoleForwarderScript: String? {
        HTMLWallpaperRuntimeScript.consoleForwarder(messageName: Self.consoleMessageName)
    }

    func installConsoleForwarderMessageHandler() {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.consoleMessageName)
        controller.add(ConsoleForwarderMessageProxy(target: self), name: Self.consoleMessageName)
    }

    /// Page text is author-controlled, so it is scrubbed even though this build never ships.
    func logPageConsoleMessage(_ body: Any) {
        guard let payload = body as? [String: Any],
              let level = payload["level"] as? String,
              let text = payload["text"] as? String else { return }
        let scrubbed = LogPrivacyRedactor.scrub(text)
        let line = "[web page \(level)] \(scrubbed)"
        if level == "error" || level == "uncaught" || level == "rejection" {
            Logger.warning(line, category: .screenManager)
        } else {
            Logger.info(line, category: .screenManager)
        }
    }
}

#else

extension HTMLWallpaperView {
    var consoleForwarderScript: String? {
        nil
    }

    func installConsoleForwarderMessageHandler() {}
}

#endif
