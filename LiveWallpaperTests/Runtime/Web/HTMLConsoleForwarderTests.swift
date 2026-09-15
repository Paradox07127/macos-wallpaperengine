import Foundation
import JavaScriptCore
@testable import LiveWallpaper
import Testing

/// JavaScriptCore has no `window.webkit`, no DOM events, no page `console` and no timers, so
/// all of them are stubbed and recorded here.
private func makeConsoleContext(budget: Int = 200) throws -> JSContext {
    let context = try #require(JSContext())
    context.evaluateScript(
        """
        var window = this;
        var hostMessages = [];
        var originalCalls = [];
        window.webkit = {
            messageHandlers: {
                lwConsole: {
                    postMessage: function (payload) { hostMessages.push(payload); }
                }
            }
        };
        var console = {
            log: function () { originalCalls.push('log'); },
            info: function () { originalCalls.push('info'); },
            warn: function () { originalCalls.push('warn'); },
            error: function () { originalCalls.push('error'); },
            debug: function () { originalCalls.push('debug'); }
        };
        var domListeners = {};
        window.addEventListener = function (type, handler) { domListeners[type] = handler; };
        function fire(type, event) { if (domListeners[type]) domListeners[type](event); }
        // The liveness probe schedules work; these stubs never fire it, which keeps the
        // forwarder's own assertions about console and DOM events independent of it.
        var pendingTimers = [];
        window.setTimeout = function (callback) { pendingTimers.push(callback); return pendingTimers.length; };
        window.requestAnimationFrame = function () { return 1; };
        var setTimeout = window.setTimeout;
        var requestAnimationFrame = window.requestAnimationFrame;
        """
    )
    context.evaluateScript(
        HTMLWallpaperRuntimeScript.consoleForwarder(
            messageName: HTMLWallpaperView.consoleMessageName,
            budget: budget
        )
    )
    return context
}

@Suite("HTML page console forwarder")
struct HTMLConsoleForwarderTests {
    @Test("A console.error reaches the host and still reaches the page's own console")
    func consoleErrorIsForwardedAndPassedThrough() throws {
        let context = try makeConsoleContext()

        context.evaluateScript("console.error('boom', 42);")

        #expect(context.evaluateScript("hostMessages.length")?.toInt32() == 1)
        #expect(context.evaluateScript("hostMessages[0].level")?.toString() == "error")
        #expect(context.evaluateScript("hostMessages[0].text")?.toString() == "boom 42")
        #expect(context.evaluateScript("originalCalls[0]")?.toString() == "error")
        #expect(context.exception == nil)
    }

    @Test("An uncaught page error is forwarded with its file and line")
    func uncaughtErrorIsForwarded() throws {
        let context = try makeConsoleContext()

        context.evaluateScript(
            "fire('error', { message: 'x is not defined', filename: 'js/main.js', lineno: 84 });"
        )

        #expect(context.evaluateScript("hostMessages[0].level")?.toString() == "uncaught")
        #expect(context.evaluateScript("hostMessages[0].text")?.toString() == "x is not defined @ js/main.js:84")
    }

    @Test("An unhandled promise rejection is forwarded")
    func unhandledRejectionIsForwarded() throws {
        let context = try makeConsoleContext()

        context.evaluateScript("fire('unhandledrejection', { reason: new Error('fetch failed') });")

        #expect(context.evaluateScript("hostMessages[0].level")?.toString() == "rejection")
        #expect(context.evaluateScript("hostMessages[0].text")?.toString().contains("fetch failed") == true)
    }

    @Test("A page erroring in its own loop cannot flood the log past the budget")
    func budgetStopsAFlood() throws {
        let context = try makeConsoleContext(budget: 3)

        context.evaluateScript("for (var i = 0; i < 50; i++) { console.warn('spin ' + i); }")

        #expect(context.evaluateScript("hostMessages.length")?.toInt32() == 3)
        #expect(context.evaluateScript("hostMessages[2].text")?.toString()
            == "spin 2 [further page messages suppressed]")
        // The page's own console keeps working after the host stops listening.
        #expect(context.evaluateScript("originalCalls.length")?.toInt32() == 50)
    }

    /// `JSON.stringify(new Error('x'))` is `{}` — an Error's own properties are non-enumerable,
    /// so the naive path drops exactly the message and location a frozen wallpaper is diagnosed by.
    @Test("An Error argument arrives with its message and location, not as an empty object")
    func errorArgumentKeepsMessageAndLocation() throws {
        let context = try makeConsoleContext()

        context.evaluateScript(
            """
            var err = new Error('shouldShow is not a function');
            err.stack = 'applyUserProperties@http://x/js/main.js:204:20';
            console.error('Loomscreen failed to apply Wallpaper Engine properties', err);
            """
        )

        let text = context.evaluateScript("hostMessages[0].text")?.toString() ?? ""
        #expect(text.contains("shouldShow is not a function"))
        #expect(text.contains("js/main.js:204"))
        #expect(!text.contains("{}"))
    }

    @Test("A circular argument is stringified instead of throwing")
    func circularArgumentDoesNotThrow() throws {
        let context = try makeConsoleContext()

        context.evaluateScript("var a = {}; a.self = a; console.log(a);")

        #expect(context.evaluateScript("hostMessages.length")?.toInt32() == 1)
        #expect(context.exception == nil)
    }
}
