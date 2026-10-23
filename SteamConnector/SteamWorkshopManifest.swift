import Foundation

/// One bounded receipt for this request, independent of the last self-update run's output.
struct SteamWorkshopDownloadCompletion {
    let workshopID: String?
    private(set) var completed = false

    mutating func record(output: String, exitCode: Int32, timedOut: Bool, terminationSignal: Int32?) {
        guard let workshopID, SteamLibraryPaths.isSafeWorkshopID(workshopID) else { return }
        // A relaunch that actually attempts and fails this item invalidates an earlier receipt.
        if output.contains("ERROR! Download item \(workshopID) failed") {
            completed = false
            return
        }
        guard !timedOut, terminationSignal == nil,
              exitCode == 0 || exitCode == SteamCMDSelfUpdateRestartPolicy.restartExitCode,
              output.contains("Success. Downloaded item \(workshopID) to ") else { return }
        completed = true
    }

    /// A receipt plus a committed manifest and its payload; stale `project.json` alone proves nothing.
    static func validCommittedItem(at folder: URL, steamRoot: URL) -> Bool {
        let project = folder.appendingPathComponent("project.json")
        guard SteamLibraryPaths.isWritable(project, steamRoot: steamRoot) else { return false }
        let fd = open(project.path(percentEncoded: false), O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size > 0, metadata.st_size <= 2 * 1024 * 1024,
              let data = try? handle.read(upToCount: 2 * 1024 * 1024 + 1), data.count <= 2 * 1024 * 1024,
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        // Presets intentionally have no entry file. The importer reads values from the manifest itself.
        if manifest["file"] == nil, let dependency = manifest["dependency"] as? String,
           SteamLibraryPaths.isSafeWorkshopID(dependency), (9 ... 20).contains(dependency.count),
           manifest["preset"] is [String: Any] {
            return true
        }
        guard let file = manifest["file"] as? String, !file.isEmpty,
              !file.hasPrefix("/"), !file.split(separator: "/").contains("..") else { return false }
        // Packaged scenes (and packaged video/web) name their entry inside the package; WPE names the package after
        // the entry file's stem (ricepod.json → ricepod.pkg) and older items use scene.pkg.
        let stemPackage = ((file as NSString).lastPathComponent as NSString).deletingPathExtension + ".pkg"
        if validPayload(folder.appendingPathComponent(stemPackage), steamRoot: steamRoot)
            || validPayload(folder.appendingPathComponent("scene.pkg"), steamRoot: steamRoot) {
            return true
        }
        let payload = folder.appendingPathComponent(file).standardizedFileURL
        return payload.path.hasPrefix(folder.standardizedFileURL.path + "/")
            && validPayload(payload, steamRoot: steamRoot)
    }

    private static func validPayload(_ payload: URL, steamRoot: URL) -> Bool {
        guard SteamLibraryPaths.isWritable(payload, steamRoot: steamRoot),
              let attributes = try? FileManager.default.attributesOfItem(atPath: payload.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.uint64Value > 0 else { return false }
        return true
    }
}

enum SteamDirectorySize {
    /// Allocated bytes of the regular files under `root`, links never followed; 0 when `root` is
    /// missing. Stops at what it has counted once `entryLimit` entries were visited.
    static func allocatedBytes(at root: URL, entryLimit: Int) -> UInt64 {
        var total: UInt64 = 0
        var visited = 0
        var pending = [root.path(percentEncoded: false)]
        while visited < entryLimit, let directory = pending.popLast() {
            var info = stat()
            guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  let stream = opendir(directory) else { continue }
            defer { closedir(stream) }
            while visited < entryLimit, let entry = readdir(stream) {
                let length = Int(entry.pointee.d_namlen)
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: length) {
                        FileManager.default.string(withFileSystemRepresentation: $0, length: length)
                    }
                }
                guard name != ".", name != ".." else { continue }
                visited += 1
                let path = (directory as NSString).appendingPathComponent(name)
                guard lstat(path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFREG:
                    // SteamCMD preallocates its files, so st_size alone reads near-complete from the start.
                    total += min(UInt64(info.st_size), UInt64(info.st_blocks) * 512)
                case S_IFDIR:
                    pending.append(path)
                default:
                    break
                }
            }
        }
        return total
    }

    /// The value to report, or nil unless it beats the last one: the commit empties staging.
    static func nextReport(measured: UInt64, reported: UInt64) -> UInt64? {
        measured > reported ? measured : nil
    }
}

/// Follows only bytes appended during one SteamCMD execution. The console's
/// `workshop_status` command returns before its subscription request completes;
/// the Workshop log is where SteamCMD acknowledges that response.
final class SteamCMDSubscriptionRefresh {
    struct Completion: Equatable {
        let count: Int
        /// A changed list carries the server's version, which must also be in
        /// the ledger. An unchanged response explicitly authorizes the cache.
        let updatedAt: String?

        func subscriptions(in text: String) -> [String]? {
            guard SteamWorkshopManifest.subscriptionField("appid", in: text) == SteamLibraryPaths.wallpaperEngineAppID,
                  let ids = SteamWorkshopManifest.subscribedIDs(fromSubscriptionsVDF: text),
                  ids.count == count else { return nil }
            if let updatedAt,
               SteamWorkshopManifest.subscriptionField("time_last_updated", in: text) != updatedAt {
                return nil
            }
            return ids
        }
    }

    private let logURL: URL
    private var identity: (device: dev_t, inode: ino_t)?
    private var offset: off_t = 0
    private var framer = SteamCMDOutputFramer()
    private var requested = false
    private(set) var completion: Completion?

    init(logURL: URL) {
        self.logURL = logURL
        let fd = open(logURL.path(percentEncoded: false), O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return }
        identity = (info.st_dev, info.st_ino)
        offset = info.st_size
    }

    func poll() {
        let fd = open(logURL.path(percentEncoded: false), O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return }
        if identity?.device != info.st_dev || identity?.inode != info.st_ino || info.st_size < offset {
            offset = 0
            framer = SteamCMDOutputFramer()
            requested = false
            completion = nil
        }
        identity = (info.st_dev, info.st_ino)
        guard lseek(fd, offset, SEEK_SET) >= 0 else { return }
        // Bounded per poll and per line, even if a broken child floods the log.
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(fd, &bytes, bytes.count)
        guard count > 0 else { return }
        offset += off_t(count)
        for line in framer.append(Data(bytes.prefix(count))) {
            let app = "[AppID \(SteamLibraryPaths.wallpaperEngineAppID)] "
            guard let marker = line.range(of: app) else { continue }
            let message = String(line[marker.upperBound...])
            if message == "Requesting updated subscription list" {
                requested = true
                completion = nil
            } else if requested,
                      let match = message.firstMatch(of: /^Subscribed items changed\. Number of items: ([0-9]+) \(update time: ([0-9]+)\)$/),
                      let count = Int(match.1) {
                completion = Completion(count: count, updatedAt: String(match.2))
            } else if requested,
                      let match = message.firstMatch(of: /^Subscribed items did not change\. Number of items: ([0-9]+)(?: \(cache update time: [0-9]+\))?$/),
                      let count = Int(match.1) {
                completion = Completion(count: count, updatedAt: nil)
            }
        }
    }
}

/// The account's Workshop subscription list as SteamCMD keeps it in the profile,
/// readable without a publisher Web API key.
enum SteamWorkshopManifest {
    /// Read only scalar fields at the root of the subscription ledger; a
    /// similarly named field inside an item cannot authorize an old cache.
    static func subscriptionField(_ name: String, in text: String) -> String? {
        var cursor = text.startIndex
        guard SteamAccountsFile.nextQuoted(in: text[...], from: &cursor) == "subscribedfiles",
              let root = SteamAccountsFile.nextBraceBlock(in: text[...], from: &cursor) else { return nil }
        cursor = root.startIndex
        while let key = SteamAccountsFile.nextQuoted(in: root, from: &cursor) {
            while cursor < root.endIndex, root[cursor].isWhitespace {
                cursor = root.index(after: cursor)
            }
            if cursor < root.endIndex, root[cursor] == "{" {
                guard SteamAccountsFile.nextBraceBlock(in: root, from: &cursor) != nil else { return nil }
            } else {
                guard let value = SteamAccountsFile.nextQuoted(in: root, from: &cursor) else { return nil }
                if key == name {
                    return value
                }
            }
        }
        return nil
    }

    /// SteamCMD only requests the subscription list for apps it sees installed;
    /// without `Universe` it ignores the manifest.
    static let probeAppManifest = """
    "AppState"
    {
    \t"appid"\t\t"\(SteamLibraryPaths.wallpaperEngineAppID)"
    \t"Universe"\t\t"1"
    \t"StateFlags"\t\t"4"
    \t"installdir"\t\t"wallpaper_engine"
    }\n
    """

    /// `publishedfileid`s of `userdata/<accountid>/ugc/<appid>_subscriptions.vdf` in file
    /// order, deduplicated, path-safe only. nil when the `subscribedfiles` block is incomplete.
    static func subscribedIDs(fromSubscriptionsVDF text: String) -> [String]? {
        guard let key = text.range(of: "\"subscribedfiles\"") else { return nil }
        var cursor = key.upperBound
        guard let block = SteamAccountsFile.nextBraceBlock(in: text[...], from: &cursor) else { return nil }
        var ids: [String] = []
        var seen: Set<String> = []
        var entryCursor = block.startIndex
        while let entry = SteamAccountsFile.nextBraceBlock(in: block, from: &entryCursor) {
            var fieldCursor = entry.startIndex
            while let field = SteamAccountsFile.nextQuoted(in: entry, from: &fieldCursor),
                  let value = SteamAccountsFile.nextQuoted(in: entry, from: &fieldCursor) {
                guard field == "publishedfileid", SteamLibraryPaths.isSafeWorkshopID(value),
                      seen.insert(value).inserted else { continue }
                ids.append(value)
            }
        }
        return ids
    }

    /// Item ids under `WorkshopItemsInstalled` of `appworkshop_<appid>.acf`; nil when that block is missing or incomplete.
    static func installedIDs(fromACF text: String) -> Set<String>? {
        guard let block = installedBlock(in: text[...]) else { return nil }
        var ids: Set<String> = []
        var entryCursor = block.startIndex
        // Any token outside `"<digits>" { … }` fails the whole set: it authorizes deleting library records.
        while skipTrivia(in: block, from: &entryCursor) {
            guard block[entryCursor] == "\"",
                  let id = SteamAccountsFile.nextQuoted(in: block, from: &entryCursor),
                  !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }),
                  skipTrivia(in: block, from: &entryCursor), block[entryCursor] == "{",
                  SteamAccountsFile.nextBraceBlock(in: block, from: &entryCursor) != nil else { return nil }
            ids.insert(id)
        }
        return ids
    }

    /// The block of the one `"WorkshopItemsInstalled"` key directly under the root, matched as a key token rather than inside a
    /// comment or as a value; nil unless the whole text is balanced key/value pairs holding that key there once and nowhere deeper.
    private static func installedBlock(in text: Substring) -> Substring? {
        var cursor = text.startIndex
        var depth = 0
        var expectsKey = true
        var installed: Substring?
        while skipTrivia(in: text, from: &cursor) {
            switch text[cursor] {
            case "\"":
                guard let token = SteamAccountsFile.nextQuoted(in: text, from: &cursor) else { return nil }
                if expectsKey, token.caseInsensitiveCompare("WorkshopItemsInstalled") == .orderedSame {
                    guard depth == 1, installed == nil, skipTrivia(in: text, from: &cursor), text[cursor] == "{",
                          let block = SteamAccountsFile.nextBraceBlock(in: text, from: &cursor) else { return nil }
                    installed = block
                } else {
                    expectsKey.toggle()
                }
            case "{":
                guard !expectsKey else { return nil }
                depth += 1
                expectsKey = true
                cursor = text.index(after: cursor)
            case "}":
                guard expectsKey, depth > 0 else { return nil }
                depth -= 1
                cursor = text.index(after: cursor)
            default:
                return nil
            }
        }
        return depth == 0 && expectsKey ? installed : nil
    }

    /// Advances past whitespace and `//` line comments; false once `text` is exhausted.
    private static func skipTrivia(in text: Substring, from cursor: inout Substring.Index) -> Bool {
        while cursor < text.endIndex {
            if text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            } else if text[cursor...].hasPrefix("//") {
                // `\r\n` is one Character, so matching "\n" alone would swallow the rest of the block.
                cursor = text[cursor...].firstIndex(where: \.isNewline) ?? text.endIndex
            } else {
                return true
            }
        }
        return false
    }
}
