#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
struct UserShortcutBindingStoreTests {
    private let key = UserShortcutBindingKey(wallpaperID: "wp-1", propertyKey: "open")

    private func makeFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("UserShortcutBindingStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("bindings.json", isDirectory: false)
    }

    @Test func setWebsiteAcceptsHTTPSAndRejectsUnsafeInputWithoutChangingStore() throws {
        let store = UserShortcutBindingStore(fileURL: makeFileURL())
        try store.setWebsite("  https://example.com/a?b=1 ", for: key)
        let accepted = try #require(store.binding(for: key))
        #expect(accepted.kind == .web)
        #expect(accepted.target == "https://example.com/a?b=1")
        #expect(accepted.displayName == "example.com")

        let rejected: [(String, UserShortcutValidationError)] = [
            ("javascript:alert(1)", .unsupportedScheme),
            ("file:///etc/passwd", .unsupportedScheme),
            ("ftp://x", .unsupportedScheme),
            ("https://user:pw@example.com", .credentialsInURL),
            ("", .empty),
            ("https://example.com/" + String(repeating: "a", count: 2100), .tooLong),
        ]
        for (input, error) in rejected {
            #expect(throws: error) { try store.setWebsite(input, for: key) }
            #expect(store.binding(for: key) == accepted, "a rejected URL replaced the stored binding")
        }
    }

    @Test func setShortcutValidatesNameAndArguments() throws {
        let store = UserShortcutBindingStore(fileURL: makeFileURL())
        #expect(throws: UserShortcutValidationError.empty) { try store.setShortcut(name: "  ", arguments: nil, for: key) }
        #expect(throws: UserShortcutValidationError.tooLong) {
            try store.setShortcut(name: String(repeating: "n", count: 256), arguments: nil, for: key)
        }
        #expect(throws: UserShortcutValidationError.controlCharacters) { try store.setShortcut(name: "a\u{0}b", arguments: nil, for: key) }
        #expect(throws: UserShortcutValidationError.controlCharacters) { try store.setShortcut(name: "a\tb", arguments: nil, for: key) }
        #expect(throws: UserShortcutValidationError.controlCharacters) { try store.setShortcut(name: "ok", arguments: "a\u{7}", for: key) }
        #expect(throws: UserShortcutValidationError.tooLong) {
            try store.setShortcut(name: "ok", arguments: String(repeating: "x", count: 1025), for: key)
        }
        #expect(store.binding(for: key) == nil, "a rejected shortcut was stored")

        try store.setShortcut(name: " Make Note ", arguments: "line1\nline2", for: key)
        let binding = try #require(store.binding(for: key))
        #expect(binding.kind == .cmd)
        #expect(binding.target == "Make Note")
        #expect(binding.displayName == "Make Note")
        #expect(binding.arguments == "line1\nline2")

        try store.setShortcut(name: "Make Note", arguments: "   ", for: key)
        #expect(store.binding(for: key)?.arguments == nil, "blank arguments were kept")
    }

    @Test func shortcutLaunchURLCannotBeInjected() throws {
        let name = "A&B=C+D #?"
        let text = "x&input=clipboard"
        let binding = UserShortcutBinding(kind: .cmd, target: name, arguments: text, displayName: name, revision: 1)
        let url = try #require(UserShortcutExecutor.launchURL(for: binding))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "shortcuts")
        #expect(components.host == "run-shortcut")
        #expect(components.queryItems == [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: text),
        ])

        let bare = UserShortcutBinding(kind: .cmd, target: "Ünïcode name", arguments: nil, displayName: "", revision: 1)
        let bareURL = try #require(UserShortcutExecutor.launchURL(for: bare))
        #expect(URLComponents(url: bareURL, resolvingAgainstBaseURL: false)?.queryItems == [
            URLQueryItem(name: "name", value: "Ünïcode name"),
        ])
    }

    @Test func bindingsPersistAndRevisionIsMonotonic() throws {
        let fileURL = makeFileURL()
        let store = UserShortcutBindingStore(fileURL: fileURL)
        let other = UserShortcutBindingKey(wallpaperID: "wp-1", propertyKey: "second")
        let foreign = UserShortcutBindingKey(wallpaperID: "wp-2", propertyKey: "open")
        try store.setWebsite("https://example.com", for: key)
        let first = try #require(store.binding(for: key)?.revision)
        try store.setShortcut(name: "Run", arguments: nil, for: other)
        let second = try #require(store.binding(for: other)?.revision)
        try store.setWebsite("https://example.org", for: foreign)
        let third = try #require(store.binding(for: foreign)?.revision)
        #expect(first < second && second < third)

        let reloaded = UserShortcutBindingStore(fileURL: fileURL)
        #expect(reloaded.binding(for: key) == store.binding(for: key))
        #expect(Set(reloaded.bindings(forWallpaper: "wp-1").keys) == ["open", "second"])

        reloaded.clear(key)
        #expect(reloaded.binding(for: key) == nil)
        reloaded.removeAll(forWallpaper: "wp-1")
        #expect(reloaded.bindings(forWallpaper: "wp-1").isEmpty)
        try reloaded.setWebsite("https://example.net", for: key)
        #expect(try #require(reloaded.binding(for: key)?.revision) > third)

        let afterClear = UserShortcutBindingStore(fileURL: fileURL)
        #expect(afterClear.binding(for: other) == nil)
        #expect(afterClear.binding(for: foreign)?.target == "https://example.org")
    }

    @Test func corruptFileLoadsEmpty() throws {
        let fileURL = makeFileURL()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        let store = UserShortcutBindingStore(fileURL: fileURL)
        #expect(store.bindings(forWallpaper: "wp-1").isEmpty)
        #expect(try Data(contentsOf: fileURL) == Data("not json".utf8), "a corrupt file was rewritten on load")
    }

    @Test func backupExportNeverCarriesBindings() throws {
        let marker = "usershortcut-marker-\(UUID().uuidString)"
        let store = UserShortcutBindingStore(fileURL: ConfigurationDirectory().url(for: .userShortcutBindings))
        let markerKey = UserShortcutBindingKey(wallpaperID: marker, propertyKey: marker)
        try store.setShortcut(name: marker, arguments: marker, for: markerKey)
        defer { store.removeAll(forWallpaper: marker) }

        let data = try ConfigurationPorter.encode(ConfigurationPorter.currentBundle())
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains(marker), "the backup export carries a user shortcut binding")
    }

    @Test func executeOpensOnlyWebAndShortcutBindings() {
        var opened: [URL] = []
        let record: (URL) -> Bool = { opened.append($0); return true }

        let web = UserShortcutBinding(kind: .web, target: "https://example.com/x", arguments: nil, displayName: "example.com", revision: 1)
        #expect(UserShortcutExecutor.execute(web, open: record))
        let cmd = UserShortcutBinding(kind: .cmd, target: "Run Me", arguments: nil, displayName: "Run Me", revision: 2)
        #expect(UserShortcutExecutor.execute(cmd, open: record))
        #expect(opened.map(\.absoluteString) == [
            "https://example.com/x",
            "shortcuts://run-shortcut?name=Run%20Me",
        ])

        for kind in [UserShortcutKind.file, .directory] {
            let binding = UserShortcutBinding(kind: kind, target: "/tmp/x", arguments: nil, displayName: "x", revision: 3)
            #expect(!UserShortcutExecutor.execute(binding, open: record))
        }
        #expect(opened.count == 2, "a file or directory binding reached the opener")
    }

    private func makeTargetRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserShortcutTargets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFile(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: false)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func makeApp(_ name: String, in root: URL) throws -> URL {
        let app = root.appendingPathComponent(name, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    @Test func setFileStoresBookmarkAndDropsArgumentsForPlainFiles() throws {
        let root = try makeTargetRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile("Notes.txt", in: root)
        let fileURL = makeFileURL()
        let store = UserShortcutBindingStore(fileURL: fileURL)

        try store.setFile(file, arguments: "-v", for: key)
        let binding = try #require(store.binding(for: key))
        #expect(binding.kind == .file)
        #expect(binding.bookmark != nil)
        #expect(binding.target == "Notes.txt")
        #expect(binding.displayName == "Notes.txt")
        #expect(binding.arguments == nil, "a plain file kept launch arguments")
        #expect(UserShortcutBindingStore(fileURL: fileURL).binding(for: key) == binding)
    }

    @Test func setFileKeepsValidatedArgumentsOnlyForApps() throws {
        let root = try makeTargetRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp("Foo.APP", in: root)
        let store = UserShortcutBindingStore(fileURL: makeFileURL())

        try store.setFile(app, arguments: #"--name "My File""#, for: key)
        let binding = try #require(store.binding(for: key))
        #expect(binding.kind == .file)
        #expect(binding.arguments == #"--name "My File""#)
        #expect(binding.displayName == "Foo")
        #expect(throws: UserShortcutValidationError.controlCharacters) { try store.setFile(app, arguments: "a\u{7}", for: key) }
        #expect(store.binding(for: key) == binding, "a rejected argument string replaced the stored binding")
    }

    @Test func setDirectoryStoresDirectoryBinding() throws {
        let root = try makeTargetRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = UserShortcutBindingStore(fileURL: makeFileURL())

        try store.setDirectory(folder, for: key)
        let binding = try #require(store.binding(for: key))
        #expect(binding.kind == .directory)
        #expect(binding.bookmark != nil)
        #expect(binding.displayName == "Projects")
    }

    @Test func legacyFileWithoutBookmarkLoads() throws {
        let fileURL = makeFileURL()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = #"{"revision":3,"entries":[{"key":{"wallpaperID":"wp-1","propertyKey":"open"},"binding":{"kind":"web","target":"https://example.com","displayName":"example.com","revision":3}}]}"#
        try Data(legacy.utf8).write(to: fileURL)
        let binding = try #require(UserShortcutBindingStore(fileURL: fileURL).binding(for: key))
        #expect(binding.target == "https://example.com")
        #expect(binding.bookmark == nil)
    }

    @Test func replaceBookmarkOnlySwapsMatchingOriginal() throws {
        let root = try makeTargetRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UserShortcutBindingStore(fileURL: makeFileURL())
        try store.setDirectory(root, for: key)
        let original = try #require(store.binding(for: key)?.bookmark)

        store.replaceBookmark(Data("other".utf8), with: Data("late".utf8), for: key)
        #expect(store.binding(for: key)?.bookmark == original, "a refresh of a replaced bookmark overwrote the current one")
        store.replaceBookmark(original, with: Data("fresh".utf8), for: key)
        #expect(store.binding(for: key)?.bookmark == Data("fresh".utf8))
    }

    @Test func splitArgumentsHonorsQuotes() {
        #expect(UserShortcutExecutor.splitArguments(nil) == [])
        #expect(UserShortcutExecutor.splitArguments("") == [])
        #expect(UserShortcutExecutor.splitArguments("-a b") == ["-a", "b"])
        #expect(UserShortcutExecutor.splitArguments(#"--name "My File" -v"#) == ["--name", "My File", "-v"])
        #expect(UserShortcutExecutor.splitArguments("  -a \t\n  b  ") == ["-a", "b"])
    }

    @Test func executeOpensResolvedFilesAndAppsAndRejectsMissingTargets() throws {
        let root = try makeTargetRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile("Notes.txt", in: root)
        let app = try makeApp("Foo.app", in: root)
        let store = UserShortcutBindingStore(fileURL: makeFileURL())
        let appKey = UserShortcutBindingKey(wallpaperID: "wp-1", propertyKey: "app")
        try store.setFile(file, arguments: nil, for: key)
        try store.setFile(app, arguments: #"--name "My File""#, for: appKey)

        var opened: [(path: String, arguments: [String]?)] = []
        var completions = 0
        let openFile: @MainActor (URL, [String]?, @escaping @Sendable () -> Void) -> Void = { url, arguments, completion in
            opened.append((url.resolvingSymlinksInPath().path, arguments))
            completion()
            completions += 1
        }
        let fileBinding = try #require(store.binding(for: key))
        let appBinding = try #require(store.binding(for: appKey))
        #expect(UserShortcutExecutor.execute(fileBinding, openFile: openFile))
        #expect(UserShortcutExecutor.execute(appBinding, openFile: openFile))
        #expect(opened.count == 2)
        #expect(opened.first?.path == file.resolvingSymlinksInPath().path)
        #expect(opened.first?.arguments == nil)
        #expect(opened.last?.path == app.resolvingSymlinksInPath().path)
        #expect(opened.last?.arguments == ["--name", "My File"])
        #expect(completions == 2)
        #expect(UserShortcutExecutor.isResolvable(fileBinding))

        try FileManager.default.removeItem(at: file)
        #expect(!UserShortcutExecutor.execute(fileBinding, openFile: openFile))
        #expect(opened.count == 2, "a binding to a deleted file reached the opener")
        #expect(!UserShortcutExecutor.isResolvable(fileBinding))
        #expect(UserShortcutExecutor.isResolvable(UserShortcutBinding(kind: .web, target: "https://example.com", arguments: nil, displayName: "", revision: 1)))
    }

    @Test func launchURLRejectsEditedNonWebScheme() {
        for target in ["javascript:alert(1)", "file:///etc/passwd", "shortcuts://run-shortcut?name=x"] {
            let binding = UserShortcutBinding(kind: .web, target: target, arguments: nil, displayName: "x", revision: 1)
            #expect(UserShortcutExecutor.launchURL(for: binding) == nil)
        }
    }
}
#endif
