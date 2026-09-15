import Foundation
import JavaScriptCore
@testable import LiveWallpaper
import Testing

@Suite("Wallpaper Engine web property bridge")
struct WallpaperEngineWebPropertyBridgeTests {
    @Test("Builds an applyUserProperties bootstrap from project.json defaults")
    func buildsBootstrapFromProjectDefaults() throws {
        let folder = try makeProjectFolder(manifest: """
        {
          "file": "index.html",
          "type": "Web",
          "general": {
            "properties": {
              "introanimation": { "type": "bool", "text": "Intro Animation", "value": true },
              "modelresolution": { "type": "combo", "text": "Model Resolution", "value": "8k" },
              "bgmvolume": { "type": "slider", "text": "BGM Volume", "value": 20 }
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: folder) }

        let schema = try #require(WallpaperEngineWebPropertyBridge.parseSchema(forFolder: folder))
        let script = try #require(WallpaperEngineWebPropertyBridge.bootstrapScript(schema: schema))

        #expect(script.contains("wallpaperPropertyListener"))
        #expect(script.contains("applyUserProperties"))
        #expect(script.contains("\"introanimation\":{\"value\":true}"))
        #expect(script.contains("\"modelresolution\":{\"value\":\"8k\"}"))
        #expect(script.contains("\"bgmvolume\":{\"value\":20}"))
        #expect(!script.contains("Intro Animation"))
    }

    @Test("Returns nil when a folder has no Wallpaper Engine property defaults")
    func nilWithoutPropertyDefaults() throws {
        let folder = try makeProjectFolder(manifest: """
        {
          "file": "index.html",
          "type": "Web"
        }
        """)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(WallpaperEngineWebPropertyBridge.parseSchema(forFolder: folder) == nil)
    }

    @Test("Bootstrap script installs a defineProperty hook on wallpaperPropertyListener")
    func bootstrapInstallsDefinePropertyHook() throws {
        let folder = try makeProjectFolder(manifest: """
        {
          "file": "index.html",
          "type": "Web",
          "general": {
            "properties": {
              "color": { "type": "color", "text": "Color", "value": "1 0 0" }
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: folder) }

        let schema = try #require(WallpaperEngineWebPropertyBridge.parseSchema(forFolder: folder))
        let script = try #require(WallpaperEngineWebPropertyBridge.bootstrapScript(schema: schema))

        #expect(script.contains("Object.defineProperty(window, 'wallpaperPropertyListener'"))
        #expect(script.contains("set:"))
        #expect(script.contains("requestAnimationFrame"))
    }

    @Test("Hot apply only sends Wallpaper Engine properties whose effective value changed")
    func hotApplyOnlySendsChangedProperties() throws {
        let schema = try WallpaperEngineProjectPropertySchema.parse(data: Data("""
        {
          "file": "index.html",
          "type": "Web",
          "general": {
            "properties": {
              "dialogx": { "type": "slider", "text": "Dialog X", "value": 33, "min": 0, "max": 100, "step": 0.1 },
              "dialogy": { "type": "slider", "text": "Dialog Y", "value": 53, "min": 0, "max": 100, "step": 0.1 },
              "modelresolution": { "type": "combo", "text": "Model Resolution", "value": "8k" }
            }
          }
        }
        """.utf8))

        let script = try #require(WallpaperEngineWebPropertyBridge.applyScript(
            schema: schema,
            previousOverrides: ["dialogx": .number(33)],
            overrides: ["dialogx": .number(34)]
        ))

        #expect(script.contains("\"dialogx\":{\"value\":34}"))
        #expect(!script.contains("dialogy"))
        #expect(!script.contains("modelresolution"))
    }

    @Test("Master audio maps to Wallpaper Engine volume sliders at runtime")
    func masterAudioMapsToWallpaperEngineVolumeSliders() throws {
        let schema = try WallpaperEngineProjectPropertySchema.parse(data: Data("""
        {
          "file": "index.html",
          "type": "Web",
          "general": {
            "properties": {
              "music": { "type": "bool", "text": "Music", "value": true },
              "bgmvolume": { "type": "slider", "text": "BGM Volume", "value": 20, "min": 0, "max": 100, "step": 1 },
              "dialogx": { "type": "slider", "text": "Dialog X", "value": 33, "min": 0, "max": 100 }
            }
          }
        }
        """.utf8))

        let script = try #require(WallpaperEngineWebPropertyBridge.audioControlScript(
            schema: schema,
            projectOverrides: ["bgmvolume": .number(80)],
            volume: 0.35,
            muted: false
        ))

        #expect(script.contains("applyUserProperties"))
        #expect(script.contains("\"bgmvolume\":{\"value\":28}"))
        #expect(!script.contains("\"music\""))
        #expect(!script.contains("\"dialogx\""))
    }

    @Test("Master audio restores project volume when returning to full volume")
    func masterAudioRestoresProjectVolumeAtFullVolume() throws {
        let schema = try WallpaperEngineProjectPropertySchema.parse(data: Data("""
        {
          "file": "index.html",
          "type": "Web",
          "general": {
            "properties": {
              "bgmvolume": { "type": "slider", "text": "BGM Volume", "value": 20, "min": 0, "max": 100, "step": 1 }
            }
          }
        }
        """.utf8))

        let script = try #require(WallpaperEngineWebPropertyBridge.audioControlScript(
            schema: schema,
            projectOverrides: ["bgmvolume": .number(80)],
            volume: 1,
            muted: false
        ))

        #expect(script.contains("\"bgmvolume\":{\"value\":80}"))
    }

    @Test("Bootstrap audio overrides only when master audio is active")
    func bootstrapAudioOverridesOnlyWhenMasterAudioIsActive() throws {
        let schema = try WallpaperEngineProjectPropertySchema.parse(data: Data("""
        {
          "file": "index.html",
          "type": "Web",
          "general": {
            "properties": {
              "bgmvolume": { "type": "slider", "text": "BGM Volume", "value": 20, "min": 0, "max": 100, "step": 1 }
            }
          }
        }
        """.utf8))

        #expect(WallpaperEngineWebPropertyBridge.audioBootstrapOverrides(
            schema: schema,
            projectOverrides: ["bgmvolume": .number(80)],
            volume: 1,
            muted: false
        ).isEmpty)

        #expect(WallpaperEngineWebPropertyBridge.audioBootstrapOverrides(
            schema: schema,
            projectOverrides: ["bgmvolume": .number(80)],
            volume: 0.35,
            muted: false
        )["bgmvolume"] == .number(28))

        #expect(WallpaperEngineWebPropertyBridge.audioBootstrapOverrides(
            schema: schema,
            projectOverrides: [:],
            volume: 0.35,
            muted: false
        )["bgmvolume"] == .number(7))
    }

    @Test("Value-less file, directory and textinput rows arrive as empty strings")
    func valuelessEditableRowsArriveAsEmptyStrings() throws {
        let schema = try WallpaperEngineProjectPropertySchema.parse(data: Data("""
        {
          "file": "index.html",
          "type": "Web",
          "general": {
            "properties": {
              "image": { "type": "file", "text": "Custom Image", "fileType": "image" },
              "customdirectory": { "type": "directory", "text": "Folder", "mode": "fetchall" },
              "cityname": { "type": "textinput", "text": "City" },
              "helptext": { "type": "text", "text": "Read me" },
              "DefaultWallpaper": { "type": "combo", "text": "Wallpaper", "value": 1 }
            }
          }
        }
        """.utf8))

        let script = try #require(WallpaperEngineWebPropertyBridge.bootstrapScript(schema: schema))

        #expect(script.contains("\"image\":{\"value\":\"\"}"))
        #expect(script.contains("\"customdirectory\":{\"value\":\"\"}"))
        #expect(script.contains("\"cityname\":{\"value\":\"\"}"))
        #expect(script.contains("\"DefaultWallpaper\":{\"value\":1}"))
        // Decorative rows carry no user value; delivering one would flip `if (properties.x)` branches.
        #expect(!script.contains("\"helptext\""))
    }

    @Test("A still-unset row is not resent as a change on hot apply")
    func valuelessRowIsNotResentOnHotApply() throws {
        let schema = try WallpaperEngineProjectPropertySchema.parse(data: Data("""
        {
          "file": "index.html",
          "type": "Web",
          "general": {
            "properties": {
              "image": { "type": "file", "text": "Custom Image", "fileType": "image" },
              "dialogx": { "type": "slider", "text": "Dialog X", "value": 33, "min": 0, "max": 100 }
            }
          }
        }
        """.utf8))

        let script = try #require(WallpaperEngineWebPropertyBridge.applyScript(
            schema: schema,
            previousOverrides: ["dialogx": .number(33)],
            overrides: ["dialogx": .number(34)]
        ))

        #expect(!script.contains("\"image\""))
    }

    @Test("Clearing a picked file sends an empty string, not a dropped key")
    func clearingAPickedFileSendsAnEmptyString() throws {
        let schema = try WallpaperEngineProjectPropertySchema.parse(data: Data("""
        {
          "file": "index.html",
          "type": "Web",
          "general": {
            "properties": {
              "image": { "type": "file", "text": "Custom Image", "fileType": "image" }
            }
          }
        }
        """.utf8))

        let script = try #require(WallpaperEngineWebPropertyBridge.applyScript(
            schema: schema,
            previousOverrides: ["image": .string("/Users/me/pic.jpg")],
            overrides: [:]
        ))

        #expect(script.contains("\"image\":{\"value\":\"\"}"))
    }

    /// Wallpaper Engine delivers the cold-start properties once the wallpaper is ready. Pages that
    /// build their GL state in a `load` handler (884307090's sakura does) throw if the listener
    /// runs at documentEnd, and everything after the throw in their listener never applies.
    @Test("Cold-start properties wait for window load")
    func coldStartPropertiesWaitForLoad() throws {
        let context = try makeBootstrapContext(readyState: "loading")

        context.evaluateScript(bootstrapScriptForOneBoolProperty())
        #expect(context.evaluateScript("deliveries.length")?.toInt32() == 0)

        context.evaluateScript("fireLoad();")
        #expect(context.evaluateScript("deliveries.length")?.toInt32() == 1)
        #expect(context.evaluateScript("deliveries[0].introanimation.value")?.toBool() == true)
        #expect(context.exception == nil)
    }

    @Test("A document that is already complete is delivered to at once")
    func alreadyCompleteDocumentIsDeliveredImmediately() throws {
        let context = try makeBootstrapContext(readyState: "complete")

        context.evaluateScript(bootstrapScriptForOneBoolProperty())

        #expect(context.evaluateScript("deliveries.length")?.toInt32() == 1)
        #expect(context.exception == nil)
    }

    /// A single hanging subresource keeps `load` from ever firing. Before delivery waited for
    /// load it always arrived at documentEnd, so the wait needs a bound or the wallpaper is
    /// permanently unconfigured.
    @Test("A document that never finishes loading is still delivered to, once")
    func hangingDocumentIsStillDeliveredToOnce() throws {
        let context = try makeBootstrapContext(readyState: "loading")

        context.evaluateScript(bootstrapScriptForOneBoolProperty())
        #expect(context.evaluateScript("deliveries.length")?.toInt32() == 0)

        context.evaluateScript("fireTimeouts();")
        #expect(context.evaluateScript("deliveries.length")?.toInt32() == 1)

        // A late `load` must not deliver a second time.
        context.evaluateScript("fireLoad();")
        #expect(context.evaluateScript("deliveries.length")?.toInt32() == 1)
        #expect(context.exception == nil)
    }

    /// The hook has to exist before `load`, or a page that assigns its listener during a hang is
    /// invisible to every later delivery attempt.
    @Test("A listener assigned before load is captured and delivered to at load")
    func listenerAssignedBeforeLoadIsCaptured() throws {
        let context = try makeBootstrapContext(readyState: "loading")
        context.evaluateScript("window.wallpaperPropertyListener = undefined;")

        context.evaluateScript(bootstrapScriptForOneBoolProperty())
        context.evaluateScript("""
        window.wallpaperPropertyListener = {
            applyUserProperties: function (p) { deliveries.push(p); }
        };
        """)
        #expect(context.evaluateScript("deliveries.length")?.toInt32() == 0)

        context.evaluateScript("fireLoad();")
        #expect(context.evaluateScript("deliveries.length")?.toInt32() == 1)
        #expect(context.exception == nil)
    }

    private func bootstrapScriptForOneBoolProperty() -> String {
        let schema = try? WallpaperEngineProjectPropertySchema.parse(data: Data("""
        {
          "general": { "properties": { "introanimation": { "type": "bool", "value": true } } }
        }
        """.utf8))
        return schema.flatMap { WallpaperEngineWebPropertyBridge.bootstrapScript(schema: $0) } ?? ""
    }

    private func makeBootstrapContext(readyState: String) throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var window = this;
        var deliveries = [];
        var loadHandlers = [];
        var document = { readyState: '\(readyState)' };
        window.addEventListener = function (type, handler) {
            if (type === 'load') loadHandlers.push(handler);
        };
        window.requestAnimationFrame = function () { return 1; };
        var pendingTimeouts = [];
        window.setTimeout = function (callback) { pendingTimeouts.push(callback); return pendingTimeouts.length; };
        function fireTimeouts() {
            var due = pendingTimeouts.slice();
            pendingTimeouts = [];
            for (var i = 0; i < due.length; i++) due[i]();
        }
        function fireLoad() {
            document.readyState = 'complete';
            var handlers = loadHandlers.slice();
            for (var i = 0; i < handlers.length; i++) handlers[i]();
        }
        window.wallpaperPropertyListener = {
            applyUserProperties: function (p) { deliveries.push(p); }
        };
        """)
        return context
    }

    private func makeProjectFolder(manifest: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEWebPropertyBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifest.data(using: .utf8)?.write(to: folder.appendingPathComponent("project.json"))
        return folder
    }
}
