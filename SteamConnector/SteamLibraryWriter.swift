import Foundation

/// Every write Loomscreen makes to the user's Steam library goes through
/// here — the main app holds no write capability at all, and can't delete
/// a Workshop item or prune a Wallpaper Engine install even if its code
/// tried; one process, one place to audit. Guards ported from the app's
/// retired `WPEEngineAssetsFilesystemOwner`, with the containment anchor
/// moved from "our sandbox container" to "the Steam root we were pointed
/// at". Two subtrees are writable and nothing else:
///   `steamapps/workshop/content/431960/<id>/`
///   `steamapps/common/wallpaper_engine/`
enum SteamLibraryWriter {
        enum WriteError: Error {
        case outsideAllowedSubtree
        case unexpectedLayout
        case symbolicLinkRejected
        case missingAssets

        var reason: String {
            switch self {
            case .outsideAllowedSubtree: return "path is outside the two writable Steam subtrees"
            case .unexpectedLayout: return "path does not have the expected Steam layout"
            case .symbolicLinkRejected: return "path is a symbolic link"
            case .missingAssets: return "install has no assets/ subtree to keep"
            }
        }
    }

    // MARK: - Delete

    /// Removes one Workshop item. Steam's `appworkshop_431960.acf`
    /// deliberately keeps listing it afterwards — it's Steam's ledger, not
    /// ours, and a later `workshop_download_item` re-fetching it is the
    /// wanted behaviour; do not "fix" that by rewriting the acf.
    /// `steamRoot` is injectable purely so the destructive path can be
    /// tested against a scratch tree; production always takes the default.
    static func deleteWorkshopItem(
        workshopID: String,
        steamRoot: URL = SteamLibraryPaths.steamRoot()
    ) -> SteamDeleteResult {
        guard SteamLibraryPaths.isSafeWorkshopID(workshopID) else {
            return SteamDeleteResult(outcome: .refused, freedBytes: 0, refusalReason: "unsafe Workshop id")
        }
        let folder = SteamLibraryPaths.workshopContentRoot(steamRoot: steamRoot)
            .appendingPathComponent(workshopID, isDirectory: true)
        guard SteamLibraryPaths.isWritable(folder, steamRoot: steamRoot) else {
            return SteamDeleteResult(
                outcome: .refused,
                freedBytes: 0,
                refusalReason: WriteError.outsideAllowedSubtree.reason
            )
        }
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
            return SteamDeleteResult(outcome: .notFound, freedBytes: 0, refusalReason: nil)
        }
        let size = allocatedBytes(at: folder)
        do {
            let parent = try openDirectory(
                root: steamRoot,
                components: SteamLibraryPaths.workshopContentComponents
            )
            defer { close(parent) }
            try removeTree(parent: parent, name: workshopID)
        } catch let error as WriteError {
            return SteamDeleteResult(outcome: .refused, freedBytes: 0, refusalReason: error.reason)
        } catch {
            return SteamDeleteResult(outcome: .refused, freedBytes: 0, refusalReason: error.localizedDescription)
        }
        return SteamDeleteResult(outcome: .deleted, freedBytes: size, refusalReason: nil)
    }

    // MARK: - Prune

    /// Cuts a finished Wallpaper Engine install down to its `assets/` subtree —
    /// the only part Loomscreen reads. Refuses rather than guesses: a missing
    /// `assets/` means the install is not what we think it is.
    static func pruneWallpaperEngineInstall(
        steamRoot: URL = SteamLibraryPaths.steamRoot()
    ) throws -> URL {
        let root = SteamLibraryPaths.wallpaperEngineInstallRoot(steamRoot: steamRoot)
        guard SteamLibraryPaths.isWritable(root, steamRoot: steamRoot) else {
            throw WriteError.outsideAllowedSubtree
        }
        guard root.lastPathComponent == "wallpaper_engine",
              root.deletingLastPathComponent().lastPathComponent == "common" else {
            throw WriteError.unexpectedLayout
        }

        // One descriptor for the whole operation. Validating through one open and
        // removing through a second let a racing rename put a different ordinary
        // directory at this path between them — the second open would then trim
        // the contents of whatever landed there.
        let installFD = try openDirectory(
            root: steamRoot,
            components: SteamLibraryPaths.wallpaperEngineComponents
        )
        defer { close(installFD) }

        // `assets` must exist *in this descriptor* before anything is removed: a
        // missing one means this is not the install we think it is.
        var assetsInfo = stat()
        guard fstatat(installFD, "assets", &assetsInfo, AT_SYMLINK_NOFOLLOW) == 0,
              (assetsInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw WriteError.missingAssets
        }
        let assetsFD = openat(installFD, "assets", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard assetsFD >= 0 else { throw WriteError.missingAssets }
        let assetsIsPopulated = (try? listDirectory(fd: assetsFD).isEmpty == false) ?? false
        close(assetsFD)
        guard assetsIsPopulated else { throw WriteError.missingAssets }

        var failed = 0
        for name in try listDirectory(fd: installFD) where name != "assets" {
            do { try removeTree(parent: installFD, name: name) } catch { failed += 1 }
        }
        if failed > 0 {
            // Honest about a partial prune: the assets tree is intact and usable,
            // but the caller must not read "installed" as "fully trimmed".
            NSLog("SteamConnector: prune left \(failed) item(s) in place")
        }
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        return assets
    }

    // MARK: - Descriptor-based traversal

    /// Opens `components` one level at a time from `root`, refusing to
    /// follow a link at any step, and returns the final directory
    /// descriptor. Path-string checks can't close this hole: validating a
    /// path then handing the same *string* to `removeItem` leaves a window
    /// where an ancestor is swapped for a link, so later checks describe
    /// the attacker's target instead. Once this returns, the fd names the
    /// directory itself — nothing after can redirect the removal.
    private static func openDirectory(root: URL, components: [String]) throws -> Int32 {
        var fd = open(root.path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw WriteError.unexpectedLayout }
        for component in components {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(fd)
            guard next >= 0 else {
                throw errno == ELOOP ? WriteError.symbolicLinkRejected : WriteError.unexpectedLayout
            }
            fd = next
        }
        return fd
    }

    /// Reads every entry name **without** consuming the caller's
    /// descriptor: `fdopendir` adopts whatever it's given and `closedir`
    /// closes it, so it gets a `dup`. An earlier version handed it the
    /// caller's own descriptor — the recursion below then kept using a
    /// closed fd, silently skipping every nested entry, and could have
    /// operated relative to an unrelated directory if another thread reused
    /// the number.
    private static func listDirectory(fd: Int32) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { throw WriteError.unexpectedLayout }
        guard let dir = fdopendir(copy) else {
            close(copy)
            throw WriteError.unexpectedLayout
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
    }

    /// Recursive delete that never re-resolves a path: every entry is
    /// reached through its parent's descriptor and unlinked with
    /// `unlinkat`, so a swapped directory can't redirect removal outside.
    /// Workshop items are shallow, so a tree deep enough to exhaust the
    /// stack is hostile input — bound the descent rather than crash.
    private static let maxTreeDepth = 64

    private static func removeTree(parent: Int32, name: String, depth: Int = 0) throws {
        guard depth < maxTreeDepth else { throw WriteError.unexpectedLayout }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard child >= 0 else { throw WriteError.symbolicLinkRejected }
            defer { close(child) }
            // Every nested removal is relative to `child`, so it cannot leave the
            // directory this descriptor names — even if the path is rewritten
            // underneath us. A name that changed between listing and unlink just
            // fails or hits the same-named entry in this same directory.
            for entryName in try listDirectory(fd: child) {
                try removeTree(parent: child, name: entryName, depth: depth + 1)
            }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw WriteError.unexpectedLayout }
        } else {
            // A symlink is unlinked, never followed.
            guard unlinkat(parent, name, 0) == 0 else { throw WriteError.unexpectedLayout }
        }
    }

    // MARK: - Helpers




    static func allocatedBytes(at url: URL) -> UInt64 {
        guard let walker = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: UInt64 = 0
        for case let item as URL in walker {
            let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.totalFileAllocatedSize else { continue }
            total += UInt64(size)
        }
        return total
    }
}
