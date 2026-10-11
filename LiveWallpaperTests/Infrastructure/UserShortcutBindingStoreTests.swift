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

    private func writeRaw(_ json: String, to fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: fileURL)
    }

    private func entryJSON(_ propertyKey: String, kind: String = "web", revision: String) -> String {
        #"{"key":{"wallpaperID":"wp-1","propertyKey":"\#(propertyKey)"},"#
            + #""binding":{"kind":"\#(kind)","target":"https://example.com","displayName":"example.com","revision":\#(revision)}}"#
    }

    private func backups(besides fileURL: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: fileURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("bindings.corrupt-") && $0.pathExtension == "json" }
    }

    private func observeChanges(of store: UserShortcutBindingStore) -> (FailureRecorder, any NSObjectProtocol) {
        let posts = FailureRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: UserShortcutBindingStore.didChange, object: store, queue: nil
        ) { _ in
            MainActor.assumeIsolated { posts.record() }
        }
        return (posts, observer)
    }

    @Test func unreadableEntryIsDroppedAndOriginalIsBackedUpBeforeTheNextWrite() throws {
        let fileURL = makeFileURL()
        let original = #"{"revision":5,"entries":["#
            + [entryJSON("a", revision: "1"), entryJSON("b", kind: "telnet", revision: "2"), entryJSON("c", revision: "3")].joined(separator: ",")
            + "]}"
        try writeRaw(original, to: fileURL)
        let store = UserShortcutBindingStore(fileURL: fileURL)
        #expect(Set(store.bindings(forWallpaper: "wp-1").keys) == ["a", "c"], "one unknown entry discarded the readable ones")
        #expect(try backups(besides: fileURL).isEmpty, "loading alone moved the original file")

        try store.setShortcut(name: "Run", arguments: nil, for: key)
        #expect(Set(UserShortcutBindingStore(fileURL: fileURL).bindings(forWallpaper: "wp-1").keys) == ["a", "c", "open"])
        let backup = try #require(try backups(besides: fileURL).first, "the partly unreadable file was overwritten without a backup")
        #expect(try Data(contentsOf: backup) == Data(original.utf8))
    }

    @Test func overflowingRevisionsLoadAsCorruptEntries() throws {
        let fileURL = makeFileURL()
        let huge = String(UInt64.max)
        try writeRaw(#"{"revision":\#(huge),"entries":["# + entryJSON("a", revision: "3") + "," + entryJSON("b", revision: huge) + "]}", to: fileURL)
        let store = UserShortcutBindingStore(fileURL: fileURL)
        try #require(
            store.binding(for: UserShortcutBindingKey(wallpaperID: "wp-1", propertyKey: "b")) == nil,
            "an entry whose revision would overflow was loaded"
        )
        #expect(store.binding(for: UserShortcutBindingKey(wallpaperID: "wp-1", propertyKey: "a")) != nil)

        try store.setWebsite("https://example.net", for: key)
        let revision = try #require(store.binding(for: key)?.revision)
        #expect(revision > 3 && revision <= UInt64.max / 2)
        #expect(try !backups(besides: fileURL).isEmpty)
    }

    @Test func readFailureMakesTheStoreRefuseWrites() throws {
        let fileURL = makeFileURL()
        let original = #"{"revision":1,"entries":["# + entryJSON("a", revision: "1") + "]}"
        try writeRaw(original, to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path) }
        let store = UserShortcutBindingStore(fileURL: fileURL)
        let (posts, observer) = observeChanges(of: store)
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(try !store.setWebsite("https://example.com", for: key))
        #expect(store.binding(for: key) == nil, "a store that couldn't read its file kept an unsaved binding")
        #expect(posts.count == 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        #expect(try Data(contentsOf: fileURL) == Data(original.utf8), "an unreadable file was overwritten")
        #expect(try backups(besides: fileURL).isEmpty)
    }

    @Test func writeFailureLeavesMemoryAndRevisionUnchanged() throws {
        let fileURL = makeFileURL()
        let store = UserShortcutBindingStore(fileURL: fileURL)
        try store.setWebsite("https://example.com", for: key)
        let saved = try #require(store.binding(for: key))
        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: folder)
        try Data("blocks the store's folder".utf8).write(to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (posts, observer) = observeChanges(of: store)
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(try !store.setWebsite("https://example.org", for: key))
        #expect(!store.clear(key))
        #expect(store.binding(for: key) == saved, "an unsaved change stayed in memory")
        #expect(posts.count == 0, "a failed write announced a change")

        try FileManager.default.removeItem(at: folder)
        try store.setWebsite("https://example.org", for: key)
        #expect(store.binding(for: key)?.revision == saved.revision + 1, "failed writes consumed revisions")
    }

    @Test func deletingOneOfTwoEntriesSharingAnIDKeepsItsBindings() throws {
        let id = "usershortcut-shared-\(UUID().uuidString)"
        let shortcuts = UserShortcutBindingStore.shared
        defer { shortcuts.removeAll(forWallpaper: id) }
        try shortcuts.setWebsite("https://example.com", for: UserShortcutBindingKey(wallpaperID: id, propertyKey: "open"))
        let history = HistoryProbe(entries: [10, 20].map { seconds in
            WPEHistoryEntry(
                origin: WPEOrigin(
                    workshopID: id, title: "Fixture", originalType: .scene,
                    sourceFolderBookmark: Data(id.utf8), cacheRelativePath: nil, previewFileName: nil,
                    resourceLocation: .sourceFolder
                ),
                importedAt: Date(timeIntervalSince1970: seconds)
            )
        })
        let model = InstalledLibraryModel(dependencies: history.dependencies)

        model.performDelete(history.entries[0], services: history.services)
        #expect(history.entries.count == 1)
        #expect(shortcuts.bindings(forWallpaper: id).count == 1, "deleting a local copy cleared the bindings its Steam twin still uses")
        model.performDelete(history.entries[0], services: history.services)
        #expect(history.entries.isEmpty)
        #expect(shortcuts.bindings(forWallpaper: id).isEmpty, "deleting the last entry kept its bindings")
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
        let openFile: @MainActor (URL, [String]?, @escaping @Sendable (Bool) -> Void) -> Void = { url, arguments, completion in
            opened.append((url.resolvingSymlinksInPath().path, arguments))
            completion(true)
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

    @Test func executeReportsSynchronousFailureOnce() throws {
        let root = try makeTargetRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile("Notes.txt", in: root)
        let store = UserShortcutBindingStore(fileURL: makeFileURL())
        try store.setFile(file, arguments: nil, for: key)
        let binding = try #require(store.binding(for: key))
        try FileManager.default.removeItem(at: file)

        let failures = FailureRecorder()
        let missingOpened = UserShortcutExecutor.execute(binding, openFile: { _, _, _ in }, onFailure: { failures.record() })
        #expect(!missingOpened)
        #expect(failures.count == 1, "a deleted file target was not reported exactly once")

        let web = UserShortcutBinding(kind: .web, target: "https://example.com", arguments: nil, displayName: "example.com", revision: 1)
        let refusedOpened = UserShortcutExecutor.execute(web, open: { _ in false }, onFailure: { failures.record() })
        #expect(!refusedOpened)
        #expect(failures.count == 2, "a web open that returned false was not reported exactly once")
        let webOpened = UserShortcutExecutor.execute(web, open: { _ in true }, onFailure: { failures.record() })
        #expect(webOpened)
        #expect(failures.count == 2, "a successful web open was reported as a failure")
    }

    @Test(.timeLimit(.minutes(1))) func executeReportsAsynchronousOpenFailureOnMainActor() async throws {
        let root = try makeTargetRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile("Notes.txt", in: root)
        let store = UserShortcutBindingStore(fileURL: makeFileURL())
        try store.setFile(file, arguments: nil, for: key)
        let binding = try #require(store.binding(for: key))

        var completions: [@Sendable (Bool) -> Void] = []
        let openFile: @MainActor (URL, [String]?, @escaping @Sendable (Bool) -> Void) -> Void = { _, _, completion in
            completions.append(completion)
        }
        let failures = FailureRecorder()
        let firstStarted = UserShortcutExecutor.execute(binding, openFile: openFile, onFailure: { failures.record() })
        let secondStarted = UserShortcutExecutor.execute(binding, openFile: openFile, onFailure: { failures.record() })
        #expect(firstStarted && secondStarted)
        try #require(completions.count == 2)

        let succeed = completions[0]
        let fail = completions[1]
        await Task.detached { succeed(true) }.value
        await Task.detached { fail(false) }.value
        // Main-actor jobs run in enqueue order, so both completions' hops have run once this one does.
        await Task { @MainActor in }.value
        #expect(failures.count == 1, "an asynchronous open result was misreported")
        #expect(failures.offMainCalls == 0)
    }

    @Test func dropTargetClassifiesFilesAppsAndFolders() throws {
        let root = try makeTargetRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile("Notes.txt", in: root)
        let app = try makeApp("Foo.app", in: root)
        let folder = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folderWithoutSlash = URL(filePath: folder.path(percentEncoded: false), directoryHint: .notDirectory)

        #expect(UserShortcutBindingRow.dropTarget(for: file) == .file(asksForArguments: false))
        #expect(UserShortcutBindingRow.dropTarget(for: app) == .file(asksForArguments: true), "an .app package was treated as a folder")
        #expect(UserShortcutBindingRow.dropTarget(for: folder) == .directory)
        #expect(UserShortcutBindingRow.dropTarget(for: folderWithoutSlash) == .directory)
        let web = try #require(URL(string: "https://example.com"))
        #expect(UserShortcutBindingRow.dropTarget(for: web) == nil)
    }

    @Test func droppedItemsBindTheFirstURL() throws {
        let root = try makeTargetRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile("Notes.txt", in: root)
        let app = try makeApp("Foo.app", in: root)
        let folder = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = UserShortcutBindingStore(fileURL: makeFileURL())

        #expect(try UserShortcutBindingRow.bindDropped([file], to: key, in: store) == .file(asksForArguments: false))
        #expect(store.binding(for: key)?.kind == .file)
        #expect(store.binding(for: key)?.target == "Notes.txt")

        #expect(try UserShortcutBindingRow.bindDropped([folder, file], to: key, in: store) == .directory)
        #expect(store.binding(for: key)?.kind == .directory)
        #expect(store.binding(for: key)?.target == "Projects")

        #expect(try UserShortcutBindingRow.bindDropped([app], to: key, in: store) == .file(asksForArguments: true))
        let appBinding = try #require(store.binding(for: key))
        #expect(appBinding.isApplication)

        let web = try #require(URL(string: "https://example.com"))
        #expect(try UserShortcutBindingRow.bindDropped([web, file], to: key, in: store) == nil)
        #expect(try UserShortcutBindingRow.bindDropped([], to: key, in: store) == nil)
        #expect(store.binding(for: key) == appBinding, "a rejected drop replaced the stored binding")
    }
}

@MainActor
private final class HistoryProbe {
    var entries: [WPEHistoryEntry]

    init(entries: [WPEHistoryEntry]) {
        self.entries = entries
    }

    var dependencies: InstalledLibraryModel.Dependencies {
        InstalledLibraryModel.Dependencies(
            loadEntries: { [weak self] in self?.entries ?? [] },
            loadRemoteUpdateEpochs: { [:] },
            saveRemoteUpdateEpochs: { _ in },
            loadLastUpdateCheckEpoch: { 0 },
            saveLastUpdateCheckEpoch: { _ in },
            makeMetadataService: { SteamWorkshopMetadataService() },
            now: { .distantPast },
            prefetchPreviewURLs: { _ in }
        )
    }

    var services: InstalledLibraryModel.DeleteServices {
        InstalledLibraryModel.DeleteServices(
            containsBookmark: { _ in false },
            removeBookmarks: { _ in },
            removeImportIfMatching: { [weak self] identity in
                guard let self, let index = entries.firstIndex(where: { WorkshopInstalledEntryIdentity($0) == identity }) else { return false }
                entries.remove(at: index)
                return true
            },
            isMutating: { _ in false },
            deleteSharedRepositoryItem: { _ in nil }
        )
    }
}

@MainActor
private final class FailureRecorder {
    private(set) var count = 0
    private(set) var offMainCalls = 0

    func record() {
        count += 1
        if !Thread.isMainThread {
            offMainCalls += 1
        }
    }
}
#endif
