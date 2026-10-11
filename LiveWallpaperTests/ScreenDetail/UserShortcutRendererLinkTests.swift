#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Metal
import Testing

@MainActor
@Suite("User shortcut renderer link")
struct UserShortcutRendererLinkTests {
    private typealias Entry = WPEUserShortcutScriptBridge.Entry

    private static func makeStore() -> UserShortcutBindingStore {
        UserShortcutBindingStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("UserShortcutRendererLinkTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("bindings.json", isDirectory: false))
    }

    private static func key(_ wallpaperID: String, _ propertyKey: String) -> UserShortcutBindingKey {
        UserShortcutBindingKey(wallpaperID: wallpaperID, propertyKey: propertyKey)
    }

    private static func makeIcons() throws -> WPEUserShortcutIconStore {
        try WPEUserShortcutIconStore(device: #require(MTLCreateSystemDefaultDevice()))
    }

    private static func hasIcon(_ icons: WPEUserShortcutIconStore, _ key: String) -> Bool {
        icons.substituting(nil, slot: 0, declarations: [0: key]) != nil
    }

    @Test("Attaching pushes the declared keys and the stored bindings of that wallpaper")
    func attachPushesDeclaredAndBound() throws {
        let store = Self.makeStore()
        try store.setWebsite("https://example.com/a", for: Self.key("w1", "open"))
        try store.setShortcut(name: "Lights", arguments: nil, for: Self.key("w2", "open"))
        let link = UserShortcutRendererLink(store: store)
        let bridge = WPEUserShortcutScriptBridge()

        try link.attach(bridge, icons: Self.makeIcons(), wallpaperID: "w1", declaredKeys: ["open", "run"])

        let snapshot = bridge.snapshot()
        #expect(snapshot.declared == ["open", "run"])
        #expect(snapshot.bound == ["open": Entry(commandType: "web", displayName: "example.com")])
    }

    @Test("Attaching gives bound keys an icon, unbound keys none, and clearing a binding drops its icon")
    func attachPushesIcons() throws {
        let store = Self.makeStore()
        try store.setWebsite("https://example.com/a", for: Self.key("w1", "open"))
        let link = UserShortcutRendererLink(store: store)
        let bridge = WPEUserShortcutScriptBridge()
        let icons = try Self.makeIcons()

        link.attach(bridge, icons: icons, wallpaperID: "w1", declaredKeys: ["open", "run"])

        #expect(Self.hasIcon(icons, "open"))
        #expect(!Self.hasIcon(icons, "run"))
        store.clear(Self.key("w1", "open"))
        #expect(!Self.hasIcon(icons, "open"), "a cleared binding must fall back to the author's texture")
    }

    @Test("A store change reaches every bridge of that wallpaper and no other")
    func storeChangeReachesSameWallpaperBridges() throws {
        let store = Self.makeStore()
        let link = UserShortcutRendererLink(store: store)
        let first = WPEUserShortcutScriptBridge()
        let second = WPEUserShortcutScriptBridge()
        let other = WPEUserShortcutScriptBridge()
        let icons = try Self.makeIcons()
        link.attach(first, icons: icons, wallpaperID: "w1", declaredKeys: ["run"])
        link.attach(second, icons: icons, wallpaperID: "w1", declaredKeys: ["run"])
        try link.attach(other, icons: Self.makeIcons(), wallpaperID: "w2", declaredKeys: ["run"])

        try store.setShortcut(name: "Lights", arguments: "on", for: Self.key("w1", "run"))

        let expected = ["run": Entry(commandType: "cmd", displayName: "Lights")]
        #expect(first.snapshot().bound == expected)
        #expect(second.snapshot().bound == expected)
        #expect(first.snapshot().declared == ["run"])
        #expect(other.snapshot().bound.isEmpty)
    }

    @Test("A released bridge is dropped on the next store change")
    func releasedBridgeIsPruned() throws {
        let store = Self.makeStore()
        let link = UserShortcutRendererLink(store: store)
        var bridge: WPEUserShortcutScriptBridge? = WPEUserShortcutScriptBridge()
        weak var released = bridge
        try link.attach(#require(bridge), icons: Self.makeIcons(), wallpaperID: "w1", declaredKeys: ["run"])
        #expect(link.registrationCount == 1)
        bridge = nil
        #expect(released == nil, "the link kept the bridge alive")

        try store.setWebsite("https://example.com", for: Self.key("w1", "run"))

        #expect(link.registrationCount == 0)
    }

    @Test("Declared keys are the usershortcut properties of the manifest")
    func declaredKeysReadOnlyUserShortcuts() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserShortcutRendererLinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let json = #"{"general":{"properties":{"launch":{"type":"usershortcut","text":"Launch","order":0},"speed":{"type":"slider","text":"Speed","value":1,"min":0,"max":2,"order":1}}}}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("project.json"))

        #expect(UserShortcutRendererLink.declaredKeys(manifestRoot: folder) == ["launch"])
        #expect(UserShortcutRendererLink.declaredKeys(manifestRoot: folder.appendingPathComponent("missing")).isEmpty)
    }

    @Test("A scene whose only property is a usershortcut still gets a settings schema")
    func userShortcutOnlySceneLoadsSchema() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserShortcutSchema-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("LiveWallpaper/wpe-cache/77")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let json = #"{"general":{"properties":{"launch":{"type":"usershortcut","text":"Launch","order":0}}}}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("project.json"))
        let descriptor = SceneDescriptor(workshopID: "77", cacheRelativePath: "wpe-cache/77", entryFile: "scene.json",
                                         capabilityTier: .imageOnly)
        defer { WPESceneProjectSchemaLoader.invalidateCache() }

        let outcome = await WPESceneProjectSchemaLoader.load(descriptor: descriptor, wpeOrigin: nil, applicationSupportRootURL: root)
        #expect(outcome.schema?.properties.map(\.key) == ["launch"])
    }

    @Test("The launcher runs the binding current when it executes, and nothing for a key cleared meanwhile", .timeLimit(.minutes(1)))
    func launcherExecutesCurrentBinding() async throws {
        let store = Self.makeStore()
        let link = UserShortcutRendererLink(store: store)
        let bridge = WPEUserShortcutScriptBridge()
        try store.setWebsite("https://old.example.com", for: Self.key("w1", "open"))
        try store.setShortcut(name: "Lights", arguments: nil, for: Self.key("w1", "run"))
        try store.setWebsite("https://gone.example.com", for: Self.key("w1", "gone"))
        try link.attach(bridge, icons: Self.makeIcons(), wallpaperID: "w1", declaredKeys: ["open", "run", "gone"])

        var executed: [UserShortcutBinding] = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            link.execute = { binding in
                executed.append(binding)
                if executed.count == 2 {
                    done.resume()
                }
            }
            #expect(bridge.requestLaunch("gone"))
            store.clear(Self.key("w1", "gone"))
            #expect(bridge.requestLaunch("open"))
            try? store.setWebsite("https://new.example.com", for: Self.key("w1", "open"))
            #expect(bridge.requestLaunch("run"))
        }

        let open = try #require(store.binding(for: Self.key("w1", "open")))
        let run = try #require(store.binding(for: Self.key("w1", "run")))
        #expect(open.target == "https://new.example.com")
        #expect(executed.count == 2)
        #expect(executed.contains(open) && executed.contains(run))
    }
}
#endif
