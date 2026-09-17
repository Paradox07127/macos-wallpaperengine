#if DEBUG
import Darwin
import Foundation
import LiveWallpaperCore

/// Socket lives at <container>/tmp/ because Application Support is 115 bytes, over sockaddr_un.sun_path's 104.
@MainActor
final class QAControlPlane {
    static let shared = QAControlPlane()

    static var socketPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("tmp/loomscreen-qa.sock")
    }

    private(set) weak var screenManager: ScreenManager?
    private var listenerFD: Int32 = -1
    /// The socket we bound, so shutdown never unlinks a path another instance took over.
    private var boundInode: ino_t?
    private var lockFD: Int32 = -1
    /// Set on shutdown so a request that was already queued cannot commit into a dying app.
    private var isStopped = false
    private let queue = DispatchQueue(label: "com.loomscreen.qa-control-plane")
    /// One worker per connection: serial serving would let a silent client hold everyone else.
    private let workers = DispatchQueue(label: "com.loomscreen.qa-control-plane.worker", attributes: .concurrent)

    private init() {}

    static func startIfEnabled(screenManager: ScreenManager) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        guard UserDefaults.standard.bool(forKey: "LoomscreenQAControlPlane") else { return }
        shared.start(screenManager: screenManager)
    }

    private func start(screenManager: ScreenManager) {
        guard listenerFD < 0 else { return }
        self.screenManager = screenManager
        let path = Self.socketPath
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        // A connect-probe alone leaves a window between looks-stale and bind; flock for process life closes it.
        guard let lock = Self.acquireLock(at: Self.lockPath) else {
            Logger.notice(
                "[QA] another instance already holds the control plane; this one will not open it",
                category: .lifecycle
            )
            return
        }
        lockFD = lock
        // SO_NOSIGPIPE on the accepted fd would not stop SIGPIPE; ignore it process-wide so write reports EPIPE.
        signal(SIGPIPE, SIG_IGN)
        if FileManager.default.fileExists(atPath: path) {
            Logger.notice("[QA] removing a stale control-plane socket at \(path)", category: .lifecycle)
            unlink(path)
        }
        guard let fd = Self.makeListener(at: path) else {
            Logger.error("[QA] control plane could not listen at \(path)", category: .lifecycle)
            close(lock)
            lockFD = -1
            return
        }
        listenerFD = fd
        boundInode = Self.inode(of: path)
        Logger.notice(
            "[QA] control plane listening at \(path) (pid \(ProcessInfo.processInfo.processIdentifier))",
            category: .lifecycle
        )
        let handle: @Sendable (String) -> String = { line in Self.respondOnMain(to: line) }
        let workers = workers
        queue.async { Self.acceptLoop(listener: fd, workers: workers, handle: handle) }
    }

    /// DispatchQueue.main.sync + assumeIsolated traps: the isolation check runs on the socket thread. Hop and block the socket thread (never main) until the answer returns.
    private nonisolated static func respondOnMain(to line: String) -> String {
        // Written once on the main actor before `signal()`, read once after `wait()`:
        // the semaphore is the happens-before edge, so the box is never concurrently accessed.
        final class ResponseBox: @unchecked Sendable { var text: String? }
        let box = ResponseBox()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            box.text = QAControlPlane.shared.respond(to: line)
            done.signal()
        }
        done.wait()
        return box.text ?? failure("No response produced")
    }

    // MARK: - Socket

    /// Caller decides whether the path may be removed first; unlinking unconditionally here would let a second instance steal a live socket.
    private static func makeListener(at path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            return nil
        }
        chmod(path, 0o600)
        return fd
    }

    static var lockPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("tmp/loomscreen-qa.lock")
    }

    /// Non-blocking exclusive flock, held for the life of the process. Returns nil when
    /// another live instance holds it.
    private nonisolated static func acquireLock(at path: String) -> Int32? {
        // Read-only on purpose: flock needs no write access, so nothing here can ever put bytes into the file.
        let fd = open(path, O_CREAT | O_RDONLY, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private nonisolated static func inode(of path: String) -> ino_t? {
        var info = stat()
        return stat(path, &info) == 0 ? info.st_ino : nil
    }

    static func shutdown() {
        shared.stop()
    }

    private func stop() {
        guard listenerFD >= 0 else { return }
        isStopped = true
        let path = Self.socketPath
        // Unlink BEFORE close: once the listener is closed another instance can bind, and a later unlink would delete that fresh socket.
        if let boundInode, Self.inode(of: path) == boundInode {
            unlink(path)
        }
        close(listenerFD)
        listenerFD = -1
        boundInode = nil
        if lockFD >= 0 {
            close(lockFD)
            lockFD = -1
        }
        Logger.notice("[QA] control plane stopped", category: .lifecycle)
    }

    /// Upper bound for one unfinished request line.
    private nonisolated static let maxRequestBytes = 1 << 20

    private nonisolated static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written <= 0 {
                    if errno == EINTR {
                        continue
                    }
                    Logger.notice("[QA] response write stopped errno=\(errno)", category: .lifecycle)
                    return false
                }
                pointer += written
                remaining -= written
            }
            return true
        }
    }

    private nonisolated static func acceptLoop(
        listener: Int32,
        workers: DispatchQueue,
        handle: @escaping @Sendable (String) -> String
    ) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                if errno == EINTR {
                    continue
                }
                return
            }
            var timeout = timeval(tv_sec: 15, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            // Without SO_NOSIGPIPE, writing to a hung-up bridge raises SIGPIPE and would kill the app — a Swift throw cannot catch a signal.
            var noSigPipe: Int32 = 1
            if setsockopt(
                client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)
            ) != 0 {
                Logger.error("[QA] SO_NOSIGPIPE failed errno=\(errno)", category: .lifecycle)
            }
            workers.async {
                serve(client: client, handle: handle)
                close(client)
            }
        }
    }

    /// nonisolated is load-bearing: a static method on a @MainActor type inherits that isolation, and running it off the main queue traps in dispatch_assert_queue.
    private nonisolated static func serve(client: Int32, handle: @escaping @Sendable (String) -> String) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let read = Darwin.read(client, &buffer, buffer.count)
            guard read > 0 else { return }
            pending.append(contentsOf: buffer[0 ..< read])
            // SO_RCVTIMEO is an idle timeout: a client that keeps sending without ever
            // writing a newline never trips it, so cap the unfinished line instead.
            guard pending.count <= maxRequestBytes else { return }
            while let newline = pending.firstIndex(of: 0x0A) {
                // Failable on purpose: `String(decoding:)` would swallow invalid UTF-8 as
                // replacement characters and hand JSON a silently corrupted line.
                guard let line = String(bytes: pending[pending.startIndex ..< newline], encoding: .utf8) else {
                    return
                }
                // Rebuild rather than slice: `firstIndex` is absolute, so a slice's
                // startIndex would not be 0 and the next scan would read past the line.
                pending = Data(pending[(newline + 1)...])
                guard var response = handle(line).data(using: .utf8) else { return }
                response.append(0x0A)
                // A single write can be short; stop on EPIPE rather than looping forever.
                guard writeAll(client, response) else { return }
            }
        }
    }

    // MARK: - Dispatch

    func respond(to line: String) -> String {
        // A request can be queued before shutdown and run after it; committing then would
        // change settings in an app whose ScreenManager is already torn down.
        guard !isStopped else { return Self.failure("Control plane is shutting down") }
        guard let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = request["tool"] as? String else {
            return Self.failure("Malformed request: expected {\"tool\": …}")
        }
        let arguments = request["arguments"] as? [String: Any] ?? [:]
        do {
            return try Self.success(route(tool: tool, arguments: arguments))
        } catch {
            return Self.failure("\(error)")
        }
    }

    private func route(tool: String, arguments: [String: Any]) throws -> Any {
        switch tool {
        case "meta.describe": return Self.describe()
        case "settings.get": return try settingsGet()
        case "settings.patch": return try settingsPatch(arguments)
        case "state.dump": return try stateDump()
        case "defaults.get": return try defaultsGet(arguments)
        case "defaults.set": return try defaultsSet(arguments)
        case "wallpaper.list": return try wallpaperList()
        case "wallpaper.apply": return try wallpaperApply(arguments)
        case "wallpaper.togglePlayback": return try wallpaperTogglePlayback(arguments)
        case "screen.get": return try screenGet(arguments)
        case "screen.patch": return try screenPatch(arguments)
        case "runtime.state": return try runtimeState(arguments)
        default: throw QAError.message("Unknown tool: \(tool)")
        }
    }

    // MARK: - Tools

    private static func describe() -> Any {
        [
            "protocolVersion": 1,
            "sku": Bundle.main.bundleIdentifier ?? "unknown",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "pid": ProcessInfo.processInfo.processIdentifier,
            "executablePath": Bundle.main.executablePath ?? "unknown",
            "tools": [
                ["name": "meta.describe", "arguments": [:] as [String: Any],
                 "description": "Tool catalog, writable setting keys and this instance's identity."],
                ["name": "settings.get", "arguments": [:] as [String: Any],
                 "description": "Full GlobalSettings plus the writable-key split."],
                ["name": "settings.patch",
                 "arguments": ["<field>": "any GlobalSettings field listed in writableKeys"],
                 "description": "Read-modify-write through the same commit the Settings UI uses, so the apply chain runs."],
                ["name": "state.dump", "arguments": [:] as [String: Any],
                 "description": "Live per-screen wallpaper session state: type, activity, subtitle, runtime error."],
                ["name": "defaults.get", "arguments": ["key": "String"],
                 "description": "Read one UserDefaults-backed setting."],
                ["name": "defaults.set", "arguments": ["key": "String", "value": "Bool | Double | String"],
                 "description": "Write one UserDefaults-backed setting."],
                ["name": "wallpaper.list", "arguments": [:] as [String: Any],
                 "description": "Authorized wallpaper bookmarks by id and label. Never returns bookmark bytes."],
                ["name": "wallpaper.apply", "arguments": ["bookmarkID": "String", "screenID": "Int"],
                 "description": "Switch one screen's wallpaper through ScreenManager.applyBookmark, which bumps the transition generation. Content only — per-screen playback settings are preserved. Loading is asynchronous."],
                ["name": "wallpaper.togglePlayback", "arguments": ["screenID": "Int"],
                 "description": "Toggle playback for one screen, or for every screen when screenID is omitted."],
                ["name": "screen.get", "arguments": ["screenID": "Int"],
                 "description": "Per-screen playback configuration; all screens when screenID is omitted."],
                ["name": "runtime.state", "arguments": ["screenID": "Int"],
                 "description": "What the live session reports (playback, frame production, renderer errors) — as opposed to what the store holds. Volume, frame-rate and fit mode are push-only and absent here."],
                ["name": "screen.patch", "arguments": ["screenID": "Int", "<field>": "any key listed in screenWritableKeys"],
                 "description": "Write per-screen playback settings through ScreenManager's named setters, so each change also reaches the live session."],
            ],
            "writableKeys": [
                "general": Array(generalKeys).sorted(),
                "workshop": Array(workshopKeys).sorted(),
            ],
            "screenWritableKeys": Array(screenWritableKeys).sorted(),
            "writableFields": writableFieldTypes(),
            "unwritableReason": [
                "globalShortcuts": "Binding table is not exposed yet; edit it from the Shortcuts page.",
                "recentWPEImports": "Import history, not a setting.",
                "deletedWorkshopIDs": "Tombstones, not a setting.",
                "scenePresets": "Preset library, not a setting.",
            ],
        ]
    }

    private static func writableFieldTypes() -> [String: Any] {
        guard let json = try? encodeToJSON(SettingsManager.shared.loadGlobalSettings()) else { return [:] }
        var fields: [String: Any] = [:]
        for key in generalKeys.union(workshopKeys) {
            guard let value = json[key] else { continue }
            fields[key] = [
                "type": jsonTypeName(value),
                "current": value,
                "page": generalKeys.contains(key) ? "general" : "workshop",
            ]
        }
        return fields
    }

    private static func jsonTypeName(_ value: Any) -> String {
        if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
            return "boolean"
        }
        switch value {
        case is NSNumber: return "number"
        case is String: return "string"
        case is [Any]: return "array"
        case is [String: Any]: return "object"
        default: return "unknown"
        }
    }

    private static let generalKeys: Set<String> = [
        "globalPauseOnBattery", "preservePlaybackOnLock", "startOnLogin", "pauseOnFullScreen",
        "pauseOnWindowOcclusion", "pauseInLowPowerMode", "applicationPerformanceRules",
        "showInDock", "wallpaperVisibleInScreenCapture", "videoCacheMaxBytesPerScreen",
        "audioResponseEnabled", "adaptiveFrameRateEnabled", "weatherLocation",
    ]

    private static let workshopKeys: Set<String> = [
        "showsWorkshopPresetsInBrowse", "workshopDefaultSort", "workshopDefaultTimeFrame",
    ]

    private func settingsGet() throws -> Any {
        try [
            "globalSettings": Self.encodeToJSON(SettingsManager.shared.loadGlobalSettings()),
            "writableKeys": [
                "general": Array(Self.generalKeys).sorted(),
                "workshop": Array(Self.workshopKeys).sorted(),
            ],
        ]
    }

    private func settingsPatch(_ patch: [String: Any]) throws -> Any {
        guard !patch.isEmpty else { throw QAError.message("Empty patch") }
        let unknown = patch.keys.filter {
            !Self.generalKeys.contains($0) && !Self.workshopKeys.contains($0)
        }
        guard unknown.isEmpty else {
            throw QAError.message("Not writable: \(unknown.sorted().joined(separator: ", "))")
        }

        var json = try Self.encodeToJSON(SettingsManager.shared.loadGlobalSettings())
        for (key, value) in patch {
            json[key] = value
        }
        let merged: GlobalSettings = try Self.decodeFromJSON(json)
        // GlobalSettings.init(from:) is a migration decoder; decoding proves nothing about the patch. Re-encode and compare each patched key — a swallowed value comes back changed.
        let roundTrip = try Self.encodeToJSON(merged)
        for (key, value) in patch {
            guard Self.jsonEqual(roundTrip[key], value) else {
                throw QAError.message(
                    "Rejected \(key): the value did not survive decoding "
                        + "(stored would become \(Self.describeJSON(roundTrip[key])))"
                )
            }
        }

        var applied: [String] = []
        if patch.keys.contains(where: Self.generalKeys.contains) {
            guard let screenManager else { throw QAError.message("ScreenManager unavailable") }
            GlobalSettingsCommit.apply(
                GlobalSettingsCommit.GeneralPageFields(
                    globalPauseOnBattery: merged.globalPauseOnBattery,
                    preservePlaybackOnLock: merged.preservePlaybackOnLock,
                    startOnLogin: merged.startOnLogin,
                    pauseOnFullScreen: merged.pauseOnFullScreen,
                    pauseOnWindowOcclusion: merged.pauseOnWindowOcclusion,
                    pauseInLowPowerMode: merged.pauseInLowPowerMode,
                    applicationPerformanceRules: merged.applicationPerformanceRules,
                    showInDock: merged.showInDock,
                    wallpaperVisibleInScreenCapture: merged.wallpaperVisibleInScreenCapture,
                    videoCacheMaxBytesPerScreen: merged.videoCacheMaxBytesPerScreen,
                    audioResponseEnabled: merged.audioResponseEnabled,
                    adaptiveFrameRateEnabled: merged.adaptiveFrameRateEnabled,
                    weatherLocation: merged.weatherLocation
                ),
                screenManager: screenManager
            )
            applied.append("general")
        }
        if patch.keys.contains(where: Self.workshopKeys.contains) {
            GlobalSettingsCommit.apply(
                GlobalSettingsCommit.WorkshopPageFields(
                    showsPresetsInBrowse: merged.showsWorkshopPresetsInBrowse,
                    defaultSort: merged.workshopDefaultSort,
                    defaultTimeFrame: merged.workshopDefaultTimeFrame
                )
            )
            applied.append("workshop")
        }
        // Read back through the store rather than echoing the merge, so the caller
        // sees what persistence actually holds.
        return try [
            "status": "applied",
            "commits": applied,
            "globalSettings": Self.encodeToJSON(SettingsManager.shared.loadGlobalSettings()),
        ]
    }

    private func stateDump() throws -> Any {
        guard let screenManager else { throw QAError.message("ScreenManager unavailable") }
        let screens = screenManager.screens.map { screen -> [String: Any] in
            let summary = screenManager.wallpaperSummary(for: screen)
            var entry: [String: Any] = [
                "screenID": screen.id,
                "name": screen.name,
                "displayFingerprint": screen.displayFingerprint,
                "frame": ["width": screen.frame.width, "height": screen.frame.height],
                "activity": String(describing: summary.activity),
                "supportsPlaybackControl": summary.supportsPlaybackControl,
                "hasActiveWindow": screen.activeWallpaperWindow != nil,
            ]
            entry["wallpaperType"] = summary.wallpaperType.map { String(describing: $0) } ?? NSNull()
            entry["subtitle"] = summary.subtitle ?? NSNull()
            entry["displayName"] = screenManager.wallpaperDisplayName(for: screen) ?? NSNull()
            entry["runtimeError"] = screenManager.runtimeError(for: screen)
                .map { String(describing: $0) } ?? NSNull()
            // A load that never produced a session reports through wallpaperLoads, not runtimeError. Reading only the latter would make a failed apply look like nothing happened.
            if let attempt = screenManager.wallpaperLoads.attempt(for: screen) {
                var load: [String: Any] = [
                    "phase": String(describing: attempt.phase),
                    "title": attempt.title,
                ]
                if let failure = attempt.failure {
                    load["failure"] = [
                        "stage": failure.stage,
                        "code": failure.cause.code,
                        "reason": failure.cause.reason,
                        "canRetry": failure.cause.canRetry,
                        "workshopID": failure.workshopID ?? NSNull(),
                    ]
                }
                entry["loadAttempt"] = load
            } else {
                entry["loadAttempt"] = NSNull()
            }
            return entry
        }
        return ["screens": screens, "screenCount": screens.count]
    }

    private func defaultsGet(_ arguments: [String: Any]) throws -> Any {
        guard let key = arguments["key"] as? String else { throw QAError.message("Missing key") }
        let stored = UserDefaults.standard.object(forKey: key)
        return ["key": key, "value": Self.jsonSafeDefaultsValue(stored), "isSet": stored != nil]
    }

    /// `Data`/`Date` defaults (bookmarks, migration stamps) would throw an ObjC exception inside
    /// `JSONSerialization`; they are reported by type instead of by value.
    nonisolated static func jsonSafeDefaultsValue(_ stored: Any?) -> Any {
        guard let stored else { return NSNull() }
        return JSONSerialization.isValidJSONObject([stored]) ? stored : ["opaque": true, "type": String(describing: type(of: stored))]
    }

    private func defaultsSet(_ arguments: [String: Any]) throws -> Any {
        guard let key = arguments["key"] as? String else { throw QAError.message("Missing key") }
        guard let value = arguments["value"] else { throw QAError.message("Missing value") }
        // A key that holds a non-JSON value is product state (a bookmark, a trust table), not a diagnostic knob.
        if let existing = UserDefaults.standard.object(forKey: key), !JSONSerialization.isValidJSONObject([existing]) {
            throw QAError.message("\(key) holds \(type(of: existing)) and is not a diagnostic key")
        }
        if value is NSNull {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            // `UserDefaults.set` raises an ObjC exception (a crash) for anything that is not a property list.
            guard PropertyListSerialization.propertyList(value, isValidFor: .binary) else {
                throw QAError.message("Value is not a property list (a null inside a container is not allowed)")
            }
            UserDefaults.standard.set(value, forKey: key)
        }
        return ["key": key, "value": Self.jsonSafeDefaultsValue(UserDefaults.standard.object(forKey: key))]
    }

    // MARK: - Encoding

    enum QAError: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self {
            case let .message(text): text
            }
        }
    }

    /// Serialized comparison, so `true` and `1` are not conflated the way `isEqual` does.
    private static func jsonEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        func canonical(_ value: Any?) -> Data? {
            guard let value else { return nil }
            return try? JSONSerialization.data(withJSONObject: ["v": value], options: [.sortedKeys])
        }
        let left = canonical(lhs)
        let right = canonical(rhs)
        return left != nil && left == right
    }

    private static func describeJSON(_ value: Any?) -> String {
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: ["v": value], options: [.sortedKeys]),
              let text = String(bytes: data, encoding: .utf8) else { return "nil" }
        return text
    }

    private static func encodeToJSON(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QAError.message("Encoded value is not a JSON object")
        }
        return object
    }

    private static func decodeFromJSON<T: Decodable>(_ object: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private nonisolated static func success(_ result: Any) -> String {
        serialize(["ok": true, "result": result])
    }

    private nonisolated static func failure(_ message: String) -> String {
        serialize(["ok": false, "error": message])
    }

    private nonisolated static func serialize(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"Response is not serializable\"}"
        }
        return text
    }
}
#endif
