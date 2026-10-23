import Foundation

/// Where Loomscreen may write inside the shared Steam library, and nowhere else.
///
/// Pure rules, shared with the app so the boundary can be asserted in tests
/// without a Steam install. The mutating half lives only in the connector.
enum SteamLibraryPaths {
    static let wallpaperEngineAppID = "431960"

    /// The two subtrees Loomscreen may write, relative to the Steam root.
    private static let writableSubtrees: [[String]] = [
        workshopContentComponents,
        wallpaperEngineComponents,
    ]

    static func steamRoot() -> URL {
        URL(fileURLWithPath: SteamConnectorEnvironmentProbe.posixHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
    }

    /// The two roots take an injectable Steam root for the same reason
    /// `isWritable` does: the destructive paths must be exercisable against a
    /// scratch tree, never the user's library.
    static func workshopContentRoot(steamRoot root: URL = steamRoot()) -> URL {
        root.appendingPathComponent(
            "steamapps/workshop/content/\(wallpaperEngineAppID)",
            isDirectory: true
        )
    }

    /// Where SteamCMD stages `itemID` before committing it to `content/`; emptied by the commit.
    static func workshopStagingDirectories(steamRoot root: URL, appID: String, itemID: String) -> [URL] {
        ["downloads", "temp"].map {
            root.appendingPathComponent("steamapps/workshop/\($0)/\(appID)/\(itemID)", isDirectory: true)
        }
    }

    static let workshopContentComponents = ["steamapps", "workshop", "content", wallpaperEngineAppID]
    static let wallpaperEngineComponents = ["steamapps", "common", "wallpaper_engine"]

    static func wallpaperEngineInstallRoot(steamRoot root: URL = steamRoot()) -> URL {
        root.appendingPathComponent("steamapps/common/wallpaper_engine", isDirectory: true)
    }

    /// The Steam library the app authorized, re-checked here because the
    /// connector runs unsandboxed: the app's security-scoped grant confers
    /// nothing on this side, so the path arrives as an ordinary string and is
    /// only as trustworthy as these rules make it. Same symlink walk the
    /// managed-install removals use — a link anywhere along the way would let
    /// the writable-subtree anchor point at an arbitrary tree.
    static func validatedLibraryRoot(_ path: String) -> URL? {
        // The raw components, before standardizing: `standardizedFileURL`
        // resolves `..` away, so checking afterwards would pass vacuously.
        guard path.hasPrefix("/"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        // The connector does not trust the caller's word that this is a Steam
        // library: `isWritable` only bounds the subtree *relative to* whatever
        // root it is handed, so without this an XPC caller could name any
        // directory and have an unsandboxed process build `steamapps/...` in
        // it. Same judgement the app applies when the user picks a folder — the
        // canonical location counts even without `config.vdf`, because a
        // SteamCMD-only install has no client config.
        guard path == steamRoot().standardizedFileURL.path(percentEncoded: false)
            || FileManager.default.isReadableFile(
                atPath: (path as NSString).appendingPathComponent("config/config.vdf")
            )
        else { return nil }
        // Deliberately NOT symlink-checked: `isWritable` already settled that a
        // legitimately symlinked Steam root is supported (a user may point the
        // library at another volume), and rejecting one here would break that
        // setup outright. What bounds each path differs: the writer walks with
        // `O_NOFOLLOW` from the root down and re-checks `isWritable`, while a
        // direct download is bounded only by this check plus SteamCMD's own
        // fixed `steamapps/workshop` layout — it resolves the path itself, so
        // a link the user planted inside their library is followed.
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// A Workshop id must be exactly ASCII `0-9`: it becomes a path component
    /// under the user's real Steam library. Not `Character.isNumber` — that
    /// also passes Nd/Nl/No (fullwidth `１２３`, `①`, `٤`), which are not Steam
    /// ids but would still be created or deleted as directories.
    static func isSafeWorkshopID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 20 && id.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// True only for paths at or under one of the two writable subtrees,
    /// with **no symlink anywhere between the Steam root and the target**.
    /// Resolving both sides before comparing was not containment: replacing
    /// `steamapps/workshop/content/431960` with a link to `~/Documents` made
    /// the target and its anchor resolve consistently, so an arbitrary
    /// directory looked "inside" — the path is instead walked one
    /// component at a time with `lstat`, which doesn't follow links.
    /// `steamRoot` is injectable so the walk runs against a scratch tree;
    /// the real library must never be mutated by a test.
    static func isWritable(_ url: URL, steamRoot root: URL) -> Bool {
        // Use the root exactly as given. Canonicalizing it here while the target
        // stays lexical made a legitimately symlinked Steam root fail its own
        // prefix test; the walk below starts after the root, so the root being a
        // link is accepted without ever resolving anything under it.
        var base = root.standardizedFileURL.path(percentEncoded: false)
        while base.count > 1, base.hasSuffix("/") {
            base.removeLast()
        }
        let target = url.standardizedFileURL.path(percentEncoded: false)
        guard target.hasPrefix(base + "/") else { return false }

        let components = String(target.dropFirst(base.count + 1))
            .split(separator: "/").map(String.init)
        guard !components.contains(".."), !components.contains("."), writableSubtrees.contains(where: {
            components.count >= $0.count && Array(components.prefix($0.count)) == $0
        }) else { return false }

        var walked = base
        for component in components {
            walked += "/" + component
            var info = stat()
            // A component that does not exist yet is fine; one that exists as a
            // link is not, whatever it points at.
            guard lstat(walked, &info) == 0 else { return true }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                return false
            }
        }
        return true
    }
}

/// Reads Wallpaper Engine build ids out of SteamCMD's `app_info_print` dump.
enum SteamConnectorBuildInfo {
    /// `"buildid"  "23967692"` inside `branches { "public" { … } }`. The
    /// `branches` block is located first: the dump's first `"public"` is the
    /// depot manifest (gid/size/download, no buildid), so keying on it
    /// returned nil for every real update check. Reads the buildid from
    /// inside the `public` block only — a block with no readable buildid must
    /// not fall to the next branch and report a beta build as public.
    static func parsePublicBuildID(from output: String) -> String? {
        guard let branches = block(named: "branches", in: output[...]),
              let publicBranch = block(named: "public", in: branches),
              let match = publicBranch.firstMatch(of: /"buildid"\s+"(\d+)"/) else { return nil }
        return String(match.output.1)
    }

    /// Contents of the brace-matched block following the first `"name"` key.
    private static func block(named name: String, in text: Substring) -> Substring? {
        guard let keyRange = text.range(of: "\"\(name)\"") else { return nil }
        let afterKey = text[keyRange.upperBound...]
        guard let open = afterKey.firstIndex(of: "{") else { return nil }

        var depth = 0
        var index = open
        while index < afterKey.endIndex {
            let character = afterKey[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    break
                }
            }
            index = afterKey.index(after: index)
        }
        guard depth == 0, index < afterKey.endIndex else { return nil }
        return afterKey[afterKey.index(after: open) ..< index]
    }
}
