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

    /// Publish only content, never SteamCMD's configuration or manifests. Build
    /// a complete sibling first, then atomically exchange it with the old tree.
    /// All traversal and writes stay anchored to open directory descriptors.
    static func publishContent(
        components: [String],
        from sourceRoot: URL,
        to steamRoot: URL
    ) throws -> URL {
        let destination = components.reduce(steamRoot) { $0.appendingPathComponent($1) }
        guard !components.isEmpty,
              SteamLibraryPaths.isWritable(destination, steamRoot: steamRoot),
              SteamLibraryPaths.isWritable(components.reduce(sourceRoot) { $0.appendingPathComponent($1) }, steamRoot: sourceRoot)
        else { throw WriteError.outsideAllowedSubtree }
        let source = try openDirectory(root: sourceRoot, components: components)
        defer { close(source) }
        guard try !listDirectory(fd: source).isEmpty else { throw WriteError.unexpectedLayout }
        let parent = try openDirectory(root: steamRoot, components: Array(components.dropLast()), create: true)
        defer { close(parent) }
        let staging = ".loomscreen-\(UUID().uuidString)"
        guard mkdirat(parent, staging, 0o700) == 0 else { throw WriteError.unexpectedLayout }
        // Cleared once the swap has happened and the merge below has carried
        // every target-only entry across. Between those two points the old tree
        // still holds the only copy of files the new one lacks, so the cleanup
        // must not run: a merge that throws leaves them in the hidden staging
        // name (which the library scan skips) instead of deleting them.
        var discardDisplacedTree = true
        defer {
            if discardDisplacedTree {
                try? removeTree(parent: parent, name: staging)
            }
        }
        let target = openat(parent, staging, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard target >= 0 else { throw WriteError.unexpectedLayout }
        defer { close(target) }
        try copyTree(source: source, target: target)
        let name = components[components.count - 1]
        var info = stat()
        let exists = fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0
        guard !exists || (info.st_mode & S_IFMT) == S_IFDIR else { throw WriteError.symbolicLinkRejected }
        var sourceInfo = stat()
        guard fstat(source, &sourceInfo) == 0,
              !exists || info.st_dev != sourceInfo.st_dev || info.st_ino != sourceInfo.st_ino
        else { throw WriteError.unexpectedLayout }
        let flags = exists ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
        guard renameatx_np(parent, staging, parent, name, flags) == 0 else { throw WriteError.unexpectedLayout }
        if exists {
            // `target` followed its inode through the swap and now names the live
            // tree; the displaced old tree sits under the staging name.
            let old = openat(parent, staging, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard old >= 0 else { throw WriteError.unexpectedLayout }
            defer { close(old) }
            discardDisplacedTree = false
            try adoptTargetOnlyEntries(old: old, new: target)
            discardDisplacedTree = true
        }
        // Keep one content repository. Only the engine-assets install still
        // stages into a profile and publishes from it; Workshop items are
        // written straight into the library by SteamCMD.
        if let sourceParent = try? openDirectory(root: sourceRoot, components: Array(components.dropLast())) {
            defer { close(sourceParent) }
            var current = stat()
            if fstatat(sourceParent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
               current.st_dev == sourceInfo.st_dev, current.st_ino == sourceInfo.st_ino {
                try? removeTree(parent: sourceParent, name: name)
            }
        }
        return destination
    }

    private static func copyTree(source: Int32, target: Int32, depth: Int = 0) throws {
        guard depth < maxTreeDepth else { throw WriteError.unexpectedLayout }
        for name in try listDirectory(fd: source) {
            var info = stat()
            guard fstatat(source, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw WriteError.unexpectedLayout }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard mkdirat(target, name, 0o700) == 0 else { throw WriteError.unexpectedLayout }
                let input = openat(source, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                let output = openat(target, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                defer {
                    if input >= 0 {
                        close(input)
                    }
                    if output >= 0 {
                        close(output)
                    }
                }
                guard input >= 0, output >= 0 else { throw WriteError.symbolicLinkRejected }
                try copyTree(source: input, target: output, depth: depth + 1)
            case S_IFREG:
                let input = openat(source, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                let output = openat(target, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                defer {
                    if input >= 0 {
                        close(input)
                    }
                    if output >= 0 {
                        close(output)
                    }
                }
                var opened = stat()
                guard input >= 0, output >= 0, fstat(input, &opened) == 0,
                      (opened.st_mode & S_IFMT) == S_IFREG else { throw WriteError.symbolicLinkRejected }
                guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else { throw WriteError.unexpectedLayout }
            default: throw WriteError.symbolicLinkRejected
            }
        }
    }

    /// Files the user or another program put beside a downloaded item are not
    /// ours to delete: move whatever only the old tree has into the new one.
    /// Links stay behind for `removeTree` to unlink — never moved, never followed.
    private static func adoptTargetOnlyEntries(old: Int32, new: Int32, depth: Int = 0) throws {
        guard depth < maxTreeDepth else { throw WriteError.unexpectedLayout }
        for name in try listDirectory(fd: old) {
            var oldInfo = stat()
            guard fstatat(old, name, &oldInfo, AT_SYMLINK_NOFOLLOW) == 0 else { throw WriteError.unexpectedLayout }
            let kind = oldInfo.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG else { continue }
            var newInfo = stat()
            if fstatat(new, name, &newInfo, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT,
                      renameatx_np(old, name, new, name, UInt32(RENAME_EXCL)) == 0 else { throw WriteError.unexpectedLayout }
            } else if kind == S_IFDIR, (newInfo.st_mode & S_IFMT) == S_IFDIR {
                let input = openat(old, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                let output = openat(new, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                defer {
                    if input >= 0 {
                        close(input)
                    }
                    if output >= 0 {
                        close(output)
                    }
                }
                guard input >= 0, output >= 0 else { throw WriteError.unexpectedLayout }
                try adoptTargetOnlyEntries(old: input, new: output, depth: depth + 1)
            }
        }
    }

    // MARK: - Delete

    /// Removes one Workshop item. Steam's `appworkshop_431960.acf`
    /// deliberately keeps listing it afterwards — it's Steam's ledger, not
    /// ours, and a later `workshop_download_item` re-fetching it is the
    /// wanted behaviour; do not "fix" that by rewriting the acf.
    /// `steamRoot` is required, never defaulted: the connector must be told
    /// which library the user authorized, and a default here would let a future
    /// caller silently write to the hardcoded one instead.
    static func deleteWorkshopItem(
        workshopID: String,
        steamRoot: URL
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

    /// Removes `directory` the way a Workshop item is removed: every level under
    /// `root` is opened relative to the one above with `O_NOFOLLOW`, so a
    /// component swapped for a link after the caller's own path check is refused
    /// or unlinked, never followed. The connector's own profile cleanups used
    /// `removeItem(atPath:)` after that check, which re-resolves the string.
    static func removeDirectory(_ directory: URL, under root: URL) throws {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = directory.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count,
              components.starts(with: rootComponents),
              let name = components.last
        else { throw WriteError.outsideAllowedSubtree }
        let parent = try openDirectory(
            root: root,
            components: Array(components[rootComponents.count ..< components.count - 1])
        )
        defer { close(parent) }
        try removeTree(parent: parent, name: name)
    }

    // MARK: - Prune

    /// Cuts a finished Wallpaper Engine install down to its `assets/` subtree —
    /// the only part Loomscreen reads. Refuses rather than guesses: a missing
    /// `assets/` means the install is not what we think it is.
    static func pruneWallpaperEngineInstall(
        steamRoot: URL
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
    private static func openDirectory(root: URL, components: [String], create: Bool = false) throws -> Int32 {
        var fd = open(root.path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw WriteError.unexpectedLayout }
        for component in components {
            if create, mkdirat(fd, component, 0o755) != 0, errno != EEXIST {
                close(fd)
                throw WriteError.unexpectedLayout
            }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(fd)
            guard next >= 0 else {
                throw errno == ELOOP ? WriteError.symbolicLinkRejected : WriteError.unexpectedLayout
            }
            fd = next
        }
        return fd
    }

    /// Open a fresh description relative to the pinned directory. `dup` keeps
    /// the descriptor alive but SHARES its directory offset: a presence check
    /// would consume the entries before the subsequent copy sees them.
    private static func listDirectory(fd: Int32) throws -> [String] {
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
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
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            // Only "already gone" (ENOENT) is a no-op — any other failure (e.g. a
            // permission error mid-removal) must not be reported as removed.
            guard errno == ENOENT else { throw WriteError.unexpectedLayout }
            return
        }
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
